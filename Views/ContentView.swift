import SwiftUI

// MARK: - App Version
//
// `build.sh` is the single source of the marketing version: it writes
// `APP_VERSION` into `CFBundleShortVersionString` and into the DMG volume name.
// Reading it back out of the bundle is the only way the UI can agree with both
// without a second hardcoded copy that starts lying the moment `APP_VERSION` is
// bumped.
enum AppVersion {
    /// `CFBundleShortVersionString`, or a visible placeholder if the bundle is
    /// malformed. A placeholder beats a silent blank badge.
    static let current: String = {
        let raw = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "—" : trimmed
    }()
}

// MARK: - Main Content View
struct ContentView: View {
    @ObservedObject var viewModel: FanViewModel
    
    var body: some View {
        GeometryReader { geometry in
            // Available window height, rather than the panel's pixel resolution,
            // determines whether the first screen needs a more compact layout.
            let compactLayout = geometry.size.height < 900
            let horizontalPadding: CGFloat = compactLayout ? 16 : 24

            VStack(spacing: 0) {
            // Title Header Bar
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(L10n.text("Fan Control Center"))
                            .font(.system(size: compactLayout ? 18 : 20, weight: .black))
                            .foregroundColor(.white)
                        
                        // Rendered from the bundle rather than written out
                        // here, so the badge cannot drift from
                        // `CFBundleShortVersionString` (`build.sh`'s
                        // `APP_VERSION`). The `v` prefix and the interpolation
                        // shape are unchanged, so this stays a single
                        // unlocalized literal exactly as it was before — no new
                        // lookup key, and nothing for the .strings tables to
                        // gain or lose.
                        Text("v\(AppVersion.current)")
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue.opacity(0.2))
                            .foregroundColor(.blue)
                            .clipShape(.rect(cornerRadius: 6))
                    }
                    Text(L10n.text("Mac System SMC Monitoring & Adjustment"))
                        .font(.system(size: 11))
                        .foregroundColor(.gray)
                }
                
                Spacer()
                
