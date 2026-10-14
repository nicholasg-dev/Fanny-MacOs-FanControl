import Foundation

// MARK: - Fan Control Law
//
// This file holds every decision that turns SMC samples into a fan command:
// sensor conditioning, thermal-demand aggregation across rules, the demand
// deadband, and the command slew-rate limiter.
//
// It is deliberately a plain value type with no SwiftUI, no `ObservableObject`,
// no `Process`, no `UserDefaults`, and no global state. `FanViewModel` owns one
// instance, feeds it sensor samples, and publishes what it decides; nothing else
// in the app touches the law. Two consequences matter:
//
//   1. The thermal-safety behaviour is testable without a window server, a
//      signed bundle, or a privileged helper — a standalone harness can compile
//      this file plus `Models/` and drive it directly.
//   2. The view model cannot accidentally smuggle side effects into a decision
//      path, because the law has no way to perform one. It returns a `Decision`
//      and the owner carries it out.
//
// Tuning values are stored rather than hard-coded so the owner can push the
// user's persisted preferences in without this type depending on the preference
// store. The declared initialisers are the shipping values.

/// The automatic fan-control law.
///
/// All mutable state the controller latches between polls lives here, so the
/// behaviour of a given sequence of samples depends only on the law's own state.
struct FanControlLaw {

    // MARK: Tuning (pushed in by the owner)

    /// Maximum commanded increase per second while the machine is heating.
    var maximumCommandRiseRatePercentPerSecond: Double = 6.0
    /// Maximum commanded decrease per second while the machine is cooling.
    var maximumCommandFallRatePercentPerSecond: Double = 3.0
    /// Degrees a sensor must fall by before a falling reading is accepted.
    var coolingTemperatureHysteresis: Double = 5.0
    /// Percent of demand change ignored before it reaches the rate limiter.
    var minimumCommandChangePercent: Double = 4.0
    /// Seconds a reduced thermal demand must persist before fan speed is released.
    var coolingConfirmationSeconds: Double = 8.0

    /// Demand at or above this percentage is treated as a safety request and
    /// bypasses both the deadband and the slew-rate limiter.
    let emergencyBypassPercent: Double = 90.0
    /// Once the commanded demand falls to or below this, control is handed back
    /// to macOS Auto.
    let releaseToAutoPercent: Double = 0.5

    // MARK: Latched state

    /// True while the law believes it is commanding the fans. The owner uses this
    /// to decide whether a reset must be issued when control is given up.
    private(set) var wasRuleApplied = false
    /// The percentage most recently handed to the fan writer. `nil` whenever the
    /// law has not commanded anything since the last release.
    private(set) var lastSetSpeedPercent: Double?
    /// Output of the deadband stage, feeding the slew-rate limiter.
    private(set) var deadbandedRuleTargetPercent: Double?
    /// Output of the slew-rate limiter.
    private(set) var filteredRuleTargetPercent: Double?
    /// Monotonic time of the last limiter evaluation, in seconds. Used to size the
    /// rate interval. See `FanViewModel` for the clock: it must keep counting
    /// through sleep, and must not follow the wall clock.
    private(set) var lastRuleEvaluationTime: TimeInterval?
    /// Last accepted temperature per sensor while cooling.
    private(set) var heldControlTemperatures: [TriggerRule.SensorType: Double] = [:]
    /// The reduced demand currently awaiting confirmation before release.
    private(set) var pendingCoolingTargetPercent: Double?
    /// Monotonic time when `pendingCoolingTargetPercent` was first proposed.
    private(set) var coolingConfirmationStartTime: TimeInterval?

    init() {}

    // MARK: - Sensor conditioning

    /// Physically plausible range for a sensor reading. Values outside it are a
    /// bad SMC key or a decoding failure, not a real temperature.
    static func temperatureBounds(for sensor: TriggerRule.SensorType) -> ClosedRange<Double> {
        switch sensor {
        case .cpu, .gpu:
            return 10.0...115.0
        case .battery:
            return 5.0...70.0
        }
    }

    /// Largest single-poll change accepted from a sensor.
    static func maximumTemperatureStep(for sensor: TriggerRule.SensorType) -> Double {
        switch sensor {
        case .cpu, .gpu:
            return 25.0
        case .battery:
            return 8.0
        }
    }

