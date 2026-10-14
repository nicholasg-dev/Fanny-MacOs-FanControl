import Combine
import Foundation

// MARK: - Published state, split by how often it changes
//
// `FanViewModel` used to publish everything from one object, and the whole
// window observed it. A fan reading changes every second, so every poll
// re-rendered the window, including the parts that show nothing live. These
// stores hold the fast-changing and slow-changing state separately, so each
// view observes only what it shows.
//
// Nothing in this file touches SwiftUI, AppKit or the helper. That keeps it
// compilable by `tests/run-tests.sh`.

// MARK: - Live telemetry (once a second)

/// The fan readings and battery temperature shown live in the window and the
/// menu. Published only when a value actually changes.
final class FanTelemetry: ObservableObject {
    @Published private(set) var fans: [FanJSON] = []
    @Published private(set) var batteryTemp: Double?

    /// Stores a poll's values, publishing each one only if it differs from the
    /// last value. An unchanged poll therefore causes no SwiftUI work at all.
    func apply(fans newFans: [FanJSON], batteryTemp newBatteryTemp: Double?) {
        if newFans != fans {
            fans = newFans
        }
        if newBatteryTemp != batteryTemp {
            batteryTemp = newBatteryTemp
        }
    }
}

/// The one live value the menu bar label shows. It changes only when the
/// rounded readout changes, so the status item is not redrawn on every poll.
final class MenuBarStatus: ObservableObject {
    /// Fan speed as displayed, rounded to the nearest 50 RPM. RPM jitters by a
    /// few revolutions every second, and rounding it keeps the readout steady.
    @Published private(set) var roundedRPM: Int?

    /// A number with the same digit count as the widest readout this fan can show,
    /// made of the widest menu-bar digit. The label draws inside a slot this wide, so
    /// the menu-bar item keeps one width as the readout changes. Without the slot the
    /// item widened and narrowed on every change, because digits are proportional.
    @Published private(set) var reservedRPM: Int = 4444

    static func displayedRPM(for rpm: Int) -> Int {
        max(0, (rpm + 25) / 50 * 50)
    }

    /// The reserved readout for a fan whose maximum speed is `maxRPM`. It has at least
    /// four digits, the usual width of a fan speed, and as many digits as the fan's
    /// maximum has.
    static func reservedRPM(forMaxRPM maxRPM: Int) -> Int {
        let digits = max(4, String(max(maxRPM, 0)).count)
        return Int(String(repeating: "4", count: digits)) ?? 4444
    }

    func update(firstFanRPM rpm: Int?, firstFanMaxRPM maxRPM: Int?) {
        let displayed = rpm.map(Self.displayedRPM(for:))
        if displayed != roundedRPM {
            roundedRPM = displayed
        }
        let reserved = Self.reservedRPM(forMaxRPM: maxRPM ?? 0)
        if reserved != reservedRPM {
            reservedRPM = reserved
        }
    }
}

// MARK: - Temperature history (one record every 30 seconds)

/// Rolling 24-hour temperature history, kept on disk so it survives a relaunch.
///
/// Storage is an append-only JSON-lines file: each 30-second sample writes one
/// line of about 150 bytes. The file is rewritten in full only when expired
/// records need removing, and at most once an hour. The previous design
/// rewrote the entire 24-hour history, about 420 KB, into UserDefaults every 30
/// seconds on the main thread. All disk work runs on a background queue.
final class FanHistoryStore: ObservableObject {
    static let retention: TimeInterval = 24 * 60 * 60
    static let recordInterval: TimeInterval = 30
    static let compactionInterval: TimeInterval = 60 * 60
    /// The UserDefaults key the previous version stored history under.
    static let legacyDefaultsKey = "tempHistory"

    @Published private(set) var records: [TempRecord] = []

    private let fileURL: URL?
    private let writer = DispatchQueue(label: "com.pair.FanControl.history-writer", qos: .utility)
    private var lastRecordTime: Date?
    private var lastCompaction: Date = .distantPast
    private var prunedSinceCompaction = false

    /// - Parameters:
    ///   - fileURL: where history is stored. `nil` keeps it in memory only.
    ///   - defaults: where a history saved by an earlier version is migrated from.
    ///   - now: the reference time for retention. Injected so tests can control it.
    init(
        fileURL: URL? = FanHistoryStore.defaultFileURL(),
        defaults: UserDefaults = .standard,
        now: Date = Date()
    ) {
        self.fileURL = fileURL
        load(defaults: defaults, now: now)
    }

