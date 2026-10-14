import SwiftUI
import AppKit

// MARK: - Application Delegate

/// AppKit-side application lifecycle.
///
/// Fan targets written through the helper are latched in SMC hardware and stay
/// there after this process exits. Nothing releases them on its own, so this
/// delegate is the single place that guarantees the fans are handed back to the
/// system thermal controller before the process goes away.
final class FanControlAppDelegate: NSObject, NSApplicationDelegate {
    /// Posted when the app is asked to bring its main window forward — e.g. a Dock
    /// click with no visible windows. Bridges AppKit's reopen callback to the
    /// SwiftUI scene, which is what owns the window.
    static let showMainWindowNotification = Notification.Name("FanControlShowMainWindow")

    /// The identifier `ContentView`'s `WindowAccessor` stamps on the main window.
    static let mainWindowIdentifier = "FanControlMainWindow"

    /// Set by `FanControlApp` as soon as the shared view model exists.
    private var viewModel: FanViewModel?

    /// The fans are released at most once per process: `applicationShouldTerminate`,
    /// `applicationWillTerminate` and the signal handlers all funnel into
    /// `releaseFansToAutomaticControl()`.
    private var hasReleasedFans = false

    /// Weak — AppKit / SwiftUI own the window's lifetime.
    private weak var cachedMainWindow: NSWindow?

    /// Retained for the lifetime of the process; a released dispatch source stops
    /// delivering its signal.
    private var terminationSignalSources: [DispatchSourceSignal] = []

    /// A wedged helper must not turn "quit" into "hang forever".
    private static let terminationGracePeriod: TimeInterval = 10

    // MARK: Wiring

    func attach(viewModel: FanViewModel) {
        self.viewModel = viewModel
        installTerminationSignalHandlers()
    }

    // MARK: Termination

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Best effort here so the fans are already back under system control
        // before AppKit starts tearing the app down; `applicationWillTerminate`
        // below is the last-resort backstop and the guard makes this a one-shot.
        releaseFansToAutomaticControl()
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        releaseFansToAutomaticControl()
    }

    /// Hands every fan back to automatic control.
    ///
    /// `resetAllAndWait()` runs the helper synchronously — the whole point is that
    /// the reset has to have completed before this process disappears, an async
    /// `resetAll()` would simply be cancelled by exit. It is only ever reached on
    /// a termination path, and the view model guards on the helper actually being
    /// present, so an unauthorized app just does nothing.
    ///
    /// Every caller runs on the main thread (AppKit callbacks and the `.main`
    /// dispatch queue below), so `hasReleasedFans` needs no locking.
    private func releaseFansToAutomaticControl() {
        guard !hasReleasedFans else { return }
        hasReleasedFans = true

        // Armed only on a termination path. AppKit has normally already exited the
        // process by the time this could fire; it only matters if the helper hangs.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.terminationGracePeriod) {
            exit(0)
        }

        viewModel?.resetAllAndWait()
    }

    /// `⌘Q` reaches AppKit, but `killall`/`kill` send `SIGTERM` and force quit
    /// sends `SIGKILL`. AppKit is not told about the first, so the release is
    /// wired up here as well. `SIGKILL` cannot be caught by any process — a
    /// force quit will still leave the last written target latched.
    private func installTerminationSignalHandlers() {
        guard terminationSignalSources.isEmpty else { return }

        for signalNumber in [SIGTERM, SIGINT, SIGHUP] {
            // Hand the signal to the dispatch source instead of the default
            // disposition, which would terminate us before the reset runs.
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { [weak self] in
                self?.releaseFansToAutomaticControl()
                exit(0)
            }
            source.resume()
            terminationSignalSources.append(source)
        }
    }

    // MARK: Window

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // The main window is ordered out rather than closed when it is dismissed,
        // so AppKit has nothing to restore on its own. Ask the scene to show it.
        guard !flag else { return true }
        NotificationCenter.default.post(name: Self.showMainWindowNotification, object: nil)
        return true
    }

    func presentMainWindow() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        guard let window = mainWindowCandidate() else { return }
        window.makeKeyAndOrderFront(nil)
    }

    /// `NSApplication.shared.windows` also contains the menu bar extra's own
    /// hosting window, so `windows.first` is not necessarily the main window.
    private func mainWindowCandidate() -> NSWindow? {
        let windows = NSApplication.shared.windows
        let identifier = NSUserInterfaceItemIdentifier(Self.mainWindowIdentifier)

        // Preferred: the identifier the `WindowAccessor` in `ContentView` sets.
        if let window = windows.first(where: { $0.identifier == identifier }) {
            cachedMainWindow = window
            return window
        }

        // A window found earlier, as long as it is still alive.
        if let cached = cachedMainWindow, windows.contains(where: { $0 === cached }) {
            return cached
        }

        // Fallback for a build where the identifier is not set yet: the menu bar
        // extra is hosted in an `NSPanel`, the app's scene is a titled `NSWindow`.
        let fallback = windows.first {
            !($0 is NSPanel) && $0.styleMask.contains(.titled) && $0.contentViewController != nil
        }
        cachedMainWindow = fallback
        return fallback
    }
}

// MARK: - Menu Bar Extra Views

/// Contents of the menu bar extra menu.
///
/// Kept separate from `FanControlApp` on purpose: `fans` is republished about
/// once a second, and reading it directly in `FanControlApp.body` subscribed the
/// whole app — including the main window's scene — to that update, rebuilding the
/// entire scene graph every second. Only this menu needs the fan list, so only
/// this view subscribes to it.
private struct FanMenuBarContent: View {
    @ObservedObject var telemetry: FanTelemetry
    /// Used for the menu's actions only, so the menu does not observe the whole view model.
    let viewModel: FanViewModel
    let presentMainWindow: () -> Void