    /// Same rejection rules as `TemperatureConditioner`, for replaying stored
    /// history. A rejected record is dropped (`nil`) rather than held, because
    /// history has no "previous" to freeze on across a gap.
    static func cleanHistoricalTemperature(
        _ candidate: Double?,
        previous: inout Double?,
        sensor: TriggerRule.SensorType
    ) -> Double? {
        guard let candidate,
              candidate.isFinite,
              temperatureBounds(for: sensor).contains(candidate) else {
            return nil
        }
        if let previous,
           abs(candidate - previous) > maximumTemperatureStep(for: sensor) {
            return nil
        }
        previous = candidate
        return candidate
    }

    /// The history graph has one fan-target series. When fans differ, record the
    /// highest SMC target percentage so the trace remains conservative and useful
    /// for comparing thermal demand with the strongest commanded cooling response.
    static func highestFanTargetPercent(fans: [FanJSON]) -> Double? {
        fans.compactMap { fan -> Double? in
            let range = fan.maxSpeed - fan.minSpeed
            guard range > 0 else { return nil }
            let percentage = 100.0 * Double(fan.targetSpeed - fan.minSpeed) / Double(range)
            return min(max(percentage, 0.0), 100.0)
        }
        .max()
    }

    // MARK: - Response shaping

    /// Lets temperature increases through immediately, but holds the last accepted
    /// temperature while cooling until it has fallen by the selected deadband. This
    /// avoids small sensor fluctuations repeatedly reducing and restoring fan demand.
    mutating func temperatureForFanControl(
        _ temperature: Double,
        sensor: TriggerRule.SensorType
    ) -> Double {
        guard let heldTemperature = heldControlTemperatures[sensor] else {
            heldControlTemperatures[sensor] = temperature
            return temperature
        }

        let hysteresis = max(coolingTemperatureHysteresis, 0)
        if temperature >= heldTemperature || temperature <= heldTemperature - hysteresis {
            heldControlTemperatures[sensor] = temperature
            return temperature
        }

        return heldTemperature
    }

    /// Ignores small demand changes before they reach the command-rate limiter.
    /// Downward changes also need a sustained lower thermal demand, which avoids
    /// releasing fan speed for a short-lived dip in CPU or GPU power.
    mutating func deadbandedRuleTarget(toward desiredPercent: Double, now: TimeInterval) -> Double {
        guard let previous = deadbandedRuleTargetPercent else {
            deadbandedRuleTargetPercent = desiredPercent
            clearCoolingConfirmation()
            return desiredPercent
        }

        if desiredPercent >= emergencyBypassPercent {
            deadbandedRuleTargetPercent = desiredPercent
            clearCoolingConfirmation()
            return desiredPercent
        }

        let change = desiredPercent - previous
        if change >= 0 {
            // A renewed thermal demand cancels any pending cooling release.
            clearCoolingConfirmation()
            if change >= minimumCommandChangePercent {
                deadbandedRuleTargetPercent = desiredPercent
            }
            return deadbandedRuleTargetPercent ?? desiredPercent
        }

        // A thermal recovery that reverses before being confirmed starts the
        // confirmation interval again, even if it remains below the current target.
        if let pendingTarget = pendingCoolingTargetPercent,
           desiredPercent > pendingTarget {
            pendingCoolingTargetPercent = desiredPercent
            coolingConfirmationStartTime = now
        }

        guard abs(change) >= minimumCommandChangePercent else {
            return previous
        }

        let confirmationInterval = max(coolingConfirmationSeconds, 0)
        guard confirmationInterval > 0 else {
            deadbandedRuleTargetPercent = desiredPercent
            clearCoolingConfirmation()
            return desiredPercent
        }

        if pendingCoolingTargetPercent == nil {
            pendingCoolingTargetPercent = desiredPercent
            coolingConfirmationStartTime = now
            return previous
        }

        pendingCoolingTargetPercent = min(pendingCoolingTargetPercent ?? desiredPercent, desiredPercent)
        guard let startTime = coolingConfirmationStartTime,
              now - startTime >= confirmationInterval else {
            return previous
        }

        let confirmedTarget = pendingCoolingTargetPercent ?? desiredPercent
        deadbandedRuleTargetPercent = confirmedTarget
        clearCoolingConfirmation()
        return confirmedTarget
    }

