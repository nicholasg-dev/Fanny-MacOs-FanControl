// Behavioural tests for Core/FanControlLaw.swift.
//
// Compiled together with Core/FanControlLaw.swift and Models/ by
// tests/run-law-tests.sh. There is no XCTest target in this project; these
// checks are plain executable assertions so they run anywhere `swiftc` does,
// with no window server, no signed bundle and no privileged helper.

import Combine
import Foundation

var failures: [String] = []
var checks = 0

func expect(_ condition: @autoclosure () -> Bool, _ name: String) {
    checks += 1
    if !condition() {
        failures.append(name)
        print("FAIL  \(name)")
    }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
    checks += 1
    if actual != expected {
        failures.append(name)
        print("FAIL  \(name): expected \(expected), got \(actual)")
    }
}

// MARK: - Temperature conditioning

/// Feeds a series of raw samples through one conditioner and returns what it
/// accepted for each one.
func accepted(_ samples: [Double?], sensor: TriggerRule.SensorType) -> [Double?] {
    var conditioner = TemperatureConditioner(sensor: sensor)
    return samples.map { conditioner.accept($0) }
}

func testFirstValidSampleIsAccepted() {
    expectEqual(accepted([60], sensor: .cpu), [60], "first valid CPU sample is accepted")
}

func testOutOfRangeSampleIsIgnored() {
    expectEqual(accepted([60, 120], sensor: .cpu), [60, 60],
                "CPU sample above 115 °C is ignored and the last value held")
}

func testMissingSampleHoldsLastValue() {
    expectEqual(accepted([60, nil], sensor: .cpu), [60, 60],
                "a nil sample holds the last accepted value")
}

func testSmallStepIsAcceptedImmediately() {
    expectEqual(accepted([60, 70], sensor: .cpu), [60, 70],
                "a 10 °C CPU step is inside the 25 °C cap and is accepted")
}

func testSingleOutlierIsRejected() {
    expectEqual(accepted([60, 95, 61], sensor: .cpu), [60, 60, 61],
                "one 35 °C outlier is rejected, and the normal reading resumes")
}

func testSustainedStepIsAcceptedAfterConfirmation() {
    // Regression: the earlier acceptTemperature rejected every sample of a
    // sustained step and held the old value forever.
    expectEqual(accepted([60, 95, 95, 95], sensor: .cpu), [60, 60, 60, 95],
                "a sustained 35 °C CPU step is accepted on the third agreeing sample")
}

func testSustainedBatteryStepUsesBatteryCap() {
    expectEqual(accepted([34, 45, 45, 45], sensor: .battery), [34, 34, 34, 45],
                "a sustained 11 °C battery step is accepted after confirmation (cap 8 °C)")
}

func testInterruptedConfirmationStartsOver() {
    expectEqual(accepted([60, 95, 61, 95, 95], sensor: .cpu), [60, 60, 61, 61, 61],
                "a sample back inside the cap resets the confirmation count")
}

// MARK: - Monotonic time and the slew limiter

func testSlewLimiterUsesElapsedTimeNotWallClock() {
    var law = FanControlLaw()
    let coolRules = [TriggerRule(isEnabled: true, sensor: .cpu, thresholdTemp: 40, targetSpeedPercent: 20)]
    let hotRules = [TriggerRule(isEnabled: true, sensor: .cpu, thresholdTemp: 40, targetSpeedPercent: 80)]
    let temps = FanControlLaw.SensorTemperatures(cpu: 50, gpu: nil, battery: nil)

    // Establish a 20% command, then ask for 80%. At 6 %/s the limiter must
    // move exactly 6 points over one second of elapsed time.
    expectEqual(law.evaluate(rules: coolRules, temperatures: temps, now: 0),
                .apply(percent: 0.20), "initial 20% demand is applied immediately")
    expectEqual(law.evaluate(rules: hotRules, temperatures: temps, now: 1.0),
                .apply(percent: 0.26), "rise is limited to 6 points per elapsed second")
}

// MARK: - Re-asserting a command