    /// `~/Library/Application Support/<bundle id>/temperature-history.jsonl`.
    static func defaultFileURL() -> URL? {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else {
            return nil
        }
        let directory = support.appendingPathComponent(
            Bundle.main.bundleIdentifier ?? "FanControl",
            isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        return directory.appendingPathComponent("temperature-history.jsonl")
    }

    /// Appends a sample if at least `recordInterval` has passed since the last
    /// one, and a live reading exists.
    func recordIfDue(
        now: Date,
        cpu: Double?,
        gpu: Double?,
        battery: Double?,
        fanTargetPercent: Double?
    ) {
        guard cpu != nil || gpu != nil || battery != nil else { return }
        if let last = lastRecordTime, now.timeIntervalSince(last) < Self.recordInterval {
            return
        }

        let record = TempRecord(
            timestamp: now,
            cpu: cpu,
            gpu: gpu,
            battery: battery,
            fanTargetPercent: fanTargetPercent
        )
        records.append(record)
        lastRecordTime = now

        let countBeforePrune = records.count
        prune(relativeTo: now)
        if records.count < countBeforePrune {
            prunedSinceCompaction = true
        }

        guard let url = fileURL else { return }
        if prunedSinceCompaction, now.timeIntervalSince(lastCompaction) >= Self.compactionInterval {
            lastCompaction = now
            prunedSinceCompaction = false
            rewrite(records, to: url)
        } else {
            append(record, to: url)
        }
    }

    /// Blocks until every queued write has reached disk. Called before the app
    /// exits, so the last few samples are not lost.
    func flush() {
        writer.sync {}
    }

    // MARK: Loading

    private func load(defaults: UserDefaults, now: Date) {
        let cutoff = now.addingTimeInterval(-Self.retention)
        guard let url = fileURL else { return }

        if FileManager.default.fileExists(atPath: url.path) {
            let data = (try? Data(contentsOf: url)) ?? Data()
            let lines = data.split(separator: UInt8(ascii: "\n"))
            let decoder = JSONDecoder()
            // A line that does not decode (for example one cut short by a crash
            // mid-write) is skipped. It must not discard the rest of the history.
            let decoded = lines.compactMap { try? decoder.decode(TempRecord.self, from: Data($0)) }
            records = Self.sanitized(decoded, cutoff: cutoff)
            if lines.count > records.count {
                lastCompaction = now
                rewrite(records, to: url)
            }
        } else if let legacy = defaults.data(forKey: Self.legacyDefaultsKey),
                  let decoded = try? JSONDecoder().decode([TempRecord].self, from: legacy) {
            records = Self.sanitized(decoded, cutoff: cutoff)
            // Write synchronously and clear the old copy only once the new file is
            // safely on disk, so a failed write cannot lose the migrated history.
            if (try? Self.encodeLines(records).write(to: url, options: .atomic)) != nil {
                defaults.removeObject(forKey: Self.legacyDefaultsKey)
            }
            lastCompaction = now
        }

        lastRecordTime = records.last?.timestamp
    }

    /// Applies the same plausibility rules as live readings, so a history written
    /// by a bad sensor read cannot draw a spike, and drops expired records.
    static func sanitized(_ records: [TempRecord], cutoff: Date) -> [TempRecord] {
        var previousCPU: Double?
        var previousGPU: Double?
        var previousBattery: Double?

        return records.map { record in
            let cpu = FanControlLaw.cleanHistoricalTemperature(record.cpu, previous: &previousCPU, sensor: .cpu)
            let gpu = FanControlLaw.cleanHistoricalTemperature(record.gpu, previous: &previousGPU, sensor: .gpu)
            let battery = FanControlLaw.cleanHistoricalTemperature(record.battery, previous: &previousBattery, sensor: .battery)
            let fanTarget = record.fanTargetPercent.flatMap { candidate in
                candidate.isFinite && (0.0...100.0).contains(candidate) ? candidate : nil
            }
            return TempRecord(
                id: record.id,
                timestamp: record.timestamp,
                cpu: cpu,
                gpu: gpu,
                battery: battery,
                fanTargetPercent: fanTarget
            )
        }
        .filter { $0.timestamp >= cutoff }
    }

    // MARK: Writing

    private func prune(relativeTo now: Date) {
        let cutoff = now.addingTimeInterval(-Self.retention)
        records.removeAll { $0.timestamp < cutoff }
    }

    private func append(_ record: TempRecord, to url: URL) {
        guard let encoded = try? JSONEncoder().encode(record) else { return }
        var line = encoded
        line.append(UInt8(ascii: "\n"))

        writer.async {
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        }
    }

    private func rewrite(_ snapshot: [TempRecord], to url: URL) {
        writer.async {
            try? Self.encodeLines(snapshot).write(to: url, options: .atomic)
        }
    }

    private static func encodeLines(_ records: [TempRecord]) throws -> Data {
        let encoder = JSONEncoder()
        var data = Data()
        for record in records {
            data.append(try encoder.encode(record))
            data.append(UInt8(ascii: "\n"))
        }
        return data
    }
}
