import SwiftUI
import AppKit
import ServiceManagement

// MARK: - View Model
//
// This type is an adapter. Every decision about what the fans should do lives in
// `Core/FanControlLaw.swift`; everything here is about getting samples in,
// publishing state out, and running the privileged helper safely.
class FanViewModel: ObservableObject {
    /// The one controller for the process. Create it only through this property:
    /// two instances would both poll the helper and both run the rules.
    static let shared = FanViewModel()

    /// Live fan readings and battery temperature. Observed by the fan cards and
    /// the menu, not by the whole window. See `ViewModels/FanStores.swift`.
    let telemetry = FanTelemetry()
    /// The menu bar's rounded RPM readout.
    let menuBar = MenuBarStatus()
    /// Rolling temperature history, observed only by the chart.
    let history = FanHistoryStore()

    /// The fans as last read from the helper.
    var fans: [FanJSON] { telemetry.fans }
    var batteryTemp: Double? { telemetry.batteryTemp }

    /// Fan count, published only when it changes. The window uses it to choose
    /// which sections to show, without observing the live fan list.
    @Published private(set) var fanCount = 0

    /// Live CPU and GPU readings. Plain values rather than published properties:
    /// nothing displays them, and publishing them would re-render the window on
    /// every poll. They feed the control law and the history.
    private var cpuTemp: Double? = nil
    private var gpuTemp: Double? = nil
    private var cpuConditioner = TemperatureConditioner(sensor: .cpu)
    private var gpuConditioner = TemperatureConditioner(sensor: .gpu)
    private var batteryConditioner = TemperatureConditioner(sensor: .battery)

    @Published var isAuthorized: Bool = false
    @Published var linkedFans: Bool = false
    @Published var errorMessage: String? = nil
    @Published var isPollingActive: Bool = false
    @Published var isAutoStart: Bool = SMAppService.mainApp.status == .enabled
    @Published var runInAccessoryMode: Bool = UserDefaults.standard.bool(forKey: "runInAccessoryMode") {
        didSet {
            UserDefaults.standard.set(runInAccessoryMode, forKey: "runInAccessoryMode")
            applyActivationPolicy()
        }
    }

    private func applyActivationPolicy() {
        let policy: NSApplication.ActivationPolicy = runInAccessoryMode ? .accessory : .regular
        NSApplication.shared.setActivationPolicy(policy)
    }

