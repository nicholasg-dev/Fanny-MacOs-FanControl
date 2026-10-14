import SwiftUI

// MARK: - macOS 13 / 14 compatibility shims
//
// `build.sh` still pins `MACOS_DEPLOYMENT_TARGET` to 13.0, so the macOS 14
// spellings of the deprecated APIs used by these views (`tint`, the two
// parameter `onChange`, `.toggleStyle(.switch)`) cannot simply be adopted.
// Each shim picks the macOS 14 spelling at runtime when it exists and falls back
// to the 13.x spelling otherwise, so one source file compiles cleanly for both
// deployment targets. If the minimum is ever raised to macOS 14 the `else`
// branches become dead code that can be deleted wholesale.
//
// `cornerRadius` needs no shim: `clipShape(.rect(cornerRadius:))` exists since
// macOS 12 and renders identically for the solid-background shapes used here.

struct CompatTintModifier: ViewModifier {
    let tint: Color

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.tint(tint)
        } else {
            content.accentColor(tint)
        }
    }
}

struct CompatSwitchToggleStyleModifier: ViewModifier {
    let tint: Color

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.toggleStyle(.switch).tint(tint)
        } else {
            content.toggleStyle(SwitchToggleStyle(tint: tint))
        }
    }
}

struct CompatOnChangeModifier<Value: Equatable>: ViewModifier {
    let value: Value
    let action: (Value) -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.onChange(of: value) { _, newValue in action(newValue) }
        } else {
            content.onChange(of: value) { newValue in action(newValue) }
        }
    }
}

extension Comparable {
    /// Local stand-in for the SwiftUI `clamped(to:)` added in macOS 15, which is
    /// `package`-level and therefore invisible to this target.
    func clampedTo(_ limits: ClosedRange<Self>) -> Self {
        min(max(self, limits.lowerBound), limits.upperBound)
    }
}

extension View {
    /// `View.tint(_:)` on macOS 14+, `View.accentColor(_:)` on macOS 13.
    func compatTint(_ tint: Color) -> some View {
        modifier(CompatTintModifier(tint: tint))
    }

    /// `SwitchToggleStyle(tint:)` is deprecated on macOS 14 in favour of
    /// `.toggleStyle(.switch).tint(_:)`.
    func compatSwitchToggleStyle(tint: Color) -> some View {
        modifier(CompatSwitchToggleStyleModifier(tint: tint))
    }

    /// Single-argument callback form of `onChange` that compiles for both
    /// macOS 13 and macOS 14. Callers receive the new value only; none of the
    /// call sites in this target need the previous one.
    func compatOnChange<Value: Equatable>(
        of value: Value,
        perform action: @escaping (Value) -> Void
    ) -> some View {
        modifier(CompatOnChangeModifier(value: value, action: action))
    }
}

// MARK: - Rule bound arithmetic

/// Hard limits, and the ordering invariant, for a trigger rule's paired ranges.
///
/// Both sliders of a pair write into the same model, so each end has to be
/// derived from the other. `Slider(value:in:step:)` is only usable with a
/// strictly increasing range: the previous `max(30, Int(rule.maxTemp) - 5)`
/// expression collapsed to `30...30` (and to `100...100` for the speed pair)
/// as soon as the paired value sat on a limit.
enum RuleBounds {
    static let tempLow: Double = 30
    static let tempHigh: Double = 95
    static let tempStep: Double = 1

    static let percentLow: Double = 0
    static let percentHigh: Double = 100

    static let speedLow: Double = percentLow
    static let speedHigh: Double = percentHigh
    static let speedStep: Double = 5

