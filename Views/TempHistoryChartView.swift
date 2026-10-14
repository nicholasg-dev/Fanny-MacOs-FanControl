import SwiftUI
import Charts

struct TempHistoryChartView: View {
    private let summaryLabelWidth: CGFloat = 48
    private let summaryColumnWidth: CGFloat = 148

    enum ChartSeries: Hashable {
        case sensor(TriggerRule.SensorType)
        case fanTarget
    }

    private enum TimeWindow: String, CaseIterable, Identifiable {
        case thirtyMinutes
        case oneHour
        case twoHours
        case twelveHours
        case twentyFourHours

        var id: String { rawValue }

        var interval: TimeInterval {
            switch self {
            case .thirtyMinutes: return 30 * 60
            case .oneHour: return 60 * 60
            case .twoHours: return 2 * 60 * 60
            case .twelveHours: return 12 * 60 * 60
            case .twentyFourHours: return 24 * 60 * 60
            }
        }

        var label: String {
            switch self {
            case .thirtyMinutes: return L10n.text("Last 30 min")
            case .oneHour: return L10n.text("Last hour")
            case .twoHours: return L10n.text("Last 2 hours")
            case .twelveHours: return L10n.text("Last 12 hours")
            case .twentyFourHours: return L10n.text("Last 24 hours")
            }
        }
    }

    let history: [TempRecord]
    let compactLayout: Bool

    @State private var hoveredTime: Date? = nil
    @State private var timeFormatterCache = TimeFormatterCache()
    @AppStorage("temperatureHistoryDisplayWindow") private var timeWindowRawValue = TimeWindow.twoHours.rawValue
    @AppStorage("showCPUHistory") private var showCPUHistory = true
    @AppStorage("showGPUHistory") private var showGPUHistory = true
    @AppStorage("showBatteryHistory") private var showBatteryHistory = true
    @AppStorage("showFanTargetHistory") private var showFanTargetHistory = true

    /// Identity of the visible series set.
    ///
    /// `onChange` compares the value it is handed on every evaluation, so it
    /// needs something cheap and unambiguous. The four visibility flags are
    /// summarised into one small `Equatable` value instead of the `[ChartSeries]`
    /// array that used to be rebuilt inside `body`.
    private struct DisplaySelection: Equatable {
        let cpu: Bool
        let gpu: Bool
        let battery: Bool
        let fanTarget: Bool
    }

    /// Identity of a single plotted sample.
    ///
    /// This used to be `"\(record.id.uuidString)-\(sensor.rawValue)"`. Rendering
    /// those strings dominated the work of every `body` evaluation (~0.3 ms of
    /// ~1.0 ms at this app's unoptimised build settings), so identity is now a
    /// hashed value type that never allocates a string. The series is part of it
    /// because two series can share the sample record nearest to the pointer.
    struct ChartPointID: Hashable {
        let record: UUID
        let series: ChartSeries
    }

    struct ChartPoint: Identifiable {
        let id: ChartPointID
        let series: ChartSeries
        let time: Date
        let value: Double
    }

    /// `DateFormatter` initialisation and `setLocalizedDateFormatFromTemplate`
    /// both resolve ICU locale data and cost roughly 29 µs together — about 235x
    /// a cached lookup. Only two templates are ever used here, so formatters are
    /// built once per template and reused; switching the rolling window simply
    /// selects the other cached entry instead of rebuilding anything.
    private final class TimeFormatterCache {
        private var formatters: [String: DateFormatter] = [:]

        func string(from date: Date, template: String) -> String {
            if let cached = formatters[template] {
                return cached.string(from: date)
            }
            let formatter = DateFormatter()
            formatter.locale = .current
            formatter.setLocalizedDateFormatFromTemplate(template)
            formatters[template] = formatter
            return formatter.string(from: date)
        }
    }

    private var selectedTimeWindow: TimeWindow {
        TimeWindow(rawValue: timeWindowRawValue) ?? .twoHours
    }

    private var timeWindowTemplate: String {
        selectedTimeWindow == .twentyFourHours ? "MMM d HH:mm" : "HH:mm"
    }