                // Status Badge
                if !viewModel.isAuthorized {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 8, height: 8)
                            .accessibilityHidden(true)
                        Text(L10n.text("Authorization Required"))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.orange)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.04))
                    .clipShape(.rect(cornerRadius: 20))
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(L10n.text("Authorization Required"))
                }
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.top, compactLayout ? 16 : 24)
            .padding(.bottom, compactLayout ? 12 : 16)
            
            Divider()
                .background(Color.white.opacity(0.08))
            
            ScrollView {
                VStack(spacing: compactLayout ? 14 : 20) {
                    TempHistoryChartContainer(store: viewModel.history, compactLayout: compactLayout)
                        .padding(.horizontal, horizontalPadding)
                        .frame(maxWidth: .infinity)
                    
                    // Privilege setup card if helper not authorized
                    if !viewModel.isAuthorized {
                        VStack(alignment: .leading, spacing: 16) {
                            HStack(alignment: .top, spacing: 16) {
                                ZStack {
                                    Circle()
                                        .fill(Color.orange.opacity(0.15))
                                        .frame(width: 48, height: 48)
                                    Image(systemName: "lock.shield.fill")
                                        .font(.system(size: 24))
                                        .foregroundColor(.orange)
                                        .accessibilityHidden(true)
                                }
                                
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(L10n.text("Helper Authentication Required"))
                                        .font(.system(size: 16, weight: .bold))
                                        .foregroundColor(.white)
                                    
                                    Text(L10n.text("SMC (System Management Controller) fan modification requires root privileges. A local helper tool is bundled to perform these actions safely. Click below to authorize it (requires administrator password once)."))
                                        .font(.system(size: 13))
                                        .foregroundColor(.gray)
                                        .lineSpacing(4)
                                }
                            }
                            
                            if let error = viewModel.errorMessage {
                                Text(error)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(.red)
                                    .padding(8)
                                    .background(Color.red.opacity(0.1))
                                    .clipShape(.rect(cornerRadius: 6))
                            }
                            
                            Button(action: {
                                withAnimation {
                                    viewModel.authorize()
                                }
                            }) {
                                HStack {
                                    Spacer()
                                    Image(systemName: "key.fill")
                                        .accessibilityHidden(true)
                                    Text(L10n.text("Authorize & Enable Fan Adjustments"))
                                    Spacer()
                                }
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(.black)
                                .padding(.vertical, 10)
                                .background(Color.orange)
                                .clipShape(.rect(cornerRadius: 8))
                            }
                            .buttonStyle(PlainButtonStyle())
                            .accessibilityLabel(L10n.text("Authorize & Enable Fan Adjustments"))
                        }
                        .padding(20)
                        .background(Color.orange.opacity(0.04))
                        .clipShape(.rect(cornerRadius: 16))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(Color.orange.opacity(0.2), lineWidth: 1)
                        )
                        .padding(.horizontal, horizontalPadding)
                        .frame(maxWidth: .infinity)
                    }

                    // Fans List
                    if viewModel.fanCount == 0 {
                        VStack(spacing: 16) {
                            ProgressView()
                                .accessibilityLabel(L10n.text("Reading SMC registers..."))
                            Text(L10n.text("Reading SMC registers..."))
                                .font(.system(size: 12))
                                .foregroundColor(.gray)
                        }
                        .frame(height: 180)
                    } else {
                        VStack(spacing: 16) {
                            FanRowsView(
                                telemetry: viewModel.telemetry,
                                viewModel: viewModel,
                                compactLayout: compactLayout
                            )

                            // Fan synchronization belongs directly with the fan cards:
                            // it affects the two manual fan controls rather than the
                            // independent automatic-rule configuration below.
                            if viewModel.isAuthorized && viewModel.fanCount > 1 {
                                HStack {
                                    Toggle(isOn: $viewModel.linkedFans) {
                                        HStack(spacing: 6) {
                                            Image(systemName: "link")
                                                .foregroundColor(viewModel.linkedFans ? .teal : .gray)
                                                .accessibilityHidden(true)
                                            Text(L10n.text("Sync All Fans Together"))
                                                .font(.system(size: 13, weight: .bold))
                                                .foregroundColor(.white)
                                        }
                                    }
                                    .toggleStyle(SwitchToggleStyle(tint: .teal))

                                    Spacer()
                                }
                                .padding(.horizontal, compactLayout ? 4 : 8)
                            }
                        }
                        .padding(.horizontal, horizontalPadding)
                        .frame(maxWidth: .infinity)
                    }

                    // Preserve the monitoring → manual fans → automatic-rules
                    // reading order, while compact fan cards keep this section
                    // discoverable on lower notebook displays.
                    if viewModel.isAuthorized && viewModel.fanCount > 0 {
                        RulesEngineView(viewModel: viewModel)
                    }

                    // Secondary application-wide controls follow both the manual
                    // and automatic cooling controls.
                    if viewModel.isAuthorized && viewModel.fanCount > 0 {
                        VStack(spacing: 16) {
                            HStack {
                                Toggle(isOn: $viewModel.isAutoStart) {
                                    HStack(spacing: 6) {
                                        Image(systemName: "autostartstop")
                                            .foregroundColor(viewModel.isAutoStart ? .teal : .gray)
                                            .accessibilityHidden(true)
                                        Text(L10n.text("Start at login (background)"))
                                            .font(.system(size: 13, weight: .bold))
                                            .foregroundColor(.white)
                                    }
                                }
                                .toggleStyle(SwitchToggleStyle(tint: .teal))
                                .onValueChange(of: viewModel.isAutoStart) { newValue in
                                    viewModel.toggleAutoStart(newValue)
                                }

                                Spacer()
                            }

                            HStack {
                                Toggle(isOn: $viewModel.runInAccessoryMode) {
                                    HStack(spacing: 6) {
                                        Image(systemName: "square.dashed")
                                            .foregroundColor(viewModel.runInAccessoryMode ? .teal : .gray)
                                            .accessibilityHidden(true)
                                        Text(L10n.text("Run in accessory mode"))
                                            .font(.system(size: 13, weight: .bold))
                                            .foregroundColor(.white)
                                    }
                                }
                                .toggleStyle(SwitchToggleStyle(tint: .teal))

                                Spacer()
                            }

                            HStack {
                                Spacer()
                                Button(action: {
                                    viewModel.resetAll()
                                }) {
                                    HStack {
                                        Image(systemName: "arrow.counterclockwise")
                                            .accessibilityHidden(true)
                                        Text(L10n.text("Reset All to Auto"))
                                    }
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                                    .background(Color.white.opacity(0.08))
                                    .clipShape(.rect(cornerRadius: 8))
                                }
                                .buttonStyle(PlainButtonStyle())
                                .accessibilityLabel(L10n.text("Reset All to Auto"))
                            }
                        }
                        .padding(20)
                        .background(Color.white.opacity(0.02))
                        .clipShape(.rect(cornerRadius: 16))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(Color.white.opacity(0.04), lineWidth: 1)
                        )
                        .padding(.horizontal, horizontalPadding)
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.vertical, compactLayout ? 12 : 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        }
        .frame(minWidth: 600, maxWidth: .infinity, minHeight: 680, maxHeight: .infinity, alignment: .top)
        .background(Color(red: 0.08, green: 0.08, blue: 0.1))
        .background(WindowAccessor { window in
            // Stable handle used by the menu-bar entry point to find and order
            // this window back in front.
            window.identifier = NSUserInterfaceItemIdentifier("FanControlMainWindow")
            window.delegate = MainWindowDelegate.shared
            window.minSize = NSSize(width: 600, height: 680)
        })
    }
}