func testRequestReassertReissuesTheLastCommand() {
    var law = FanControlLaw()
    let rules = [TriggerRule(isEnabled: true, sensor: .cpu, thresholdTemp: 40, targetSpeedPercent: 80)]
    let temps = FanControlLaw.SensorTemperatures(cpu: 50, gpu: nil, battery: nil)

    expectEqual(law.evaluate(rules: rules, temperatures: temps, now: 0),
                .apply(percent: 0.80), "first demand is applied")
    expectEqual(law.evaluate(rules: rules, temperatures: temps, now: 1),
                .hold, "an unchanged demand is held without re-sending")

    law.requestReassert()
    expectEqual(law.evaluate(rules: rules, temperatures: temps, now: 2),
                .apply(percent: 0.80), "after requestReassert the same demand is sent again")
}

// MARK: - History store

func makeTemporaryDirectory() -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("fancontrol-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

func makeDefaults() -> UserDefaults {
    let suite = "fancontrol-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
}

func lineCount(of url: URL) -> Int {
    guard let data = try? Data(contentsOf: url) else { return 0 }
    return data.split(separator: UInt8(ascii: "\n")).count
}

func testHistoryPersistsAcrossLaunches() {
    let file = makeTemporaryDirectory().appendingPathComponent("history.jsonl")
    let start = Date()
    let first = FanHistoryStore(fileURL: file, defaults: makeDefaults(), now: start)
    first.recordIfDue(now: start, cpu: 50, gpu: nil, battery: 30, fanTargetPercent: 40)
    first.recordIfDue(now: start.addingTimeInterval(30), cpu: 52, gpu: 49, battery: 30, fanTargetPercent: 45)
    first.flush()

    let second = FanHistoryStore(fileURL: file, defaults: makeDefaults(), now: start.addingTimeInterval(31))
    expectEqual(second.records.count, 2, "two records survive a relaunch")
    expectEqual(second.records.last?.cpu, 52, "the latest CPU reading is restored")
    expectEqual(second.records.last?.gpu, 49, "the latest GPU reading is restored")
}

func testRecordsCloserThanThirtySecondsAreSkipped() {
    let file = makeTemporaryDirectory().appendingPathComponent("history.jsonl")
    let start = Date()
    let store = FanHistoryStore(fileURL: file, defaults: makeDefaults(), now: start)
    store.recordIfDue(now: start, cpu: 50, gpu: nil, battery: nil, fanTargetPercent: nil)
    store.recordIfDue(now: start.addingTimeInterval(10), cpu: 51, gpu: nil, battery: nil, fanTargetPercent: nil)
    expectEqual(store.records.count, 1, "a sample 10 s after the last record is not stored")
}

func testRecordsOlderThanRetentionArePruned() {
    let file = makeTemporaryDirectory().appendingPathComponent("history.jsonl")
    let start = Date()
    let store = FanHistoryStore(fileURL: file, defaults: makeDefaults(), now: start)
    store.recordIfDue(now: start, cpu: 50, gpu: nil, battery: nil, fanTargetPercent: nil)
    let later = start.addingTimeInterval(25 * 60 * 60)
    store.recordIfDue(now: later, cpu: 51, gpu: nil, battery: nil, fanTargetPercent: nil)
    expectEqual(store.records.map(\.cpu), [51], "records older than 24 hours are pruned")
}

func testCorruptLineIsSkipped() {
    let file = makeTemporaryDirectory().appendingPathComponent("history.jsonl")
    let record = TempRecord(timestamp: Date(), cpu: 50, gpu: nil, battery: nil, fanTargetPercent: nil)
    let line = try! JSONEncoder().encode(record)
    var contents = line
    contents.append(contentsOf: Array("\n{not json\n".utf8))
    try! contents.write(to: file)

    let store = FanHistoryStore(fileURL: file, defaults: makeDefaults(), now: Date())
    expectEqual(store.records.count, 1, "a truncated or corrupt line is skipped, not fatal")
}

func testExpiredLinesAreDroppedFromDiskOnLoad() {
    let file = makeTemporaryDirectory().appendingPathComponent("history.jsonl")
    let now = Date()
    let expired = TempRecord(timestamp: now.addingTimeInterval(-3 * 24 * 60 * 60), cpu: 40, gpu: nil, battery: nil, fanTargetPercent: nil)
    let current = TempRecord(timestamp: now, cpu: 55, gpu: nil, battery: nil, fanTargetPercent: nil)
    var contents = try! JSONEncoder().encode(expired)
    contents.append(UInt8(ascii: "\n"))
    contents.append(try! JSONEncoder().encode(current))
    contents.append(UInt8(ascii: "\n"))
    try! contents.write(to: file)

    let store = FanHistoryStore(fileURL: file, defaults: makeDefaults(), now: now)
    store.flush()
    expectEqual(store.records.map(\.cpu), [55], "expired records are not loaded")
    expectEqual(lineCount(of: file), 1, "expired records are removed from disk when the file is loaded")
}

func testLegacyUserDefaultsHistoryIsMigrated() {
    let file = makeTemporaryDirectory().appendingPathComponent("history.jsonl")
    let defaults = makeDefaults()
    let now = Date()
    let legacy = [
        TempRecord(timestamp: now.addingTimeInterval(-60), cpu: 44, gpu: nil, battery: nil, fanTargetPercent: nil),
        TempRecord(timestamp: now, cpu: 46, gpu: nil, battery: nil, fanTargetPercent: nil)
    ]
    defaults.set(try! JSONEncoder().encode(legacy), forKey: "tempHistory")

    let store = FanHistoryStore(fileURL: file, defaults: defaults, now: now)
    store.flush()
    expectEqual(store.records.count, 2, "history stored in UserDefaults is loaded on first launch")
    expectEqual(defaults.data(forKey: "tempHistory") == nil, true, "the UserDefaults blob is removed after migration")
    expectEqual(lineCount(of: file), 2, "the migrated history is written to the file")
}

// MARK: - Published state changes only when values change

func testTelemetryPublishesOnlyWhenValuesChange() {
    let telemetry = FanTelemetry()
    var emissions = 0
    let subscription = telemetry.objectWillChange.sink { emissions += 1 }
    let fan = FanJSON(id: 0, name: "Fan 0", currentSpeed: 2300, minSpeed: 2000,
                      maxSpeed: 6000, targetSpeed: 2300, mode: 1)

    telemetry.apply(fans: [fan], batteryTemp: 30)
    let afterFirstPoll = emissions
    expect(afterFirstPoll > 0, "the first telemetry values are published")

    telemetry.apply(fans: [fan], batteryTemp: 30)
    expectEqual(emissions, afterFirstPoll, "an identical poll publishes nothing")
    _ = subscription
}

func testMenuBarRoundsRPMAndPublishesOnlyWhenTheRoundedValueChanges() {
    expectEqual(MenuBarStatus.displayedRPM(for: 4526), 4550, "RPM is rounded to the nearest 50")
    expectEqual(MenuBarStatus.displayedRPM(for: 4518), 4500, "RPM just below a midpoint rounds down")

    let status = MenuBarStatus()
    status.update(firstFanRPM: 4526, firstFanMaxRPM: 7826)
    expectEqual(status.roundedRPM, 4550, "the menu bar shows the rounded RPM")

    var emissions = 0
    let subscription = status.objectWillChange.sink { emissions += 1 }
    status.update(firstFanRPM: 4531, firstFanMaxRPM: 7826)
    expectEqual(emissions, 0, "a jitter that rounds to the same value publishes nothing")
    _ = subscription
}

// MARK: - Starter rules

/// The fan command the law produces for one CPU or battery reading, with only
/// the given starter rule enabled. Returns `nil` when the law holds (no demand).
func starterDemand(sensor: TriggerRule.SensorType, temperature: Double) -> Double? {
    guard var rule = TriggerRule.starterRules.first(where: { $0.sensor == sensor }) else { return nil }
    rule.isEnabled = true
    var law = FanControlLaw()
    let temps = sensor == .cpu
        ? FanControlLaw.SensorTemperatures(cpu: temperature, gpu: nil, battery: nil)
        : FanControlLaw.SensorTemperatures(cpu: nil, gpu: nil, battery: temperature)
    switch law.evaluate(rules: [rule], temperatures: temps, now: 0) {
    case .apply(let percent): return percent
    case .hold, .releaseToAuto: return nil
    }
}

func expectClose(_ actual: Double?, _ expected: Double, _ name: String) {
    checks += 1
    guard let actual, abs(actual - expected) < 1e-9 else {
        failures.append(name)
        print("FAIL  \(name): expected \(expected), got \(String(describing: actual))")
        return
    }
}

func testStarterRulesAreOffByDefault() {
    expectEqual(TriggerRule.starterRules.allSatisfy { !$0.isEnabled }, true,
                "starter rules stay disabled, so the engine does nothing until the user turns it on")
}

func testStarterCPUCurveRampsGraduallyInsteadOfStepping() {
    expectEqual(starterDemand(sensor: .cpu, temperature: 45), nil,
                "CPU at 45 °C is below the curve, so there is no demand")
    expectClose(starterDemand(sensor: .cpu, temperature: 60), 0.3625,
                "CPU at 60 °C asks for 36.25%, not a jump to a high speed")
    expectClose(starterDemand(sensor: .cpu, temperature: 75), 0.60625,
                "CPU at 75 °C asks for 60.625%")
    expectClose(starterDemand(sensor: .cpu, temperature: 90), 0.85,
                "CPU at 90 °C reaches the 85% ceiling")
    expectEqual(starterDemand(sensor: .cpu, temperature: 115).map { $0 < 0.9 } ?? false, true,
                "the starter CPU curve never reaches the 90% emergency bypass, so it stays rate-limited")
}

func testStarterBatteryCurveStaysGentle() {
    expectEqual(starterDemand(sensor: .battery, temperature: 30), nil,
                "battery at 30 °C is normal, so there is no demand")
    expectClose(starterDemand(sensor: .battery, temperature: 40), 0.375,
                "battery at 40 °C asks for 37.5%, not the old 60%")
    expectClose(starterDemand(sensor: .battery, temperature: 45), 0.60,
                "battery reaches its 60% ceiling at 45 °C")
}

// MARK: - Menu bar width

func testMenuBarReservesWidthForTheWidestReadoutTheFanCanShow() {
    // The readout is drawn in a slot as wide as its widest possible value. Digits are
    // proportional in the menu-bar font, so "4" is the widest digit, and a value
    // with as many digits as the fan's maximum is what the slot must hold.
    expectEqual(MenuBarStatus.reservedRPM(forMaxRPM: 7826), 4444,
                "a fan with a four-digit maximum reserves four-digit width")
    expectEqual(MenuBarStatus.reservedRPM(forMaxRPM: 12000), 44444,
                "a fan with a five-digit maximum reserves five-digit width")
    expectEqual(MenuBarStatus.reservedRPM(forMaxRPM: 0), 4444,
                "a missing maximum still reserves four-digit width")
}

// MARK: - Localized counts

func testCountsAreFormattedWithoutThousandsSeparator() {
    // Regression: L10n.format passes the user's locale to String(format:), so %d
    // showed fan speeds as "4,500 RPM" in the menu bar and the menu.
    expectEqual(L10n.formatCount("%d RPM", 4500), "4500 RPM",
                "an RPM count has no thousands separator")
    expectEqual(L10n.formatCount("%@ — %d RPM (%@)", "Fan 0", 4525, "Manual"),
                "Fan 0 — 4525 RPM (Manual)",
                "a menu row with an RPM count has no thousands separator")
}

// MARK: - Run

testFirstValidSampleIsAccepted()
testOutOfRangeSampleIsIgnored()
testMissingSampleHoldsLastValue()
testSmallStepIsAcceptedImmediately()
testSingleOutlierIsRejected()
testSustainedStepIsAcceptedAfterConfirmation()
testSustainedBatteryStepUsesBatteryCap()
testInterruptedConfirmationStartsOver()
testSlewLimiterUsesElapsedTimeNotWallClock()
testRequestReassertReissuesTheLastCommand()
testHistoryPersistsAcrossLaunches()
testRecordsCloserThanThirtySecondsAreSkipped()
testRecordsOlderThanRetentionArePruned()
testCorruptLineIsSkipped()
testExpiredLinesAreDroppedFromDiskOnLoad()
testLegacyUserDefaultsHistoryIsMigrated()
testTelemetryPublishesOnlyWhenValuesChange()
testMenuBarRoundsRPMAndPublishesOnlyWhenTheRoundedValueChanges()
testStarterRulesAreOffByDefault()
testStarterCPUCurveRampsGraduallyInsteadOfStepping()
testStarterBatteryCurveStaysGentle()
testCountsAreFormattedWithoutThousandsSeparator()
testMenuBarReservesWidthForTheWidestReadoutTheFanCanShow()

print("\(checks - failures.count)/\(checks) checks passed")
if !failures.isEmpty {
    exit(1)
}