    private var displaySelection: DisplaySelection {
        DisplaySelection(
            cpu: showCPUHistory,
            gpu: showGPUHistory,
            battery: showBatteryHistory,
            fanTarget: showFanTargetHistory
        )
    }

    private var selectedSensors: [TriggerRule.SensorType] {
        let selection = displaySelection
        var sensors: [TriggerRule.SensorType] = []
        if selection.cpu { sensors.append(.cpu) }
        if selection.gpu { sensors.append(.gpu) }
        if selection.battery { sensors.append(.battery) }
        return sensors
    }

    private var displayedSeries: [ChartSeries] {
        selectedSensors.map(ChartSeries.sensor)
            + (displaySelection.fanTarget ? [.fanTarget] : [])
    }

    private func sensorName(_ sensor: TriggerRule.SensorType) -> String {
        switch sensor {
        case .cpu: return L10n.text("CPU")
        case .gpu: return L10n.text("GPU")
        case .battery: return L10n.text("Battery")
        }
    }

    private func sensorColor(_ sensor: TriggerRule.SensorType) -> Color {
        switch sensor {
        case .cpu: return .orange
        case .gpu: return .purple
        case .battery: return .green
        }
    }

    private func sensorIcon(_ sensor: TriggerRule.SensorType) -> String {
        switch sensor {
        case .cpu: return "cpu"
        case .gpu: return "gauge.with.needle"
        case .battery: return "battery.100.bolt"
        }
    }

    private func seriesName(_ series: ChartSeries) -> String {
        switch series {
        case .sensor(let sensor): return sensorName(sensor)
        case .fanTarget: return L10n.text("Fan target")
        }
    }

    private func seriesColor(_ series: ChartSeries) -> Color {
        switch series {
        case .sensor(let sensor): return sensorColor(sensor)
        case .fanTarget: return .cyan
        }
    }

    private func value(for sensor: TriggerRule.SensorType, in record: TempRecord) -> Double? {
        switch sensor {
        case .cpu: return record.cpu
        case .gpu: return record.gpu
        case .battery: return record.battery
        }
    }

    // MARK: - Window slicing

    /// Index of the first record whose timestamp is at or after `date`.
    ///
    /// `history` is append-only and chronological: `FanViewModel` appends
    /// samples at least 30 s apart, prunes expired records from the front only,
    /// and restores the same ordering from disk. The result is validated in
    /// constant time before it is trusted, and the caller falls back to the full
    /// array if validation fails — so a broken ordering assumption could only
    /// cost the speed-up, never hide samples.
    private func firstRecordIndex(atOrAfter date: Date) -> Int? {
        guard !history.isEmpty else { return nil }

        var low = 0
        var high = history.count
        while low < high {
            let mid = low + (high - low) / 2
            if history[mid].timestamp < date {
                low = mid + 1
            } else {
                high = mid
            }
        }

        guard (low == history.count || history[low].timestamp >= date),
              (low == 0 || history[low - 1].timestamp < date) else {
            return nil
        }
        return low
    }

    /// The records that can possibly fall inside the rolling window.
    ///
    /// Slicing first turns four full scans of the 24-hour history into one
    /// binary search plus four scans of the visible window only.
    private func records(from windowStart: Date) -> ArraySlice<TempRecord> {
        guard let start = firstRecordIndex(atOrAfter: windowStart) else {
            return history[...]
        }
        return history[start...]
    }

    private func points(
        for sensor: TriggerRule.SensorType,
        in records: ArraySlice<TempRecord>,
        from windowStart: Date,
        through now: Date
    ) -> [ChartPoint] {
        let series = ChartSeries.sensor(sensor)
        var points: [ChartPoint] = []
        points.reserveCapacity(records.count)
        for record in records {
            guard record.timestamp >= windowStart,
                  record.timestamp <= now,
                  let temperature = value(for: sensor, in: record) else {
                continue
            }
            points.append(
                ChartPoint(
                    id: ChartPointID(record: record.id, series: series),
                    series: series,
                    time: record.timestamp,
                    value: temperature
                )
            )
        }
        return points
    }