// MARK: - Forward-Compatible `onChange`
//
// `onChange(of:perform:)` with a single closure parameter is deprecated from
// macOS 14 in favour of the two-parameter form. Both spellings behave
// identically, so the modern one is used wherever it exists and the old one is
// confined to a helper that is itself deprecated for the same reason — which is
// what lets the app keep its macOS 13 deployment target while compiling warning
// free at every later target as well.
@available(macOS, deprecated: 14.0)
private func legacyOnChange<Content: View, Value: Equatable>(
    _ content: Content,
    of value: Value,
    perform action: @escaping (Value) -> Void
) -> some View {
    content.onChange(of: value, perform: action)
}

private struct CompatibleOnChange<Value: Equatable>: ViewModifier {
    let value: Value
    let action: (Value) -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.onChange(of: value) { _, newValue in action(newValue) }
        } else {
            legacyOnChange(content, of: value, perform: action)
        }
    }
}

extension View {
    /// `onChange(of:)` without deprecation warnings on macOS 13 through macOS 26.
    func onValueChange<Value: Equatable>(
        of value: Value,
        perform action: @escaping (Value) -> Void
    ) -> some View {
        modifier(CompatibleOnChange(value: value, action: action))
    }
}

// MARK: - Window Accessor and Delegate for Menu Bar Mode
struct WindowAccessor: NSViewRepresentable {
    var onWindowBind: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                onWindowBind(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

class MainWindowDelegate: NSObject, NSWindowDelegate {
    static let shared = MainWindowDelegate()

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}

// MARK: - Fan Cards

/// The fan cards. They observe the live fan readings on their own, so the
/// once-a-second update re-renders these cards and nothing else in the window.
private struct FanRowsView: View {
    @ObservedObject var telemetry: FanTelemetry
    let viewModel: FanViewModel
    let compactLayout: Bool

    var body: some View {
        ForEach(telemetry.fans) { fan in
            FanControlRow(
                fan: fan,
                viewModel: viewModel,
                compactLayout: compactLayout
            )
        }
    }
}