    var body: some View {
        Group {
            ForEach(telemetry.fans) { fan in
                Button(L10n.formatCount(
                    "%@ — %d RPM (%@)",
                    fan.name,
                    fan.currentSpeed,
                    L10n.text(fan.mode == 1 ? "Manual" : "Auto")
                ), action: presentMainWindow)
            }

            if let battery = telemetry.batteryTemp {
                Button(L10n.format("Battery temperature: %.1f°C", battery), action: presentMainWindow)
            }

            Divider()

            Button(L10n.text("Open Fan Control Center..."), action: presentMainWindow)

            Button(L10n.text("Reset All to Auto")) {
                viewModel.resetAll()
            }

            Divider()

            Button(L10n.text("Manual: 20% Speed")) {
                viewModel.setAllToPercentage(0.20)
            }

            Button(L10n.text("Manual: 40% Speed")) {
                viewModel.setAllToPercentage(0.40)
            }

            Button(L10n.text("Manual: 50% Speed")) {
                viewModel.setAllToPercentage(0.50)
            }

            Button(L10n.text("Manual: 80% Speed")) {
                viewModel.setAllToPercentage(0.80)
            }

            Button(L10n.text("Manual: MAX Speed")) {
                viewModel.setAllToPercentage(1.00)
            }

            Divider()

            Button(L10n.text("Quit")) {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}

/// Label shown in the menu bar.
///
/// Deliberately an icon *and* a text, which means a two-child composition.
/// `Label` is the other obvious candidate and it is not usable here: measured on
/// macOS 27.2, both `Label("…", systemImage:)` and the `Label { } icon: { }`
/// form render the **icon only** and silently drop the speed readout. A bare
/// `Text` renders the readout but drops the icon, and `Text(Image) + Text(…)`
/// also drops the image. The `HStack` renders both, so it stays.
///
/// The reading is built with `L10n.formatCount`, which keeps a plain integer.
/// Both `Text`'s interpolation and `L10n.format` (which passes the locale) group
/// the digits with the locale's separator, so the readout showed as "4,500 RPM".
private struct FanMenuBarLabel: View {
    @ObservedObject var status: MenuBarStatus

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "fanblades")
            if let rpm = status.roundedRPM {
                // The readout sits in a slot as wide as the widest value this fan can
                // show. The hidden text is laid out but not drawn, so the menu-bar item
                // keeps one width while the value changes. Digits are proportional in
                // the menu-bar font, which is why the width changed with the value. The
                // value changes only when the rounded value does, so the item is not
                // redrawn on every poll.
                ZStack(alignment: .leading) {
                    Text(L10n.formatCount("%d RPM", status.reservedRPM))
                        .monospacedDigit()
                        .hidden()
                    Text(L10n.formatCount("%d RPM", rpm))
                        .monospacedDigit()
                }
            } else {
                // Polling starts before the first fan list arrives.
                Text(L10n.text("Fan Control"))
            }
        }
    }
}

// MARK: - App

@main
struct FanControlApp: App {
    @NSApplicationDelegateAdaptor(FanControlAppDelegate.self) private var appDelegate
    // SwiftUI may evaluate this initial value more than once, and an extra
    // `FanViewModel` polls the helper and runs the rules on its own. Measured on the
    // previous build: two instances were alive at once, both controlling the fans.
    @StateObject private var viewModel = FanViewModel.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Hand the view model to the delegate before anything can terminate the
        // app, so the fan release is never missed. This also starts the signal
        // handlers as early as possible.
        appDelegate.attach(viewModel: viewModel)

        // Keep the app launchable without assuming one activation policy.
        // A real `.icns` is picked up by AppKit on its own via `CFBundleIconFile`;
        // the PNG is the fallback for builds that only ship the bitmap.
        for pathExtension in ["icns", "png"] {
            if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: pathExtension),
               let icon = NSImage(contentsOf: iconURL) {
                NSApplication.shared.applicationIconImage = icon
                break
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            mainSceneContent
        }
        .windowStyle(HiddenTitleBarWindowStyle())
        .defaultSize(width: 960, height: 900)

        MenuBarExtra {
            FanMenuBarContent(telemetry: viewModel.telemetry, viewModel: viewModel) {
                appDelegate.presentMainWindow()
            }
        } label: {
            FanMenuBarLabel(status: viewModel.menuBar)
        }
    }

    /// The deployment target is 13.0, so the two-parameter `onChange` overload
    /// introduced in macOS 14 is not unconditionally available. Both branches are
    /// kept; the `if #available` is evaluated once, at view construction.
    @ViewBuilder
    private var mainSceneContent: some View {
        if #available(macOS 14, *) {
            sceneContent
                .onChange(of: scenePhase) { _, newPhase in
                    viewModel.setAppActive(newPhase == .active)
                }
        } else {
            sceneContent
                .onChange(of: scenePhase) { newPhase in
                    viewModel.setAppActive(newPhase == .active)
                }
        }
    }

    private var sceneContent: some View {
        ContentView(viewModel: viewModel)
            .preferredColorScheme(.dark)
            .onAppear {
                viewModel.setAppActive(scenePhase == .active)
                if viewModel.runInAccessoryMode {
                    NSApplication.shared.setActivationPolicy(.accessory)
                }
            }
            .onReceive(NotificationCenter.default.publisher(
                for: FanControlAppDelegate.showMainWindowNotification
            )) { _ in
                appDelegate.presentMainWindow()
            }
    }
}