    @Published var rules: [TriggerRule] = [] {
        didSet {
            saveRules()
        }
    }
    @Published var isRulesEngineEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(isRulesEngineEnabled, forKey: "isRulesEngineEnabled")
            if !isRulesEngineEnabled {
                // `relinquishControl` reports whether the law was actually driving
                // the fans, so an already-idle engine does not issue a redundant
                // reset.
                if controlLaw.relinquishControl() {
                    resetAll()
                }
            }
        }
    }
    @Published var maximumCommandRiseRatePercentPerSecond: Double = 6.0 {
        didSet {
            UserDefaults.standard.set(
                maximumCommandRiseRatePercentPerSecond,
                forKey: "maximumCommandRiseRatePercentPerSecond"
            )
        }
    }
    @Published var maximumCommandFallRatePercentPerSecond: Double = 3.0 {
        didSet {
            UserDefaults.standard.set(
                maximumCommandFallRatePercentPerSecond,
                forKey: "maximumCommandFallRatePercentPerSecond"
            )
        }
    }
    @Published var coolingTemperatureHysteresis: Double = 5.0 {
        didSet {
            UserDefaults.standard.set(coolingTemperatureHysteresis, forKey: "coolingTemperatureHysteresis")
        }
    }
    @Published var minimumCommandChangePercent: Double = 4.0 {
        didSet {
            UserDefaults.standard.set(minimumCommandChangePercent, forKey: "minimumCommandChangePercent")
        }
    }
    @Published var coolingConfirmationSeconds: Double = 8.0 {
        didSet {
            UserDefaults.standard.set(coolingConfirmationSeconds, forKey: "coolingConfirmationSeconds")
        }
    }

    /// The thermal controller itself. Pure value type: no SwiftUI, no Process, no
    /// UserDefaults. See `Core/FanControlLaw.swift`.
    private var controlLaw = FanControlLaw()

    /// True once the poll watchdog has decided it can no longer confirm that this
    /// app still commands the fans, and has handed them back to macOS Auto.
    /// Cleared again as soon as a poll succeeds.
    @Published private(set) var hasRevertedToAutoAfterFailure: Bool = false

    private var timer: Timer? = nil
    @Published private(set) var isAppActive: Bool = true
    private var isStatusUpdateInProgress = false

    /// Consecutive failed status polls tolerated while the law believes it is
    /// driving the fans. At the one-second poll rate, five failures is about five
    /// seconds of lost telemetry: long enough to ride out a transient SMC or
    /// helper hiccup, short enough that a wedged helper cannot leave the fans
    /// latched at the last commanded RPM indefinitely.
    private let pollFailureRecoveryThreshold = 5
    private var consecutivePollFailures = 0

    /// Upper bound on how long one status read may take. A wedged setuid child
    /// would otherwise hold `isStatusUpdateInProgress` true forever, silently
    /// stopping all thermal polling for the rest of the session.
    private let statusPollTimeout: TimeInterval = 5.0

    /// Shown when the watchdog has given up on automatic control. Tracked as a
    /// constant so it can be cleared again without wiping an unrelated error.
    private static let controlLostMessage = L10n.text(
        "Automatic fan control stopped responding, so the fans were returned to automatic control."
    )

    var helperPath: String {
        let bundleHelper = Bundle.main.bundlePath + "/Contents/MacOS/smc-helper"
        if FileManager.default.fileExists(atPath: bundleHelper) {
            return bundleHelper
        }
        return FileManager.default.currentDirectoryPath + "/smc-helper"
    }

    /// Every helper write (`set`, `setall`, `reset`) runs here, one at a time, in
    /// the order it was requested. Writes used to run on a concurrent queue, so
    /// two of them could race on the shared `Ftst` unlock key, and a write could
    /// finish after the quit-time reset and leave the fans forced after exit.
    private let writeQueue = DispatchQueue(label: "com.pair.FanControl.helper-write", qos: .userInitiated)
    /// Writes requested and not yet finished. Counted on the main thread only.
    private var pendingWriteCount = 0
    /// Set once quitting has begun. Writes requested after this point are
    /// dropped, so nothing can re-apply a speed after the reset.
    private var isTerminating = false
    /// Consecutive polls that found a fan in automatic mode while the law believed
    /// it was in control. See `reassertIfFansReturnedToAuto`.
    private var consecutiveAutoPolls = 0
    /// When the drift re-send last fired, on the monotonic clock.
    private var lastDriftReassertTime: TimeInterval?
    /// Whether the most recent helper write exited cleanly. A failed write stops
    /// the drift re-send until a write succeeds, so a broken helper is not hammered.
    private var lastWriteSucceeded = true
    /// The drift re-send fires at most once in this many seconds.
    private static let driftReassertCooldown: TimeInterval = 30
    private var wakeObserver: NSObjectProtocol?

    private init() {
        checkAuthorization()
        loadRules()
        loadResponseSettings()
        observeSystemWake()
        startPolling()
    }

    deinit {
        if let wakeObserver = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    /// Sleep can reset the fans, and the readings from before it are stale. Ask the
    /// law to re-send its demand at the next poll, rather than trusting that the
    /// fans are still where it last put them.
    private func observeSystemWake() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.controlLaw.requestReassert()
        }
    }

    /// Seconds on a clock that keeps running through sleep and ignores changes to
    /// the wall clock. The slew limiter and the cooling confirmation both measure
    /// elapsed time on it.
    private static let monotonicOrigin = ContinuousClock.now

    static func monotonicNow() -> TimeInterval {
        let elapsed = monotonicOrigin.duration(to: ContinuousClock.now).components
        return TimeInterval(elapsed.seconds) + TimeInterval(elapsed.attoseconds) / 1e18
    }

    // MARK: - Authorization

    /// A helper is considered authorized when it is root-owned, setuid, and
    /// executable by the logged-in user.
    ///
    /// Group/other execute access is *required*, not a defect: the app launches
    /// the helper directly with `Process` rather than through `sudo`, so a mode
    /// that withholds execute from non-root users makes the helper unusable and
    /// every poll fails. What this check still catches is the genuinely wrong
    /// states — a helper that is not root-owned, is not setuid, is not executable
    /// at all, or is group/other *writable* (which would let an unprivileged user
    /// replace the binary that runs as root).
    private func helperAuthorizationStatus(atPath path: String) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
            return false
        }
        let ownerId = attributes[.ownerAccountID] as? Int ?? -1
        let posixPermissions = attributes[.posixPermissions] as? Int ?? 0

        let isRootOwned = ownerId == 0
        let isSetuid = (posixPermissions & 0o4000) != 0
        let isOwnerExecutable = (posixPermissions & 0o0100) != 0
        let isUserExecutable = (posixPermissions & 0o0010) != 0 || (posixPermissions & 0o0001) != 0
        // A setuid-root binary that anyone can write is a direct root compromise:
        // the attacker replaces the payload and the next invocation runs it as root.
        let isNotWritableByOthers = (posixPermissions & 0o022) == 0

        return isRootOwned
            && isSetuid
            && isOwnerExecutable
            && isUserExecutable
            && isNotWritableByOthers
    }

    func checkAuthorization() {
        let status = helperAuthorizationStatus(atPath: helperPath)
        DispatchQueue.main.async {
            self.isAuthorized = status
        }
    }

    /// Escapes `value` for embedding inside an AppleScript double-quoted literal.
    ///
    /// Without this a path containing `"` or a backslash ends the literal early
    /// and the remainder of the path is executed as AppleScript source, long
    /// before any shell quoting is involved.
    private static func appleScriptEscaped(_ value: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(value.count + 8)
        for character in value {
            switch character {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            default: escaped.append(character)
            }
        }
        return escaped
    }

    /// Wraps `value` in a single-quoted POSIX shell word, escaping any embedded
    /// single quote as `'\''`. This is the canonical POSIX idiom; the alternative
    /// — the unquoted `'\(path)'` interpolation this replaces — is broken by a
    /// single quote anywhere in the bundle path, which the user controls by
    /// choosing where to install the app.
    private static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    func authorize() {
        let path = helperPath
        guard FileManager.default.fileExists(atPath: path) else {
            self.errorMessage = L10n.text("Helper tool ‘smc-helper’ not found. Please verify project compilation.")
            return
        }

        // AppleScript unescaping happens first, then the shell sees the result, so
        // escape in that order: the literal must survive before the shell quotes.
        let quotedPath = Self.shellSingleQuoted(Self.appleScriptEscaped(path))

        // `chmod 4755` — setuid root, executable by the logged-in user.
        //
        // The helper MUST be executable by the user, because the app spawns it
        // directly with `Process`; it never runs it through `sudo`. A restrictive
        // mode therefore breaks the app outright: at `4700` (or `4750`, unless
        // the user happens to be in group `wheel`) the logged-in user cannot
        // execute it at all, `Process.run()` fails, and every poll is lost.
        // Foundation reports that `EACCES` as NSCocoaError Code=4, "the file
        // doesn't exist", which points at the wrong cause entirely.
        //
        // The setuid-root + world-executable combination is a real trade-off and
        // not something this design can eliminate: any local user can drive the
        // fans through the helper. It is bounded by the helper's minimal command
        // surface (`get`/`set`/`reset`) and by hardened runtime + library
        // validation, which block `DYLD_*` injection into the setuid binary.
        // Closing it properly requires an XPC privileged helper (SMJobBless)
        // that authenticates the connecting process — tracked as follow-up.
        let shellCommand = "chown root:wheel \(quotedPath) && chmod 4755 \(quotedPath)"

        let appleScriptSource = """
        do shell script "\(Self.appleScriptEscaped(shellCommand))" with administrator privileges
        """

        guard let appleScript = NSAppleScript(source: appleScriptSource) else {
            self.errorMessage = L10n.text("Failed to compile authorization script.")
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary? = nil
            appleScript.executeAndReturnError(&error)

            DispatchQueue.main.async {
                if let err = error {
                    let desc = err[NSAppleScript.errorMessage] as? String ?? L10n.text("Authorization rejected or failed.")
                    if desc.contains("Read-only file system") {
                        self.errorMessage = L10n.text("Move Fan Control to Applications before authorizing. The helper tool can’t be configured on a read-only disk image.")
                    } else {
                        self.errorMessage = desc
                    }
                    self.isAuthorized = false
                } else {
                    // Read the permissions back rather than trusting that the shell
                    // succeeded: a hardened runtime, an ACL, or a read-only volume
                    // can make the chmod a silent no-op.
                    self.isAuthorized = self.helperAuthorizationStatus(atPath: path)
                    if self.isAuthorized {
                        self.errorMessage = nil
                        self.updateStatus()
                    } else {
                        self.errorMessage = L10n.text("The helper tool could not be secured. It must be owned by root, carry the setuid bit, and not be writable by anyone else. Fan Control will not treat it as authorized.")
                    }
                }
            }
        }
    }

    // MARK: - Polling

    func startPolling() {
        timer?.invalidate()
        let interval = pollingInterval

        // `Timer.scheduledTimer` registers in `.default` mode only. The run loop
        // leaves that mode for the duration of any event-tracking interaction —
        // opening a SwiftUI `Menu` picker, resizing the window, dragging a slider
        // inside the `GeometryReader`/`ScrollView` layout — and a `.default`-only
        // timer does not fire for any of it. Automatic fan control silently
        // suspends for as long as the user keeps interacting. `.common` includes
        // `.default` plus every tracking mode, so the thermal poll keeps its
        // cadence regardless of what the UI is doing.
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.updateStatus()
        }
        timer.tolerance = interval * 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        updateStatus()
    }

    /// Records the app's activation state.
    ///
    /// Thermal protection deliberately does not depend on this. `pollingInterval`
    /// is fixed and the timer runs in `.common` modes, so the SMC is sampled at
    /// the same one-second cadence whether the app is frontmost, covered, or
    /// hidden, and automatic rules always have the same response time. Nothing
    /// about window visibility may be allowed to gate the poll.
    func setAppActive(_ isActive: Bool) {
        isAppActive = isActive
    }

    private var pollingInterval: TimeInterval {
        // Thermal protection is independent of the window's visibility. The SMC is
        // sampled at the same one-second cadence whether the app is frontmost,
        // covered, or hidden, so automatic rules always have the same response time.
        1.0
    }

    func updateStatus() {
        // A missing helper is checked here, before the in-progress flag is set,
        // because `recordPollFailure` deliberately does not count a poll that
        // never started.
        guard FileManager.default.fileExists(atPath: helperPath), !isStatusUpdateInProgress else { return }
        isStatusUpdateInProgress = true

        DispatchQueue.global(qos: .default).async {
            // Only stdout is decoded. The helper's stderr is diagnostics — see
            // `runHelper` for why the two must never share a pipe.
            let result = self.runHelper(arguments: ["get"], timeout: self.statusPollTimeout)

            guard result.terminationStatus != nil else {
                // The helper could not be launched, or it timed out and was
                // terminated. Nothing was written to stdout.
                DispatchQueue.main.async {
                    self.recordPollFailure()
                    self.isStatusUpdateInProgress = false
                }
                return
            }

            if let decoded = try? JSONDecoder().decode(SystemStatusJSON.self, from: result.standardOutput) {
                DispatchQueue.main.async {
                    self.clearHelperDiagnostic()
                    self.publishReadings(decoded)
                    if !self.isPollingActive {
                        self.isPollingActive = true
                    }
                    self.recordPollSuccess()
                    self.reassertIfFansReturnedToAuto(decoded.fans)
                    self.evaluateRules()
                    self.recordHistoryIfNeeded()
                    self.isStatusUpdateInProgress = false
                }
            } else {
                // The helper exits non-zero (or prints `{}` when `FNum` is
                // unreadable) on any failure. Either way this is a lost sample.
                //
                // Whatever the helper *did* say is reported rather than
                // discarded. Before stdout and stderr were split these
                // diagnostics were written into the very buffer being decoded:
                // one SMC error corrupted the payload, the decode failed
                // silently, and the only explanation was destroyed along with
                // the sample.
                DispatchQueue.main.async {
                    self.reportHelperOutput(result, command: "get", showInBanner: false)
                    self.recordPollFailure()
                    self.isStatusUpdateInProgress = false
                }
            }
        }
    }

    /// Waits for `task` to exit, giving up after `timeout`.
    ///
    /// Called only from the polling background queue, so the short sleep here
    /// never touches the main thread.
    private func waitForExit(_ task: Process, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while task.isRunning {
            if Date() >= deadline { return false }
            usleep(20_000)
        }
        return true
    }

    /// Stores one poll's readings. Telemetry and the menu bar publish only what
    /// changed. The conditioned temperatures stay plain values.
    private func publishReadings(_ decoded: SystemStatusJSON) {
        telemetry.apply(
            fans: decoded.fans,
            batteryTemp: batteryConditioner.accept(decoded.batteryTemp)
        )
        cpuTemp = cpuConditioner.accept(decoded.cpuTemp)
        gpuTemp = gpuConditioner.accept(decoded.gpuTemp)
        menuBar.update(
            firstFanRPM: decoded.fans.first?.currentSpeed,
            firstFanMaxRPM: decoded.fans.first?.maxSpeed
        )
        if fanCount != decoded.fans.count {
            fanCount = decoded.fans.count
        }
    }

    /// The law sends a command only when its own demand changes. If the firmware
    /// returns a fan to automatic on its own, the law would never notice. So while
    /// the law believes it is in control, a fan reported in automatic mode on two
    /// polls in a row is treated as lost, and the demand is sent again. Polls taken
    /// while a write is in flight are ignored, because the mode is changing.
    ///
    /// Three limits keep this from becoming a write every two seconds. It fires at
    /// most once per `driftReassertCooldown`. It does not fire after a failed write,
    /// so a helper that has lost authorization, or a fan that will not unlock, is
    /// not retried in a loop. And a fan that the user sets to Auto is forced back
    /// at most once per cooldown, not on every poll.
    private func reassertIfFansReturnedToAuto(_ polledFans: [FanJSON]) {
        guard controlLaw.wasRuleApplied, pendingWriteCount == 0, lastWriteSucceeded else {
            consecutiveAutoPolls = 0
            return
        }
        let anyFanAutomatic = polledFans.contains { FanMode(rawValue: $0.mode)?.isAutomatic == true }
        consecutiveAutoPolls = anyFanAutomatic ? consecutiveAutoPolls + 1 : 0
        guard consecutiveAutoPolls >= 2 else { return }

        let now = Self.monotonicNow()
        if let last = lastDriftReassertTime, now - last < Self.driftReassertCooldown {
            return
        }
        consecutiveAutoPolls = 0
        lastDriftReassertTime = now
        controlLaw.requestReassert()
    }

    private func recordPollSuccess() {
        consecutivePollFailures = 0
        if hasRevertedToAutoAfterFailure {
            hasRevertedToAutoAfterFailure = false
            if errorMessage == Self.controlLostMessage {
                errorMessage = nil
            }
        }
    }

    private func recordPollFailure() {
        // A missing helper is not counted: the file-presence guard above means we
        // never started a poll, and the app cannot have gained control without
        // one, so there is nothing to recover from.
        consecutivePollFailures += 1
        guard consecutivePollFailures >= pollFailureRecoveryThreshold else { return }

        // Re-arm so a later, separate outage can trigger the watchdog again.
        consecutivePollFailures = 0

        // A fan controller's core safety invariant is that if you cannot confirm
        // you are in control, you must not keep commanding. Without this, a helper
        // that stops answering leaves the fans pinned at the last commanded speed
        // with temperatures frozen at their last values and no recovery path.
        guard controlLaw.wasRuleApplied else { return }
        controlLaw.relinquishControl()
        resetAll()

        hasRevertedToAutoAfterFailure = true
        isPollingActive = false
        errorMessage = Self.controlLostMessage
    }

    // MARK: - Helper invocation

    /// Everything one helper invocation produced.
    ///
    /// The two channels are kept apart on purpose. stdout is the
    /// machine-readable channel — `get` writes a JSON document there and the app
    /// feeds those bytes straight to `JSONDecoder` — while stderr carries SMC
    /// diagnostics. They are never concatenated.
    private struct HelperResult {
        /// Raw bytes the helper wrote to stdout.
        var standardOutput: Data = Data()
        /// Human-readable diagnostics the helper wrote to stderr.
        var standardError: String = ""
        /// Exit status, or `nil` if the helper could not be run, timed out, or
        /// was terminated before reporting one.
        var terminationStatus: Int32?
    }

    /// Prefix marking `errorMessage` as a helper diagnostic rather than an
    /// authorization or watchdog message, so the poll success path can clear
    /// one without wiping the others.
    private static let helperDiagnosticPrefix = "smc-helper "

    private static func lastNonEmptyLine(_ text: String) -> String? {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
    }

    /// Routes one helper invocation's output into the app's diagnostics instead
    /// of dropping it.
    ///
    /// Both channels are consulted — stderr first — because they carry
    /// different things: `SMCLog` writes SMC diagnostics there, while a verb's
    /// own report is on stdout. Whichever has content wins, and only its last
    /// meaningful line is shown.
    ///
    /// - Parameters:
    ///   - result: what the helper produced.
    ///   - command: the verb, echoed into the message.
    ///   - showInBanner: whether a failure should also appear in `errorMessage`.
    ///     False for the once-per-second background `get` poll, where the poll
    ///     watchdog already owns the user-facing escalation and a banner per
    ///     tick would flash; false during `applicationWillTerminate`, where
    ///     there is no user left to show it to.
    ///
    /// - Important: only touches `errorMessage`, so it must be called from the
    ///   main thread.
    private func reportHelperOutput(_ result: HelperResult, command: String, showInBanner: Bool) {
        let detail = Self.lastNonEmptyLine(result.standardError)
            ?? Self.lastNonEmptyLine(String(decoding: result.standardOutput, as: UTF8.self))
        guard let detail else { return }

        // stdout carries "SUCCESS: ..." when a verb succeeds, so a line there is
        // only a failure when the exit status agrees.
        let failed = (result.terminationStatus ?? 1) != 0
        let summary = "\(Self.helperDiagnosticPrefix)\(command): \(detail)"
        print(summary)

        guard failed, showInBanner else { return }
        errorMessage = summary
    }

    /// Drops a stale helper diagnostic after a good sample, so a one-off SMC
    /// error does not sit in the banner until the next authorize or quit.
    private func clearHelperDiagnostic() {
        guard let message = errorMessage,
              message.hasPrefix(Self.helperDiagnosticPrefix) else { return }
        errorMessage = nil
    }

    /// Runs the privileged helper synchronously and captures both of its output
    /// channels separately.
    ///
    /// stdout and stderr get **separate** pipes and are reported separately.
    /// Pointing both at one pipe is the bug this replaces: the helper's `get`
    /// verb writes its JSON to stdout and `SMCLog` writes diagnostics to stderr,
    /// so a shared pipe put every logged SMC warning into the exact buffer the
    /// app decodes as JSON. One warning was enough to fail the decode, and the
    /// diagnostic explaining why was destroyed with it — thermal monitoring
    /// stopped with no trace.
    ///
    /// Both pipes are drained concurrently with the wait, which matters even
    /// though this helper's output is tiny: a pipe buffers roughly 64 KiB, a
    /// helper that filled it would block in `write` while the caller sat in
    /// `waitUntilExit()`, and nothing would break the tie.
    ///
    /// Callers on the main thread (`resetAllAndWait`) need the synchronous form;
    /// the asynchronous callers dispatch the same work to a background queue so
    /// there is exactly one invocation path.
    @discardableResult
    private func runHelper(arguments: [String], timeout: TimeInterval? = nil) -> HelperResult {
        let path = helperPath
        guard FileManager.default.fileExists(atPath: path) else { return HelperResult() }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        task.standardOutput = outputPipe
        task.standardError = errorPipe

        do {
            try task.run()
        } catch {
            // Foundation surfaces an `EACCES` on exec as NSCocoaError Code=4
            // ("the file doesn't exist") — see
            // https://developer.apple.com/forums/thread/726994. A helper whose
            // permissions deny the logged-in user therefore reports as *missing*
            // and sends people looking for a packaging problem instead of a mode
            // problem. Name the real possibilities explicitly.
            let nsError = error as NSError
            let denialHint = (nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileNoSuchFileError)
                ? " It may exist but be unexecutable by this user — check `ls -l` on the helper (it must be root-owned, setuid, and mode 4755; the app runs it directly, not via sudo)."
                : ""
            print("Helper invocation failed: \(error)\(denialHint)")
            return HelperResult()
        }

        // The drains start only after launch succeeds. Starting them before it
        // would mean waiting on EOF from a process that never ran — and
        // `Pipe()` holds its own write end, so that read would never return.
        // Launch is therefore the gate; the helper's few hundred bytes of
        // output sit comfortably inside the pipe buffer until these start.
        var outputData = Data()
        var errorData = Data()
        let drains = DispatchGroup()
        let drainQueue = DispatchQueue(
            label: "com.pair.FanControl.helper-drain",
            qos: .userInitiated,
            attributes: .concurrent
        )
        drains.enter()
        drainQueue.async {
            outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            drains.leave()
        }
        drains.enter()
        drainQueue.async {
            errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            drains.leave()
        }

        var result = HelperResult()
        if let timeout, !waitForExit(task, timeout: timeout) {
            stopHelper(task)
            print("Helper invocation timed out after \(timeout)s; terminated.")
        } else {
            task.waitUntilExit()
            result.terminationStatus = task.terminationStatus
        }

        // The pipes reach end-of-file only when the child's write ends close. If the
        // child survived even SIGKILL, do not wait on the drains, and do not read
        // buffers they may still be writing. The result stays "not run".
        guard drains.wait(timeout: .now() + 2) == .success else {
            return result
        }
        result.standardOutput = outputData
        result.standardError = String(decoding: errorData, as: UTF8.self)
        return result
    }

    /// Stops a helper that has run past its timeout: SIGTERM first, then SIGKILL if
    /// it is still alive. Both waits are bounded. A process stuck in the kernel can
    /// ignore SIGTERM, and an unbounded `waitUntilExit()` here would stop the poll
    /// loop for good, because the in-progress flag would never clear.
    private func stopHelper(_ task: Process) {
        task.terminate()
        if waitForExit(task, timeout: 1) { return }
        kill(task.processIdentifier, SIGKILL)
        _ = waitForExit(task, timeout: 2)
    }

    /// Queues one helper write on the serial write queue. Its outcome is reported,
    /// and the fans re-polled, on the main thread. Call from the main thread only.
    private func enqueueWrite(arguments: [String], command: String, showInBanner: Bool) {
        pendingWriteCount += 1
        writeQueue.async {
            let result = self.runHelper(arguments: arguments)
            DispatchQueue.main.async {
                self.pendingWriteCount -= 1
                self.lastWriteSucceeded = result.terminationStatus == 0
                self.reportHelperOutput(result, command: command, showInBanner: showInBanner)
                self.updateStatus()
            }
        }
    }

    func setFanMode(fanId: Int, mode: Int, speed: Int? = nil) {
        guard !isTerminating else { return }
        var args = ["set", "\(fanId)", "\(mode)"]
        if mode == 1, let spd = speed {
            args.append("\(spd)")
        }
        enqueueWrite(arguments: args, command: "set \(fanId)", showInBanner: true)
    }

    func changeFanMode(fanId: Int, mode: Int) {
        if linkedFans {
            if mode == 1 {
                // Every fan to its own minimum, which is fraction 0 of its range. One
                // helper run, so the fans are never unlocked concurrently.
                setAllToPercentage(0)
            } else {
                for fan in fans {
                    setFanMode(fanId: fan.id, mode: mode, speed: nil)
                }
            }
        } else {
            if let fan = fans.first(where: { $0.id == fanId }) {
                let targetSpeed = mode == 1 ? fan.minSpeed : nil
                setFanMode(fanId: fanId, mode: mode, speed: targetSpeed)
            }
        }
    }

    func changeFanSpeed(fanId: Int, speed: Int) {
        guard linkedFans else {
            setFanMode(fanId: fanId, mode: 1, speed: speed)
            return
        }

        guard let initiatingFan = fans.first(where: { $0.id == fanId }),
              initiatingFan.maxSpeed > initiatingFan.minSpeed else {
            // Unknown fan id, or one without a usable range: clamp the raw RPM per fan.
            for fan in fans {
                setFanMode(fanId: fan.id, mode: 1, speed: min(max(speed, fan.minSpeed), fan.maxSpeed))
            }
            return
        }

        // Linked fans share the initiating fan's position within *its own* range, so
        // with fan A at 1200–5000 and fan B at 1800–6200, asking A for 50% gives B
        // 50% of its own span, not the same raw RPM. `setall` applies
        // min + (max - min) * fraction to each fan. That is the projection the old
        // per-fan loop used, and it runs as one helper invocation, so the fans are
        // not unlocked concurrently.
        let fraction = (Double(speed) - Double(initiatingFan.minSpeed))
            / Double(initiatingFan.maxSpeed - initiatingFan.minSpeed)
        setAllToPercentage(min(max(fraction, 0), 1))
    }

    func resetAll() {
        guard !isTerminating else { return }
        enqueueWrite(arguments: ["reset"], command: "reset", showInBanner: true)
    }

    /// Synchronous sibling of `resetAll()`, for `applicationWillTerminate`.
    ///
    /// Runs the helper on the calling thread and waits for it. The process is
    /// about to exit, so dispatching to a background queue is not safe: the
    /// block may never run, and the fans would stay latched at the last manual
    /// or rules-driven RPM with nothing left to reclaim them.
    ///
    /// - Important: must be called from the main thread. It blocks that thread
    ///   for the duration of one helper invocation, which is a few SMC writes.
    /// How long the helper may run for a reset before it is stopped. The helper's own
    /// budget is `resetBudgetSeconds` (6 s), so this leaves a margin for the final
    /// relock write. It must be longer than that budget: the previous 5 s timeout
    /// could stop the helper mid-reset.
    private static let resetTimeout: TimeInterval = 8

    /// How long quitting waits for the reset, including any write that was already
    /// in flight ahead of it. Bounded, so a wedged helper cannot stop the app from
    /// quitting.
    private static let quitWaitTimeout: TimeInterval = 12

    func resetAllAndWait() {
        // Stop the poll first: a timer firing around the reset could otherwise
        // re-apply a speed after the fans were handed back.
        timer?.invalidate()
        timer = nil
        // From here on no new write may be queued, so nothing can re-apply a speed.
        isTerminating = true
        history.flush()

        // The reset joins the serial write queue behind any write already in flight,
        // so it runs after them and cannot be overtaken by them.
        let finished = DispatchSemaphore(value: 0)
        var result = HelperResult()
        writeQueue.async {
            result = self.runHelper(arguments: ["reset"], timeout: Self.resetTimeout)
            finished.signal()
        }
        guard finished.wait(timeout: .now() + Self.quitWaitTimeout) == .success else {
            print("Fan reset did not finish before quitting.")
            controlLaw.relinquishControl()
            return
        }

        // The helper's complaint is logged, but not put in the banner: the app
        // is quitting and has no window left to show it in.
        reportHelperOutput(result, command: "reset", showInBanner: false)
        controlLaw.relinquishControl()
    }

    /// Drives every fan to `pct` of **its own** min…max range.
    ///
    /// One `setall` helper invocation instead of one `set` process per fan: at
    /// the one-second poll rate the old shape forked N processes per tick, each
    /// re-opening its own `AppleSMC` connection and each racing the others for
    /// the single global `Ftst` unlock key. Sharing one connection also makes
    /// the unlock strictly more reliable, because the fans are handled
    /// sequentially rather than concurrently.
    ///
    /// Equivalence with the old loop is preserved in the helper: the same
    /// per-fan formula (`min + (max - min) * percent`, so fans with different
    /// spans each get the same *fraction*), the same SMC call sequence per fan,
    /// and — importantly — a failure on one fan no longer stops the rest, which
    /// is what N independent processes used to guarantee.
    ///
    /// `evaluateRules` already gates this on a >= 0.1 percent change, so it only
    /// runs when the command actually moves.
    func setAllToPercentage(_ pct: Double) {
        guard !isTerminating else { return }
        guard FileManager.default.fileExists(atPath: helperPath) else { return }
        // No fan list means nothing to command, exactly as the old loop over
        // `fans` did. It also keeps a helper that cannot read `FNum` from being
        // handed a percentage at all.
        guard !fans.isEmpty, pct.isFinite, (0.0...1.0).contains(pct) else { return }

        enqueueWrite(arguments: ["setall", "\(pct)"], command: "setall", showInBanner: true)
    }

    // MARK: - Rules

    /// Set while `loadRules()` is recovering from an undecodable stored payload.
    /// It stops the `rules` `didSet` from writing that recovery state back over
    /// the user's file — otherwise a read failure would destroy the very data
    /// the recovery path is trying to keep.
    private var suppressRuleSaving = false

    func saveRules() {
        guard !suppressRuleSaving else { return }
        if let encoded = try? JSONEncoder().encode(rules) {
            UserDefaults.standard.set(encoded, forKey: "triggerRules")
        }
    }

    func loadRules() {
        isRulesEngineEnabled = UserDefaults.standard.bool(forKey: "isRulesEngineEnabled")

        // "No stored rules" and "stored rules that failed to decode" must not be
        // treated as the same thing. Seeding sensible starters on a first run is
        // helpful; silently replacing a user's existing configuration is data
        // loss, and because `rules` has a `didSet` that saves, the substitution
        // was written straight back over the original bytes. A rules file written
        // by a newer version, or hand-edited into an invalid shape, would
        // therefore destroy itself on the next launch with no trace and no
        // warning — the user just finds their thresholds gone and the engine
        // mysteriously inert.
        //
        // On a decode failure the stored data is left untouched on disk and the
        // engine is disabled, so an unrecognised configuration fails safe
        // (macOS keeps driving the fans) and visibly, rather than quietly.
        guard let data = UserDefaults.standard.data(forKey: "triggerRules") else {
            self.rules = TriggerRule.starterRules
            return
        }

        do {
            self.rules = try JSONDecoder().decode([TriggerRule].self, from: data)
        } catch {
            print("Stored trigger rules could not be decoded (\(error)); leaving them on disk untouched and disabling the rules engine.")
            // Assigning an empty array here would itself fire `didSet` ->
            // `saveRules()` and overwrite the very bytes we are trying to
            // preserve. `suppressRuleSaving` makes that assignment a
            // display-only reset.
            suppressRuleSaving = true
            self.rules = []
            if isRulesEngineEnabled {
                errorMessage = L10n.text("Saved trigger rules could not be read and were left unchanged. The automatic rules engine is off; re-add your rules to use it again.")
            }
            isRulesEngineEnabled = false
            suppressRuleSaving = false
        }
    }

    private func loadResponseSettings() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "maximumCommandRiseRatePercentPerSecond") != nil {
            maximumCommandRiseRatePercentPerSecond = defaults.double(
                forKey: "maximumCommandRiseRatePercentPerSecond"
            )
        }
        if defaults.object(forKey: "maximumCommandFallRatePercentPerSecond") != nil {
            maximumCommandFallRatePercentPerSecond = defaults.double(
                forKey: "maximumCommandFallRatePercentPerSecond"
            )
        }
        if defaults.object(forKey: "coolingTemperatureHysteresis") != nil {
            coolingTemperatureHysteresis = defaults.double(forKey: "coolingTemperatureHysteresis")
        }
        if defaults.object(forKey: "minimumCommandChangePercent") != nil {
            minimumCommandChangePercent = defaults.double(forKey: "minimumCommandChangePercent")
        }
        if defaults.object(forKey: "coolingConfirmationSeconds") != nil {
            coolingConfirmationSeconds = defaults.double(forKey: "coolingConfirmationSeconds")
        }
    }

    /// Pushes the published tuning values into the law. Done immediately before
    /// every evaluation so the law can never run against a stale preference, and
    /// so it does not have to reach into `UserDefaults` itself.
    private func syncControlLawTuning() {
        controlLaw.maximumCommandRiseRatePercentPerSecond = maximumCommandRiseRatePercentPerSecond
        controlLaw.maximumCommandFallRatePercentPerSecond = maximumCommandFallRatePercentPerSecond
        controlLaw.coolingTemperatureHysteresis = coolingTemperatureHysteresis
        controlLaw.minimumCommandChangePercent = minimumCommandChangePercent
        controlLaw.coolingConfirmationSeconds = coolingConfirmationSeconds
    }

    func evaluateRules() {
        guard isRulesEngineEnabled else { return }

        syncControlLawTuning()

        let decision = controlLaw.evaluate(
            rules: rules,
            temperatures: FanControlLaw.SensorTemperatures(
                cpu: cpuTemp,
                gpu: gpuTemp,
                battery: batteryTemp
            ),
            now: Self.monotonicNow()
        )

        switch decision {
        case .hold:
            break
        case .apply(let percent):
            setAllToPercentage(percent)
        case .releaseToAuto:
            resetAll()
        }
    }

    func getTempFor(sensor: TriggerRule.SensorType) -> Double? {
        switch sensor {
        case .cpu: return cpuTemp
        case .gpu: return gpuTemp
        case .battery: return batteryTemp
        }
    }

    func toggleAutoStart(_ newValue: Bool) {
        do {
            if (newValue) {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch { }
        isAutoStart = SMAppService.mainApp.status == .enabled
    }

    // MARK: - Temperature History

    /// Hands the poll's readings to the history store, which keeps one sample every
    /// 30 seconds and writes it to disk in the background.
    private func recordHistoryIfNeeded() {
        history.recordIfDue(
            now: Date(),
            cpu: cpuTemp,
            gpu: gpuTemp,
            battery: batteryTemp,
            fanTargetPercent: FanControlLaw.highestFanTargetPercent(fans: fans)
        )
    }
}