    private func fanTargetPoints(
        in records: ArraySlice<TempRecord>,
        from windowStart: Date,
        through now: Date
    ) -> [ChartPoint] {
        var points: [ChartPoint] = []
        points.reserveCapacity(records.count)
        for record in records {
            guard record.timestamp >= windowStart,
                  record.timestamp <= now,
                  let targetPercent = record.fanTargetPercent,
                  (0.0...100.0).contains(targetPercent) else {
                continue
            }
            points.append(
                ChartPoint(
                    id: ChartPointID(record: record.id, series: .fanTarget),
                    series: .fanTarget,
                    time: record.timestamp,
                    value: targetPercent
                )
            )
        }
        return points
    }

    // MARK: - Derived aggregates

    /// Highest plotted value across the visible series, without materialising a
    /// flattened copy of every point.
    private func peakValue(
        in series: [ChartSeries],
        pointsBySeries: [ChartSeries: [ChartPoint]]
    ) -> Double {
        var peak = 0.0
        for chartSeries in series {
            for point in pointsBySeries[chartSeries] ?? [] where point.value > peak {
                peak = point.value
            }
        }
        return peak
    }

    private func valueBounds(
        of points: [ChartPoint]
    ) -> (minimum: Double, maximum: Double)? {
        guard var minimum = points.first?.value else { return nil }
        var maximum = minimum
        for point in points {
            minimum = Swift.min(minimum, point.value)
            maximum = Swift.max(maximum, point.value)
        }
        return (minimum, maximum)
    }

    /// The sample closest to `date` inside a time-sorted point array.
    ///
    /// The nearest entry to an instant is always one of the two neighbours of the
    /// lower-bound insertion point, so hovering no longer scans the whole series
    /// on every pointer-move event. Ties keep the earlier sample, matching the
    /// `min(by:)` behaviour this replaced.
    private func nearestPoint(in points: [ChartPoint], to date: Date) -> ChartPoint? {
        guard !points.isEmpty else { return nil }

        var low = 0
        var high = points.count
        while low < high {
            let mid = low + (high - low) / 2
            if points[mid].time < date {
                low = mid + 1
            } else {
                high = mid
            }
        }

        let later = low < points.count ? points[low] : nil
        let earlier = low > 0 ? points[low - 1] : nil
        switch (earlier, later) {
        case let (earlier?, later?):
            return abs(earlier.time.timeIntervalSince(date)) <= abs(later.time.timeIntervalSince(date))
                ? earlier
                : later
        case let (earlier?, nil):
            return earlier
        case let (nil, later?):
            return later
        default:
            return nil
        }
    }

    private func nearestPoint(
        in series: [ChartSeries],
        pointsBySeries: [ChartSeries: [ChartPoint]],
        to date: Date
    ) -> ChartPoint? {
        var closest: ChartPoint?
        for chartSeries in series {
            guard let candidate = nearestPoint(in: pointsBySeries[chartSeries] ?? [], to: date) else {
                continue
            }
            guard let current = closest else {
                closest = candidate
                continue
            }
            if abs(candidate.time.timeIntervalSince(date)) < abs(current.time.timeIntervalSince(date)) {
                closest = candidate
            }
        }
        return closest
    }