    /// Moves the automatic command at a bounded, predictable rate. This is a
    /// slew-rate limiter, rather than a time-constant filter: it gives the same
    /// maximum command change per second for a small or large temperature step.
    /// Heating uses a higher configurable rate than cooling by default, so the
    /// controller can react promptly to load while releasing fan speed gently.
    mutating func filteredRuleTarget(toward desiredPercent: Double, now: TimeInterval) -> Double {
        defer { lastRuleEvaluationTime = now }

        guard let previous = filteredRuleTargetPercent,
              let previousTime = lastRuleEvaluationTime else {
            // Apply the first demand immediately; this is the conservative choice.
            filteredRuleTargetPercent = desiredPercent
            return desiredPercent
        }

        // Do not delay a high-speed safety request.
        if desiredPercent >= emergencyBypassPercent {
            filteredRuleTargetPercent = desiredPercent
            return desiredPercent
        }

        let elapsed = max(now - previousTime, 0.01)
        let change = desiredPercent - previous
        let maximumRate = change >= 0
            ? maximumCommandRiseRatePercentPerSecond
            : maximumCommandFallRatePercentPerSecond
        let maximumChange = max(maximumRate, 0.1) * elapsed
        let filtered = previous + min(max(change, -maximumChange), maximumChange)

        filteredRuleTargetPercent = filtered
        return filtered
    }

    /// Drops every latched response value so the next evaluation starts from a
    /// cold controller.
    mutating func resetResponse() {
        filteredRuleTargetPercent = nil
        deadbandedRuleTargetPercent = nil
        lastRuleEvaluationTime = nil
        heldControlTemperatures.removeAll()
        clearCoolingConfirmation()
    }

    /// Gives up control of the fans and reports whether the caller must issue a
    /// reset first. Used both when the rules engine is switched off and when the
    /// poll watchdog decides it can no longer confirm it is in control.
    ///
    /// - Returns: `true` when the law was commanding the fans, so the owner must
    ///   hand them back to macOS Auto.
    @discardableResult
    mutating func relinquishControl() -> Bool {
        let needsReset = wasRuleApplied
        wasRuleApplied = false
        lastSetSpeedPercent = nil
        resetResponse()
        return needsReset
    }

    /// Forgets the last command so the next evaluation sends the current demand
    /// again, even though it has not changed. The owner calls this after wake,
    /// and when the helper reports a fan that is no longer in manual mode, since
    /// the firmware may have put the fan back under its own control.
    mutating func requestReassert() {
        lastSetSpeedPercent = nil
    }

    private mutating func clearCoolingConfirmation() {
        pendingCoolingTargetPercent = nil
        coolingConfirmationStartTime = nil
    }

    // MARK: - Decision

    /// The result of one evaluation. The law states what should happen; the owner
    /// is the only thing that can make it happen.
    enum Decision: Equatable {
        /// Leave the fans exactly as they are.
        case hold
        /// Write `percent` (0...1) to every fan.
        case apply(percent: Double)
        /// Hand control back to macOS Auto.
        case releaseToAuto
    }

    /// The latest reading per sensor, fed into the law each poll.
    struct SensorTemperatures {
        var cpu: Double?
        var gpu: Double?
        var battery: Double?

        func value(for sensor: TriggerRule.SensorType) -> Double? {
            switch sensor {
            case .cpu: return cpu
            case .gpu: return gpu
            case .battery: return battery
            }
        }
    }