    /// Ordered, in-bounds copy of `rule`. Total: safe to call on any value,
    /// including one decoded from a hand-edited or truncated rules file.
    static func normalized(_ rule: TriggerRule) -> TriggerRule {
        var copy = rule

        copy.thresholdTemp = copy.thresholdTemp.clampedTo(tempLow...tempHigh)
        copy.targetSpeedPercent = copy.targetSpeedPercent.clampedTo(percentLow...percentHigh)

        // Normalize the low end first, then let the high end follow it, so the
        // pair ends up ordered no matter which end the stored value violated.
        copy.minTemp = lower(copy.minTemp, other: copy.maxTemp, low: tempLow, high: tempHigh, step: tempStep)
        copy.maxTemp = upper(copy.maxTemp, other: copy.minTemp, low: tempLow, high: tempHigh, step: tempStep)

        copy.minSpeedPercent = lower(copy.minSpeedPercent, other: copy.maxSpeedPercent, low: speedLow, high: speedHigh, step: speedStep)
        copy.maxSpeedPercent = upper(copy.maxSpeedPercent, other: copy.minSpeedPercent, low: speedLow, high: speedHigh, step: speedStep)

        return copy
    }

    /// Clamps the low end of a pair so it can never reach or pass the high end.
    static func lower(_ value: Double, other: Double, low: Double, high: Double, step: Double) -> Double {
        let ceiling = max(low, min(high - step, other - step))
        return min(max(value, low), ceiling)
    }

    /// Clamps the high end of a pair so it can never drop to or below the low end.
    static func upper(_ value: Double, other: Double, low: Double, high: Double, step: Double) -> Double {
        let floor = min(high, max(low + step, other + step))
        return min(max(value, floor), high)
    }

    /// Range for the slider that edits the low end of a pair. Always at least
    /// `step` wide, so it stays strictly increasing even when the paired value
    /// is pinned against `low`.
    static func lowSliderRange(other: Double, low: Double, high: Double, step: Double) -> ClosedRange<Double> {
        low...max(low + step, min(high - step, other - step))
    }

    /// Range for the slider that edits the high end of a pair. Always at least
    /// `step` wide, so it stays strictly increasing even when the paired value
    /// is pinned against `high`.
    static func highSliderRange(other: Double, low: Double, high: Double, step: Double) -> ClosedRange<Double> {
        min(high - step, max(low, other - step))...high
    }
}