    var body: some View {
        // The graph is a rolling window ending at the present moment, rather
        // than a calendar-day view beginning at midnight.
        let now = Date()
        let windowStart = now.addingTimeInterval(-selectedTimeWindow.interval)
        let series = displayedSeries
        let windowRecords = records(from: windowStart)
        let pointsBySeries: [ChartSeries: [ChartPoint]] = Dictionary(
            uniqueKeysWithValues: series.map { chartSeries in
                switch chartSeries {
                case .sensor(let sensor):
                    return (chartSeries, points(for: sensor, in: windowRecords, from: windowStart, through: now))
                case .fanTarget:
                    return (chartSeries, fanTargetPoints(in: windowRecords, from: windowStart, through: now))
                }
            }
        )
        let hoverPoints = hoveredTime.flatMap { time in
            series.compactMap { nearestPoint(in: pointsBySeries[$0] ?? [], to: time) }
        } ?? []
        // This is the one values strip for the chart: live values normally,
        // or values at the inspected instant while the pointer is in the graph.
        let inspectionPoints = hoverPoints.isEmpty
            ? series.compactMap { pointsBySeries[$0]?.last }
            : hoverPoints
        let hasPoints = series.contains { !(pointsBySeries[$0] ?? []).isEmpty }
        let chartScaleMaximum = max(
            105.0,
            ceil(peakValue(in: series, pointsBySeries: pointsBySeries) / 5.0) * 5.0
        )

        VStack(alignment: .leading, spacing: 14) {
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "chart.xyaxis.line")
                        .foregroundColor(.cyan)
                        .font(.system(size: 14, weight: .bold))
                        .accessibilityHidden(true)
                    Text(L10n.text("Temperature & fan target history"))
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white)
                }

                Spacer()

                Picker(selection: $timeWindowRawValue) {
                    ForEach(TimeWindow.allCases) { window in
                        Text(window.label).tag(window.rawValue)
                    }
                } label: {
                    Text(L10n.text("History duration"))
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 112)
                .help(L10n.text("Choose the rolling time range shown in the graph"))
            }

            HStack(spacing: 10) {
                Color.clear
                    .frame(width: summaryLabelWidth, height: 1)
                    .accessibilityHidden(true)
                sensorToggle(.cpu, isOn: $showCPUHistory)
                    .frame(width: summaryColumnWidth, alignment: .leading)
                sensorToggle(.gpu, isOn: $showGPUHistory)
                    .frame(width: summaryColumnWidth, alignment: .leading)
                sensorToggle(.battery, isOn: $showBatteryHistory)
                    .frame(width: summaryColumnWidth, alignment: .leading)
                fanTargetToggle
                    .frame(width: summaryColumnWidth, alignment: .leading)
                Spacer(minLength: 0)
            }

            if selectedSensors.isEmpty && !showFanTargetHistory {
                emptyState(
                    icon: "chart.xyaxis.line",
                    message: "Select one or more series to display their history."
                )
            } else if !hasPoints {
                emptyState(
                    icon: "chart.xyaxis.line",
                    message: "No temperature data recorded in this time range yet."
                )
            } else {
                HStack(spacing: 10) {
                    Text(inspectionTimeLabel)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.gray)
                        .frame(width: summaryLabelWidth, alignment: .leading)

                    inspectionColumn(for: .sensor(.cpu), in: inspectionPoints)
                    inspectionColumn(for: .sensor(.gpu), in: inspectionPoints)
                    inspectionColumn(for: .sensor(.battery), in: inspectionPoints)
                    inspectionColumn(for: .fanTarget, in: inspectionPoints)
                    
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.white.opacity(0.06))
                .clipShape(.rect(cornerRadius: 6))

                HStack(spacing: 10) {
                    Text(L10n.text("Range"))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.gray)
                        .frame(width: summaryLabelWidth, alignment: .leading)
                    periodRangeColumn(for: .sensor(.cpu), points: pointsBySeries[.sensor(.cpu)])
                    periodRangeColumn(for: .sensor(.gpu), points: pointsBySeries[.sensor(.gpu)])
                    periodRangeColumn(for: .sensor(.battery), points: pointsBySeries[.sensor(.battery)])
                    periodRangeColumn(for: .fanTarget, points: pointsBySeries[.fanTarget])
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.035))
                .clipShape(.rect(cornerRadius: 6))

                Text(L10n.text("Shared scale: temperature in °C; blue fan target in % (limited to 100%)."))
                    .font(.system(size: 9))
                    .foregroundColor(.gray)

                Chart {
                    ForEach(selectedSensors, id: \.self) { sensor in
                        ForEach(pointsBySeries[.sensor(sensor)] ?? []) { point in
                            LineMark(
                                x: .value("Time", point.time),
                                y: .value("Temperature", point.value),
                                series: .value("Sensor", sensor.rawValue)
                            )
                            .foregroundStyle(sensorColor(sensor))
                            .interpolationMethod(.monotone)
                        }
                    }

                    if showFanTargetHistory {
                        ForEach(pointsBySeries[.fanTarget] ?? []) { point in
                            LineMark(
                                x: .value("Time", point.time),
                                y: .value("Fan target", point.value),
                                series: .value("Series", "Fan target")
                            )
                            .foregroundStyle(Color.cyan)
                            .lineStyle(StrokeStyle(lineWidth: 2.2))
                            .interpolationMethod(.stepCenter)
                        }
                    }

                    if let hoveredTime {
                        RuleMark(x: .value("Hover Time", hoveredTime))
                            .foregroundStyle(Color.white.opacity(0.25))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4]))

                        ForEach(hoverPoints) { point in
                            PointMark(
                                x: .value("Hover Time", point.time),
                                y: .value("Hover Value", point.value)
                            )
                            .foregroundStyle(seriesColor(point.series))
                            .symbolSize(80)
                        }
                    }
                }
                .chartXScale(domain: windowStart...now)
                .chartYScale(domain: 0.0...chartScaleMaximum)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.8))
                            .foregroundStyle(Color.white.opacity(0.14))
                        AxisTick(stroke: StrokeStyle(lineWidth: 0.8))
                            .foregroundStyle(Color.white.opacity(0.18))
                        AxisValueLabel(format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute())
                            .foregroundStyle(Color.gray)
                            .font(.system(size: 9))
                    }
                }
                .chartYAxis {
                    AxisMarks(values: .stride(by: 5)) { value in
                        if let temperature = value.as(Double.self) {
                            let roundedTemperature = Int(temperature.rounded())
                            let isMajor = roundedTemperature.isMultiple(of: 10)
                            AxisGridLine(stroke: StrokeStyle(lineWidth: isMajor ? 0.9 : 0.4))
                                .foregroundStyle(Color.white.opacity(isMajor ? 0.18 : 0.08))
                            if isMajor {
                                AxisTick(stroke: StrokeStyle(lineWidth: 0.9))
                                    .foregroundStyle(Color.white.opacity(0.22))
                            AxisValueLabel {
                                Text(String(format: "%.0f", temperature))
                                        .foregroundColor(.gray)
                                        .font(.system(size: 9))
                                }
                            }
                        }
                    }
                }
                .chartOverlay { proxy in
                    GeometryReader { _ in
                        Rectangle()
                            .fill(Color.clear)
                            .contentShape(Rectangle())
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { value in
                                        updateHoveredTime(
                                            at: value.location.x,
                                            using: proxy,
                                            series: series,
                                            pointsBySeries: pointsBySeries
                                        )
                                    }
                                    .onEnded { _ in
                                        hoveredTime = nil
                                    }
                            )
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let location):
                                    updateHoveredTime(
                                        at: location.x,
                                        using: proxy,
                                        series: series,
                                        pointsBySeries: pointsBySeries
                                    )
                                case .ended:
                                    hoveredTime = nil
                                }
                            }
                    }
                }
                .frame(height: compactLayout ? 160 : 240)
                // Swift Charts already exposes each mark to VoiceOver; this adds
                // a spoken summary of the instant the plot is showing so the
                // chart is meaningful without walking ~1,000 data points.
                .accessibilityLabel(L10n.text("Temperature & fan target history"))
                .accessibilityValue(accessibilitySummary(of: inspectionPoints))
            }
        }
        .padding(compactLayout ? 12 : 16)
        .background(Color.white.opacity(0.02))
        .clipShape(.rect(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.05), lineWidth: 1)
        )
        .onValueChange(of: displaySelection) { _ in
            hoveredTime = nil
        }
        .onValueChange(of: timeWindowRawValue) { _ in
            hoveredTime = nil
        }
    }

    private var inspectionTimeLabel: String {
        if let hoveredTime {
            return timeFormatterCache.string(from: hoveredTime, template: timeWindowTemplate)
        }
        return L10n.text("Now")
    }

    private func formattedValue(for point: ChartPoint) -> String {
        point.series == .fanTarget
            ? String(format: "%.1f%%", point.value)
            : String(format: "%.1f°C", point.value)
    }

    private func accessibilitySummary(of points: [ChartPoint]) -> String {
        guard !points.isEmpty else {
            return L10n.text("No temperature data recorded in this time range yet.")
        }
        return points
            .map { "\(seriesName($0.series)) \(formattedValue(for: $0))" }
            .joined(separator: ", ")
    }

    private func sensorToggle(_ sensor: TriggerRule.SensorType, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Label(sensorName(sensor), systemImage: sensorIcon(sensor))
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(sensorColor(sensor))
        }
        .toggleStyle(CheckboxToggleStyle())
        .accessibilityLabel(L10n.format("Show %@ temperature in the graph", sensorName(sensor)))
        .help(L10n.format("Show %@ temperature in the graph", sensorName(sensor)))
    }

    private var fanTargetToggle: some View {
        Toggle(isOn: $showFanTargetHistory) {
            Label {
                Text(L10n.text("Fan target"))
            } icon: {
                Image(systemName: "fanblades")
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.cyan)
        }
        .toggleStyle(CheckboxToggleStyle())
        .accessibilityLabel(L10n.text("Show the highest requested fan speed as a percentage"))
        .help(L10n.text("Show the highest requested fan speed as a percentage"))
    }

    private func emptyState(icon: String, message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundColor(.gray.opacity(0.5))
                .accessibilityHidden(true)
            Text(L10n.text(message))
                .font(.system(size: 12))
                .foregroundColor(.gray)
        }
        .frame(height: compactLayout ? 56 : 72)
        .frame(maxWidth: .infinity)
        .background(Color.black.opacity(0.15))
        .clipShape(.rect(cornerRadius: 8))
    }

    private func inspectionValue(_ point: ChartPoint) -> some View {
        HStack(spacing: 4) {
            Text(seriesName(point.series))
                .foregroundColor(seriesColor(point.series))
            Text(formattedValue(for: point))
                .fontWeight(.bold)
                .foregroundColor(.white)
        }
        .font(.system(size: 10, weight: .medium))
        .accessibilityElement(children: .combine)
    }

    private func inspectionColumn(for series: ChartSeries, in points: [ChartPoint]) -> some View {
        Group {
            if let point = points.first(where: { $0.series == series }) {
                inspectionValue(point)
            } else {
                Color.clear
                    .accessibilityHidden(true)
            }
        }
        .frame(width: summaryColumnWidth, alignment: .leading)
    }

    private func periodRangeColumn(for series: ChartSeries, points: [ChartPoint]?) -> some View {
        Group {
            if let points, !points.isEmpty {
                periodRange(series: series, points: points)
            } else {
                Color.clear
                    .accessibilityHidden(true)
            }
        }
        .frame(width: summaryColumnWidth, alignment: .leading)
    }

    private func periodRange(series: ChartSeries, points: [ChartPoint]) -> some View {
        let bounds = valueBounds(of: points) ?? (0, 0)
        let unit = series == .fanTarget ? "%" : "°C"

        return HStack(spacing: 4) {
            Text(seriesName(series))
                .foregroundColor(seriesColor(series))
            Text(String(format: "%.1f–%.1f%@", bounds.minimum, bounds.maximum, unit))
                .fontWeight(.semibold)
                .foregroundColor(.white)
        }
        .font(.system(size: 9, weight: .medium))
        .accessibilityElement(children: .combine)
    }

    private func updateHoveredTime(
        at xPosition: CGFloat,
        using proxy: ChartProxy,
        series: [ChartSeries],
        pointsBySeries: [ChartSeries: [ChartPoint]]
    ) {
        guard let date: Date = proxy.value(atX: xPosition) else { return }
        hoveredTime = nearestPoint(in: series, pointsBySeries: pointsBySeries, to: date)?.time
    }
}

/// Keeps the chart current without re-rendering the rest of the window.
///
/// The history changes once every 30 seconds. The rolling window the chart shows,
/// though, moves continuously, so the chart also refreshes on a five-second
/// timeline. Five seconds is enough to keep the window moving without re-rendering
/// the chart every second.
struct TempHistoryChartContainer: View {
    @ObservedObject var store: FanHistoryStore
    let compactLayout: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { _ in
            TempHistoryChartView(history: store.records, compactLayout: compactLayout)
        }
    }
}