    /// Aggregates the enabled rules into a single thermal demand, shapes that
    /// demand through the deadband and the slew-rate limiter, and reports what
    /// should be done with the fans.
    ///
    /// - Parameter now: monotonic time in seconds (see `lastRuleEvaluationTime`).
    ///   It must never follow the wall clock, which can jump backwards or forwards.
    ///
    /// - Important: this advances the law's latched state. A caller that gets
    ///   `.apply` or `.releaseToAuto` is responsible for carrying it out.
    mutating func evaluate(
        rules: [TriggerRule],
        temperatures: SensorTemperatures,
        now: TimeInterval
    ) -> Decision {
        var maxTargetPercent: Double? = nil

        for rule in rules where rule.isEnabled {
            guard let measuredTemp = temperatures.value(for: rule.sensor) else { continue }
            let currentTemp = temperatureForFanControl(measuredTemp, sensor: rule.sensor)

            if rule.ruleType == .threshold {
                if currentTemp >= rule.thresholdTemp {
                    if maxTargetPercent == nil || rule.targetSpeedPercent > maxTargetPercent! {
                        maxTargetPercent = rule.targetSpeedPercent
                    }
                }
            } else if rule.ruleType == .curve {
                if currentTemp >= rule.minTemp {
                    let range = rule.maxTemp - rule.minTemp
                    let tempDiff = currentTemp - rule.minTemp
                    let speedDiff = rule.maxSpeedPercent - rule.minSpeedPercent

                    var calculatedPercent = rule.minSpeedPercent
                    if range > 0 {
                        let ratio = min(max(tempDiff / range, 0.0), 1.0)
                        calculatedPercent = rule.minSpeedPercent + ratio * speedDiff
                    }

                    if maxTargetPercent == nil || calculatedPercent > maxTargetPercent! {
                        maxTargetPercent = calculatedPercent
                    }
                }
            }
        }

        let desiredPercent = maxTargetPercent ?? 0.0
        let stabilizedPercent = deadbandedRuleTarget(toward: desiredPercent, now: now)
        let filteredPercent = filteredRuleTarget(toward: stabilizedPercent, now: now)

        // When all rules clear, ramp down to the physical fan minimum first, then
        // yield control back to macOS instead of switching to Auto abruptly.
        if desiredPercent > 0.0 || filteredPercent > releaseToAutoPercent {
            let requiresEmergencyIncrease = stabilizedPercent >= emergencyBypassPercent
                && (lastSetSpeedPercent == nil || filteredPercent > lastSetSpeedPercent!)
            if !wasRuleApplied ||
                lastSetSpeedPercent == nil ||
                requiresEmergencyIncrease ||
                abs(filteredPercent - lastSetSpeedPercent!) >= 0.1 {
                wasRuleApplied = true
                lastSetSpeedPercent = filteredPercent
                return .apply(percent: min(max(filteredPercent, 0.0), 100.0) / 100.0)
            }
            return .hold
        } else if wasRuleApplied {
            wasRuleApplied = false
            lastSetSpeedPercent = nil
            resetResponse()
            return .releaseToAuto
        }
        return .hold
    }
}

// MARK: - Temperature conditioning

/// Conditions one sensor's stream of raw readings before they reach the
/// published telemetry or the control law.
///
/// A reading that is out of range, non-finite, or missing is ignored and the
/// last accepted value is held. A reading within the sensor's per-poll step cap
/// is accepted at once. A reading beyond the cap is held back as a candidate
/// and accepted only once `confirmationSamples` consecutive readings agree with
/// it. A single outlier therefore never moves the value, while a real, sustained
/// change is accepted after a few seconds instead of being frozen out forever.
struct TemperatureConditioner {
    /// Consecutive agreeing readings beyond the cap needed before a sustained
    /// change is accepted. At the one-second poll rate this is a delay of two
    /// seconds at most.
    static let confirmationSamples = 3

    let sensor: TriggerRule.SensorType
    /// The last value this conditioner accepted, or `nil` before the first one.
    private(set) var accepted: Double?
    /// The beyond-cap value currently being confirmed.
    private var candidate: Double?
    /// How many consecutive readings have agreed with `candidate`.
    private var candidateCount = 0

    init(sensor: TriggerRule.SensorType) {
        self.sensor = sensor
    }

    /// Feeds one raw reading and returns the value to publish and control with.
    mutating func accept(_ reading: Double?) -> Double? {
        guard let reading,
              reading.isFinite,
              FanControlLaw.temperatureBounds(for: sensor).contains(reading) else {
            return accepted
        }

        guard let current = accepted else {
            accepted = reading
            return reading
        }

        let cap = FanControlLaw.maximumTemperatureStep(for: sensor)
        if abs(reading - current) <= cap {
            accepted = reading
            clearCandidate()
            return reading
        }

        if let pending = candidate, abs(reading - pending) <= cap {
            candidateCount += 1
        } else {
            candidate = reading
            candidateCount = 1
        }

        if candidateCount >= Self.confirmationSamples {
            accepted = reading
            clearCandidate()
        }
        return accepted
    }

    private mutating func clearCandidate() {
        candidate = nil
        candidateCount = 0
    }
}