// MARK: - Auto-Trigger Rules Engine Views
struct RulesEngineView: View {
    @ObservedObject var viewModel: FanViewModel
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Image(systemName: "slider.horizontal.3")
                            .foregroundColor(.purple)
                            .accessibilityHidden(true)
                        Text(L10n.text("Auto-Trigger Rules Engine"))
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white)
                    }
                    Text(L10n.text("Automatically override fan speeds when sensors cross temperature thresholds."))
                        .font(.system(size: 11))
                        .foregroundColor(.gray)
                }
                
                Spacer()
                
                Toggle("", isOn: $viewModel.isRulesEngineEnabled)
                    .labelsHidden()
                    .compatSwitchToggleStyle(tint: .purple)
                    .accessibilityLabel(Text(L10n.text("Auto-Trigger Rules Engine")))
                    .accessibilityHint(Text(L10n.text("Enable or disable automatic fan override rules.")))
            }
            
            if viewModel.isRulesEngineEnabled {
                VStack(spacing: 12) {
                    FanResponseSettingsView(viewModel: viewModel)

                    ForEach($viewModel.rules) { $rule in
                        RuleRowView(rule: $rule, onDelete: {
                            if let idx = viewModel.rules.firstIndex(where: { $0.id == rule.id }) {
                                viewModel.rules.remove(at: idx)
                            }
                        })
                    }
                    
                    Button(action: {
                        withAnimation {
                            viewModel.rules.append(TriggerRule(isEnabled: true, sensor: .cpu, thresholdTemp: 60.0, targetSpeedPercent: 50.0))
                        }
                    }) {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                            Text(L10n.text("Add Custom Trigger Rule"))
                        }
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.purple)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity)
                        .background(Color.purple.opacity(0.1))
                        .clipShape(.rect(cornerRadius: 8))
                    }
                    .buttonStyle(PlainButtonStyle())
                    .accessibilityHint(Text(L10n.text("Creates a new trigger rule using the default CPU threshold.")))
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(20)
        .background(Color.white.opacity(0.02))
        .clipShape(.rect(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(viewModel.isRulesEngineEnabled ? Color.purple.opacity(0.2) : Color.white.opacity(0.04), lineWidth: 1)
        )
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct FanResponseSettingsView: View {
    @ObservedObject var viewModel: FanViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "gauge.with.dots.needle.33percent")
                    .foregroundColor(.purple)
                    .accessibilityHidden(true)
                Text(L10n.text("Fan response"))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
            }

            HStack(spacing: 16) {
                responseControl(
                    title: "Rise command rate",
                    value: $viewModel.maximumCommandRiseRatePercentPerSecond,
                    range: 0.5...10.0,
                    step: 0.5,
                    tint: .teal,
                    unit: "%/s"
                )

                responseControl(
                    title: "Fall command rate",
                    value: $viewModel.maximumCommandFallRatePercentPerSecond,
                    range: 0.5...10.0,
                    step: 0.5,
                    tint: .purple,
                    unit: "%/s"
                )
            }

            HStack(spacing: 16) {
                responseControl(
                    title: "Cooling hysteresis",
                    value: $viewModel.coolingTemperatureHysteresis,
                    range: 0.0...5.0,
                    step: 0.5,
                    tint: .orange,
                    unit: "°C"
                )

                responseControl(
                    title: "Min. target change",
                    value: $viewModel.minimumCommandChangePercent,
                    range: 1.0...5.0,
                    step: 1.0,
                    tint: .purple,
                    unit: "%"
                )
            }

            HStack {
                responseControl(
                    title: "Cooling confirmation",
                    value: $viewModel.coolingConfirmationSeconds,
                    range: 0.0...15.0,
                    step: 1.0,
                    tint: .blue,
                    unit: "s"
                )
                Spacer()
            }

            Text(L10n.text("Temperature rises use the faster rise rate. A lower target must persist for the selected cooling confirmation time before the gentler fall rate begins; 0 s disables this hold. Requests of 90% or more are applied immediately."))
                .font(.system(size: 10))
                .foregroundColor(.gray)
        }
        .padding(12)
        .background(Color.purple.opacity(0.06))
        .clipShape(.rect(cornerRadius: 12))
    }

    private func responseControl(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        tint: Color,
        unit: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L10n.text(title))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.gray)
                Spacer()
                // The slider below carries the accessible name and value, so
                // this readout is decorative and must not be announced twice.
                Text(verbatim: L10n.format("%.1f %@", value.wrappedValue, unit))
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(tint)
                    .accessibilityHidden(true)
            }
            Slider(value: value, in: range, step: step)
                .compatTint(tint)
                .accessibilityLabel(Text(L10n.text(title)))
                .accessibilityValue(Text(verbatim: L10n.format("%.1f %@", value.wrappedValue, unit)))
        }
        .frame(maxWidth: .infinity)
    }
}

