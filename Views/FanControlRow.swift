import SwiftUI

// MARK: - Individual Fan Control Row
struct FanControlRow: View {
    let fan: FanJSON
    @ObservedObject var viewModel: FanViewModel
    let compactLayout: Bool
    
    @State private var sliderVal: Double = 0.0
    @State private var isEditingSlider: Bool = false
    /// Last value pushed to the helper. The 1 Hz SMC poll can deliver a target
    /// that predates our own write; without remembering what we asked for, the
    /// thumb snaps back to that stale value the moment the drag ends.
    @State private var lastRequestedSpeed: Int?
    
    init(fan: FanJSON, viewModel: FanViewModel, compactLayout: Bool = false) {
        self.fan = fan
        self.viewModel = viewModel
        self.compactLayout = compactLayout
        // Initial setup of state. The target can legitimately sit outside the
        // fan's min/max window while the helper is still reconciling, so clamp
        // it here rather than letting the slider show an out-of-range thumb.
        let window = Double(fan.minSpeed)...Double(max(fan.minSpeed, fan.maxSpeed))
        _sliderVal = State(initialValue: Double(fan.targetSpeed).clampedTo(window))
    }
    
    var body: some View {
        HStack(alignment: .center, spacing: compactLayout ? 12 : 18) {
            fanIndicator

            VStack(alignment: .leading, spacing: compactLayout ? 6 : 10) {
                header
                manualControls
                autoNotice
            }
        }
        .padding(compactLayout ? 12 : 18)
        .background(Color.white.opacity(0.03))
        .clipShape(.rect(cornerRadius: compactLayout ? 12 : 16))
        .overlay(
            RoundedRectangle(cornerRadius: compactLayout ? 12 : 16)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear(perform: resyncSlider)
        // Keep slider synchronized with system status updates if user is not actively dragging it
        .compatOnChange(of: fan.targetSpeed) { newTarget in
            guard !isEditingSlider else { return }
            // Ignore an echo of a value we ourselves just requested; anything
            // else is a real change made elsewhere and must be reflected.
            guard newTarget != lastRequestedSpeed else { return }
            sliderVal = Double(newTarget).clampedTo(speedRange)
        }
    }
    
    // MARK: - Subviews
    
    private var fanIndicator: some View {
        SpinningFanView(currentSpeed: Double(fan.currentSpeed), maxSpeed: Double(fan.maxSpeed))
            // NSViewRepresentable must be constrained explicitly; otherwise
            // SwiftUI may offer it the entire width of a resized row.
            // Treat the fan as the leading visual column, not as a small
            // top-aligned badge beside a taller group of controls.
            .frame(width: compactLayout ? 88 : 140, height: compactLayout ? 88 : 140)
            // Purely decorative; the RPM readout below carries the real value.
            .accessibilityHidden(true)
    }
    
    private var header: some View {
        HStack(alignment: .top) {
            fanIdentity
            Spacer(minLength: 12)
            modePicker
        }
    }
    
    private var fanIdentity: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L10n.text(fan.name))
                .font(.system(size: compactLayout ? 14 : 16, weight: .bold))
                .foregroundColor(.white)
            rpmReadout
        }
    }
    
    private var rpmReadout: some View {
        HStack(spacing: 8) {
            Text(verbatim: rpmText)
                .font(.system(size: compactLayout ? 21 : 26, weight: .black, design: .monospaced))
                .foregroundColor(rpmColor)
            Text(L10n.text("RPM"))
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.gray)
                .offset(y: 4)
                .accessibilityHidden(true)
        }
        // One element carries both the number and its unit, so VoiceOver reads
        // "revolutions per minute, 4821" instead of two disconnected fragments.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(L10n.text("RPM")))
        .accessibilityValue(Text(verbatim: rpmAccessibilityValue))
    }
    
    private var modePicker: some View {
        Picker("", selection: Binding(
            get: { fan.mode },
            set: { newMode in
                viewModel.changeFanMode(fanId: fan.id, mode: newMode)
            }
        )) {
            Text(L10n.text("Auto")).tag(0)
            Text(L10n.text("Manual")).tag(1)
        }
        .pickerStyle(SegmentedPickerStyle())
        .labelsHidden()
        .frame(width: compactLayout ? 128 : 150)
        .accessibilityLabel(Text(L10n.text("Fan control mode")))
        .accessibilityHint(Text(L10n.text("Auto lets the Mac thermal controller manage this fan.")))
    }
    
    @ViewBuilder
    private var manualControls: some View {
        if fan.mode == 1 {
            VStack(spacing: compactLayout ? 5 : 8) {
                targetSpeedCaption
                targetSpeedSlider
                presetRow
            }
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }
    
    private var targetSpeedCaption: some View {
        HStack {
            Text(L10n.text("Target Speed"))
                .font(.system(size: compactLayout ? 10 : 12, weight: .semibold))
                .foregroundColor(.gray)
            Spacer()
            // The slider below carries the accessible name and value, so this
            // readout must not be announced a second time.
            Text(verbatim: targetSpeedText)
                .font(.system(size: compactLayout ? 10 : 12, weight: .bold, design: .monospaced))
                .foregroundColor(.teal)
                .accessibilityHidden(true)
        }
    }
    
    private var targetSpeedSlider: some View {
        Slider(
            value: $sliderVal,
            in: speedRange,
            step: speedStep,
            onEditingChanged: handleSliderEditing
        )
            .compatTint(.teal)
            .disabled(!hasKnownSpeed)
            .accessibilityLabel(Text(L10n.text("Target Speed")))
            .accessibilityValue(Text(verbatim: targetSpeedText))
    }
    
    private var presetRow: some View {
        HStack(spacing: compactLayout ? 5 : 8) {
            presetButton(title: "Min", val: Double(fan.minSpeed), compact: compactLayout)
            presetButton(title: "20%", val: getSpeedForPercentage(0.20), compact: compactLayout)
            presetButton(title: "50%", val: getSpeedForPercentage(0.50), compact: compactLayout)
            presetButton(title: "80%", val: getSpeedForPercentage(0.80), compact: compactLayout)
            presetButton(title: "Max", val: Double(fan.maxSpeed), compact: compactLayout)
        }
        .disabled(!hasKnownSpeed)
    }
    
    @ViewBuilder
    private var autoNotice: some View {
        if fan.mode != 1 && !compactLayout {
            Label(L10n.text("Mac system thermal controller is managing this fan."), systemImage: "cpu")
                .font(.system(size: 12))
                .foregroundColor(.gray)
                .padding(.top, 2)
        }
    }
    
    // MARK: - Derived speed state
    
    /// `FMn`/`FMx` can transiently read back as `0`/`0` when an SMC lookup fails.
    /// A zero maximum is therefore "unknown", not "stopped": without this the
    /// fan would be reported as a plausible-looking 0 RPM in idle blue, and the
    /// speed slider would collapse to the degenerate range `0...0`.
    private var hasKnownSpeed: Bool {
        fan.maxSpeed > 0
    }
    
    /// Never hand SwiftUI a zero-width or inverted range.
    private var speedRange: ClosedRange<Double> {
        let low = Double(fan.minSpeed)
        let high = Double(fan.maxSpeed)
        guard high > low else { return low...(low + 1) }
        return low...high
    }
    
    /// Slider detent, derived from the fan's actual window. The previous fixed
    /// `50.0` was coarser than the whole span of some fans, which left the knob
    /// able to reach only one or two usable values.
    private var speedStep: Double {
        let span = speedRange.upperBound - speedRange.lowerBound
        guard span > 0 else { return 1 }
        // Aim for roughly 100 detents, snapped up to a round number.
        let target = span / 100.0
        let candidates: [Double] = [1, 5, 10, 25, 50, 100, 250]
        if let step = candidates.first(where: { $0 >= target }) { return step }
        return max(1, (target / 250).rounded(.up) * 250)
    }
    
    private var rpmText: String {
        hasKnownSpeed ? "\(fan.currentSpeed)" : "—"
    }
    
    private var rpmAccessibilityValue: String {
        hasKnownSpeed ? "\(fan.currentSpeed)" : L10n.text("Speed unavailable")
    }
    
    private var targetSpeedText: String {
        guard hasKnownSpeed else { return "—" }
        return L10n.format("%.0f RPM (%.0f%%)", sliderVal, speedPercentage)
    }
    
    private var rpmColor: Color {
        // A failed read is grey, never a confident "idle" blue.
        guard hasKnownSpeed else { return .gray }
        let ratio = Double(fan.currentSpeed) / Double(fan.maxSpeed)
        if ratio > 0.75 {
            return .orange
        } else if ratio > 0.4 {
            return .teal
        } else {
            return .blue
        }
    }
    
    private var speedPercentage: Double {
        let range = Double(fan.maxSpeed - fan.minSpeed)
        guard range > 0 else { return 0 }
        return ((sliderVal - Double(fan.minSpeed)) / range) * 100.0
    }
    
    private func getSpeedForPercentage(_ pct: Double) -> Double {
        let range = Double(fan.maxSpeed - fan.minSpeed)
        guard range > 0 else { return Double(fan.minSpeed) }
        return Double(fan.minSpeed) + range * pct
    }
    
    private func handleSliderEditing(_ editing: Bool) {
        isEditingSlider = editing
        guard !editing else { return }
        commitSliderSpeed()
    }
    
    /// Push the current slider value to the helper and remember it, so a late
    /// poll carrying the pre-change target does not roll the thumb back.
    private func commitSliderSpeed() {
        lastRequestedSpeed = Int(sliderVal)
        viewModel.changeFanSpeed(fanId: fan.id, speed: Int(sliderVal))
    }
    
    /// The fan's window can change between construction and first render.
    private func resyncSlider() {
        sliderVal = sliderVal.clampedTo(speedRange)
    }
    
    private func presetButton(title: String, val: Double, compact: Bool) -> some View {
        Button(action: {
            sliderVal = val.clampedTo(speedRange)
            commitSliderSpeed()
        }) {
            Text(L10n.text(title))
                .font(.system(size: compact ? 9 : 11, weight: .bold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, compact ? 4 : 6)
                .background(Color.white.opacity(0.06))
                .clipShape(.rect(cornerRadius: 8))
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel(Text(L10n.text(title)))
        .accessibilityValue(Text(verbatim: presetAccessibilityValue(for: val)))
    }
    
    private func presetAccessibilityValue(for val: Double) -> String {
        hasKnownSpeed ? L10n.format("%.0f RPM", val) : L10n.text("Speed unavailable")
    }
}