struct RuleRowView: View {
    @Binding var rule: TriggerRule
    var onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerRow($rule)
            detailsRow($rule)
        }
        .padding(12)
        .background(Color.white.opacity(0.02))
        .clipShape(.rect(cornerRadius: 12))
        .onAppear { normalizeStoredRule($rule) }
        // Bounds can change from outside these sliders: a restored rules file, a
        // future preset editor, or another view mutating the array. Re-apply the
        // ordering invariant so the stored model can never hold a degenerate pair.
        .compatOnChange(of: $rule.wrappedValue) { updated in
            let normalized = RuleBounds.normalized(updated)
            if normalized != updated {
                $rule.wrappedValue = normalized
            }
        }
    }

    // MARK: - Header Row: Toggle, Sensor, Rule Type, Trash

    private func headerRow(_ rule: Binding<TriggerRule>) -> some View {
        HStack(spacing: 12) {
            Toggle("", isOn: rule.isEnabled)
                .labelsHidden()
                .compatSwitchToggleStyle(tint: .green)
                .accessibilityLabel(Text(L10n.text("Enable rule")))
                .accessibilityHint(Text(L10n.text("Enable or disable this trigger rule.")))

            Text(L10n.text("If"))
                .font(.system(size: 13))
                .foregroundColor(.gray)
                .accessibilityHidden(true)

            Picker("", selection: rule.sensor) {
                ForEach(TriggerRule.SensorType.allCases, id: \.self) { type in
                    Text(L10n.text(type.rawValue)).tag(type)
                }
            }
            .pickerStyle(MenuPickerStyle())
            .labelsHidden()
            .frame(width: 85)
            .background(Color.white.opacity(0.05))
            .clipShape(.rect(cornerRadius: 6))
            .accessibilityLabel(Text(L10n.text("Sensor")))
            .accessibilityHint(Text(L10n.text("Chooses the temperature sensor this rule watches.")))

            Picker("", selection: rule.ruleType) {
                Text(L10n.text("Threshold")).tag(TriggerRule.RuleType.threshold)
                Text(L10n.text("Curve (Min/Max)")).tag(TriggerRule.RuleType.curve)
            }
            .pickerStyle(MenuPickerStyle())
            .labelsHidden()
            .frame(width: 140)
            .background(Color.white.opacity(0.05))
            .clipShape(.rect(cornerRadius: 6))
            .accessibilityLabel(Text(L10n.text("Rule type")))

            Spacer()

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .foregroundColor(.red.opacity(0.7))
                    .padding(6)
                    .background(Color.red.opacity(0.1))
                    .clipShape(.rect(cornerRadius: 6))
            }
            .buttonStyle(PlainButtonStyle())
            .accessibilityLabel(Text(L10n.text("Delete rule")))
            .accessibilityHint(Text(L10n.text("Removes this trigger rule.")))
        }
    }

    // MARK: - Details Row

    @ViewBuilder
    private func detailsRow(_ rule: Binding<TriggerRule>) -> some View {
        // The rule as presented: every bound forced into the hard limits and
        // both pairs forced into order, so a malformed stored rule can never
        // produce a degenerate slider or an out-of-range readout.
        let shown = RuleBounds.normalized(rule.wrappedValue)
        if shown.ruleType == .threshold {
            thresholdDetails(rule, shown)
        } else {
            curveDetails(rule, shown)
        }
    }

    private func thresholdDetails(_ rule: Binding<TriggerRule>, _ shown: TriggerRule) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Spacer().frame(width: 48)
                Text(L10n.text("If temp ≥"))
                    .font(.system(size: 13))
                    .foregroundColor(.gray)
                    .accessibilityHidden(true)

                Text(verbatim: L10n.format("%.0f°C", shown.thresholdTemp))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 36)
                    .accessibilityHidden(true)

                Slider(
                    value: rule.thresholdTemp,
                    in: RuleBounds.tempLow...RuleBounds.tempHigh,
                    step: RuleBounds.tempStep
                )
                    .compatTint(.purple)
                    .accessibilityLabel(Text(L10n.text("If temp ≥")))
                    .accessibilityValue(Text(verbatim: L10n.format("%.0f°C", shown.thresholdTemp)))
            }

            HStack(spacing: 12) {
                Spacer().frame(width: 48)
                Text(L10n.text("Set speed to"))
                    .font(.system(size: 13))
                    .foregroundColor(.gray)
                    .accessibilityHidden(true)

                Text(verbatim: L10n.format("%.0f%%", shown.targetSpeedPercent))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 36)
                    .accessibilityHidden(true)

                Slider(
                    value: rule.targetSpeedPercent,
                    in: RuleBounds.percentLow...RuleBounds.percentHigh,
                    step: RuleBounds.speedStep
                )
                    .compatTint(.purple)
                    .accessibilityLabel(Text(L10n.text("Set speed to")))
                    .accessibilityValue(Text(verbatim: L10n.format("%.0f%%", shown.targetSpeedPercent)))
            }
        }
    }

    private func curveDetails(_ rule: Binding<TriggerRule>, _ shown: TriggerRule) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Spacer().frame(width: 48)
                Text(L10n.text("Temp range:"))
                    .font(.system(size: 13))
                    .foregroundColor(.gray)
                    .frame(width: 80, alignment: .leading)
                    .accessibilityHidden(true)

                Text(verbatim: L10n.format("%.0f°C", shown.minTemp))
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.teal)
                    .frame(width: 36)
                    .accessibilityHidden(true)

                minTempSlider(rule, shown)

                Text(L10n.text("to"))
                    .font(.system(size: 12))
                    .foregroundColor(.gray)
                    .accessibilityHidden(true)

                Text(verbatim: L10n.format("%.0f°C", shown.maxTemp))
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.red)
                    .frame(width: 36)
                    .accessibilityHidden(true)

                maxTempSlider(rule, shown)
            }

            HStack(spacing: 12) {
                Spacer().frame(width: 48)
                Text(L10n.text("Speed range:"))
                    .font(.system(size: 13))
                    .foregroundColor(.gray)
                    .frame(width: 80, alignment: .leading)
                    .accessibilityHidden(true)

                Text(verbatim: L10n.format("%.0f%%", shown.minSpeedPercent))
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.teal)
                    .frame(width: 36)
                    .accessibilityHidden(true)

                minSpeedSlider(rule, shown)

                Text(L10n.text("to"))
                    .font(.system(size: 12))
                    .foregroundColor(.gray)
                    .accessibilityHidden(true)

                Text(verbatim: L10n.format("%.0f%%", shown.maxSpeedPercent))
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.red)
                    .frame(width: 36)
                    .accessibilityHidden(true)

                maxSpeedSlider(rule, shown)
            }
        }
    }

    private func minTempSlider(_ rule: Binding<TriggerRule>, _ shown: TriggerRule) -> some View {
        Slider(
            value: minTempBinding(rule),
            in: RuleBounds.lowSliderRange(
                other: shown.maxTemp,
                low: RuleBounds.tempLow,
                high: RuleBounds.tempHigh,
                step: RuleBounds.tempStep
            ),
            step: RuleBounds.tempStep
        )
            .compatTint(.teal)
            .accessibilityLabel(Text(L10n.text("Min temperature")))
            .accessibilityValue(Text(verbatim: L10n.format("%.0f°C", shown.minTemp)))
    }

    private func maxTempSlider(_ rule: Binding<TriggerRule>, _ shown: TriggerRule) -> some View {
        Slider(
            value: maxTempBinding(rule),
            in: RuleBounds.highSliderRange(
                other: shown.minTemp,
                low: RuleBounds.tempLow,
                high: RuleBounds.tempHigh,
                step: RuleBounds.tempStep
            ),
            step: RuleBounds.tempStep
        )
            .compatTint(.red)
            .accessibilityLabel(Text(L10n.text("Max temperature")))
            .accessibilityValue(Text(verbatim: L10n.format("%.0f°C", shown.maxTemp)))
    }

    private func minSpeedSlider(_ rule: Binding<TriggerRule>, _ shown: TriggerRule) -> some View {
        Slider(
            value: minSpeedBinding(rule),
            in: RuleBounds.lowSliderRange(
                other: shown.maxSpeedPercent,
                low: RuleBounds.speedLow,
                high: RuleBounds.speedHigh,
                step: RuleBounds.speedStep
            ),
            step: RuleBounds.speedStep
        )
            .compatTint(.teal)
            .accessibilityLabel(Text(L10n.text("Min speed")))
            .accessibilityValue(Text(verbatim: L10n.format("%.0f%%", shown.minSpeedPercent)))
    }

    private func maxSpeedSlider(_ rule: Binding<TriggerRule>, _ shown: TriggerRule) -> some View {
        Slider(
            value: maxSpeedBinding(rule),
            in: RuleBounds.highSliderRange(
                other: shown.minSpeedPercent,
                low: RuleBounds.speedLow,
                high: RuleBounds.speedHigh,
                step: RuleBounds.speedStep
            ),
            step: RuleBounds.speedStep
        )
            .compatTint(.red)
            .accessibilityLabel(Text(L10n.text("Max speed")))
            .accessibilityValue(Text(verbatim: L10n.format("%.0f%%", shown.maxSpeedPercent)))
    }

    // MARK: - Ordered two-slider bindings
    //
    // Each slider writes only its own end, then nudges the paired end along so
    // the invariant `low < high` holds even mid-drag.

    private func minTempBinding(_ rule: Binding<TriggerRule>) -> Binding<Double> {
        Binding(
            get: { RuleBounds.normalized(rule.wrappedValue).minTemp },
            set: { newValue in
                rule.wrappedValue.minTemp = RuleBounds.lower(
                    newValue,
                    other: rule.wrappedValue.maxTemp,
                    low: RuleBounds.tempLow,
                    high: RuleBounds.tempHigh,
                    step: RuleBounds.tempStep
                )
                rule.wrappedValue.maxTemp = RuleBounds.upper(
                    rule.wrappedValue.maxTemp,
                    other: rule.wrappedValue.minTemp,
                    low: RuleBounds.tempLow,
                    high: RuleBounds.tempHigh,
                    step: RuleBounds.tempStep
                )
            }
        )
    }

    private func maxTempBinding(_ rule: Binding<TriggerRule>) -> Binding<Double> {
        Binding(
            get: { RuleBounds.normalized(rule.wrappedValue).maxTemp },
            set: { newValue in
                rule.wrappedValue.maxTemp = RuleBounds.upper(
                    newValue,
                    other: rule.wrappedValue.minTemp,
                    low: RuleBounds.tempLow,
                    high: RuleBounds.tempHigh,
                    step: RuleBounds.tempStep
                )
                rule.wrappedValue.minTemp = RuleBounds.lower(
                    rule.wrappedValue.minTemp,
                    other: rule.wrappedValue.maxTemp,
                    low: RuleBounds.tempLow,
                    high: RuleBounds.tempHigh,
                    step: RuleBounds.tempStep
                )
            }
        )
    }

    private func minSpeedBinding(_ rule: Binding<TriggerRule>) -> Binding<Double> {
        Binding(
            get: { RuleBounds.normalized(rule.wrappedValue).minSpeedPercent },
            set: { newValue in
                rule.wrappedValue.minSpeedPercent = RuleBounds.lower(
                    newValue,
                    other: rule.wrappedValue.maxSpeedPercent,
                    low: RuleBounds.speedLow,
                    high: RuleBounds.speedHigh,
                    step: RuleBounds.speedStep
                )
                rule.wrappedValue.maxSpeedPercent = RuleBounds.upper(
                    rule.wrappedValue.maxSpeedPercent,
                    other: rule.wrappedValue.minSpeedPercent,
                    low: RuleBounds.speedLow,
                    high: RuleBounds.speedHigh,
                    step: RuleBounds.speedStep
                )
            }
        )
    }

    private func maxSpeedBinding(_ rule: Binding<TriggerRule>) -> Binding<Double> {
        Binding(
            get: { RuleBounds.normalized(rule.wrappedValue).maxSpeedPercent },
            set: { newValue in
                rule.wrappedValue.maxSpeedPercent = RuleBounds.upper(
                    newValue,
                    other: rule.wrappedValue.minSpeedPercent,
                    low: RuleBounds.speedLow,
                    high: RuleBounds.speedHigh,
                    step: RuleBounds.speedStep
                )
                rule.wrappedValue.minSpeedPercent = RuleBounds.lower(
                    rule.wrappedValue.minSpeedPercent,
                    other: rule.wrappedValue.maxSpeedPercent,
                    low: RuleBounds.speedLow,
                    high: RuleBounds.speedHigh,
                    step: RuleBounds.speedStep
                )
            }
        )
    }

    private func normalizeStoredRule(_ rule: Binding<TriggerRule>) {
        let normalized = RuleBounds.normalized(rule.wrappedValue)
        if normalized != rule.wrappedValue {
            $rule.wrappedValue = normalized
        }
    }
}