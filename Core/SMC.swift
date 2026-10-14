//
//  SMC.swift
//  Fan Control
//
//  Created by Pair Programming Agent.
//  Based on Serhiy Mytrovtsiy's SMC implementation for Stats.
//

import Foundation
import Dispatch
import IOKit

/// Largest payload the SMC wire format can carry for a single key.
///
/// `SMCKeyData_t.bytes` is a fixed 32-element tuple that sits at the *end* of the
/// struct, so anything past 32 bytes is read from (or written to) adjacent stack
/// memory by the kernel. Every `dataSize` that crosses the kernel boundary is
/// therefore clamped against this value rather than trusted.
internal enum SMCLimits {
    static let payloadCapacity = 32
}

internal enum SMCDataType: String {
    case UI8 = "ui8 "
    case UI16 = "ui16"
    case UI32 = "ui32"
    case SP1E = "sp1e"
    case SP3C = "sp3c"
    case SP4B = "sp4b"
    case SP5A = "sp5a"
    case SPA5 = "spa5"
    case SP69 = "sp69"
    case SP78 = "sp78"
    case SP87 = "sp87"
    case SP96 = "sp96"
    case SPB4 = "spb4"
    case SPF0 = "spf0"
    case FLT = "flt "
    case FPE2 = "fpe2"
    case FP2E = "fp2e"
    case FDS = "{fds"
}

internal enum SMCKeys: UInt8 {
    case kernelIndex = 2
    case readBytes = 5
    case writeBytes = 6
    case readIndex = 8
    case readKeyInfo = 9
    case readPLimit = 11
    case readVers = 12
}

public enum FanMode: Int, Codable {
    case automatic = 0
    case forced = 1
    case auto3 = 3

    public var isAutomatic: Bool {
        self == .automatic || self == .auto3
    }
}

internal struct SMCKeyData_t {
    typealias SMCBytes_t = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                            UInt8, UInt8, UInt8, UInt8)

    struct vers_t {
        var major: CUnsignedChar = 0
        var minor: CUnsignedChar = 0
        var build: CUnsignedChar = 0
        var reserved: CUnsignedChar = 0
        var release: CUnsignedShort = 0
    }

    struct LimitData_t {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0
        var gpuPLimit: UInt32 = 0
        var memPLimit: UInt32 = 0
    }

    struct keyInfo_t {
        var dataSize: IOByteCount32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }

    var key: UInt32 = 0
    var vers = vers_t()
    var pLimitData = LimitData_t()
    var keyInfo = keyInfo_t()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes_t = (UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                             UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                             UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                             UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                             UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                             UInt8(0), UInt8(0))
}

internal struct SMCVal_t {
    var key: String
    var dataSize: UInt32 = 0
    var dataType: String = ""
    /// Always allocated at `SMCLimits.payloadCapacity` (32) elements, regardless of
    /// the value's real `dataSize`, so fixed-width decoders below can index it
    /// without a bounds check on every branch.
    ///
    /// - Performance note: this is a heap `Array`, so every read costs one
    ///   32-byte allocation. The helper performs roughly 41 reads per invocation
    ///   (~41 tiny allocations), which is negligible next to the two IOKit round
    ///   trips each read performs. The durable fix for the per-poll read cost is
    ///   replacing the fork-per-poll CLI with a persistent XPC service — see the
    ///   note in `Helper/main.swift`. Not done here: it is a deliberate,
    ///   out-of-scope change.
    var bytes: [UInt8] = Array(repeating: 0, count: SMCLimits.payloadCapacity)

    init(_ key: String) {
        self.key = key
    }

    /// Layout of an `{fds` value: `fdsHeaderLength` leading bytes of framing
    /// followed by a fixed-width character field.
    static let fdsHeaderLength = 4
    static let fdsCharacterCount = 12
}

/// Diagnostics from the SMC layer.
///
/// The helper's stdout is a machine-readable JSON channel that the app decodes
/// directly, so anything written here must go to stderr instead of polluting it.
internal enum SMCLog {
    /// When set, diagnostics are suppressed entirely. The helper enables this for
    /// the `get` command so a failed read can never corrupt the JSON payload.
    internal static var isSuppressed = false

    internal static func error(_ message: @autoclosure () -> String) {
        guard !isSuppressed else { return }
        let text = "smc-helper: \(message())\n"
        FileHandle.standardError.write(Data(text.utf8))
    }
}

extension FourCharCode {
    init(fromString str: String) {
        precondition(str.count == 4)

        self = str.utf8.reduce(0) { sum, character in
            return sum << 8 | UInt32(character)
        }
    }

    func toString() -> String {
        return String(describing: UnicodeScalar(self >> 24 & 0xff)!) +
               String(describing: UnicodeScalar(self >> 16 & 0xff)!) +
               String(describing: UnicodeScalar(self >> 8  & 0xff)!) +
               String(describing: UnicodeScalar(self       & 0xff)!)
    }
}

extension UInt16 {
    init(bytes: (UInt8, UInt8)) {
        self = UInt16(bytes.0) << 8 | UInt16(bytes.1)
    }
}

extension UInt32 {
    init(bytes: (UInt8, UInt8, UInt8, UInt8)) {
        self = UInt32(bytes.0) << 24 | UInt32(bytes.1) << 16 | UInt32(bytes.2) << 8 | UInt32(bytes.3)
    }
}

extension Int {
    init(fromFPE2 bytes: (UInt8, UInt8)) {
        self = (Int(bytes.0) << 6) + (Int(bytes.1) >> 2)
    }
}

extension Float {
    init?(_ bytes: [UInt8]) {
        if bytes.count < 4 { return nil }
        self = bytes.withUnsafeBytes {
            return $0.load(fromByteOffset: 0, as: Self.self)
        }
    }

    var bytes: [UInt8] {
        withUnsafeBytes(of: self, Array.init)
    }
}

public class SMC {
    public static let shared = SMC()
    private var conn: io_connect_t = 0
    private var _fanModeKeyIsLower: Bool?

    public init() {
        var result: kern_return_t
        var iterator: io_iterator_t = 0
        let device: io_object_t

        let matchingDictionary: CFMutableDictionary = IOServiceMatching("AppleSMC")
        result = IOServiceGetMatchingServices(kIOMainPortDefault, matchingDictionary, &iterator)
        if result != kIOReturnSuccess {
            SMCLog.error("Error IOServiceGetMatchingServices(): " + (String(cString: mach_error_string(result), encoding: String.Encoding.ascii) ?? "unknown error"))
            return
        }

        device = IOIteratorNext(iterator)
        IOObjectRelease(iterator)
        if device == 0 {
            SMCLog.error("Error: No AppleSMC device found.")
            return
        }

        result = IOServiceOpen(device, mach_task_self_, 0, &conn)
        IOObjectRelease(device)
        if result != kIOReturnSuccess {
            SMCLog.error("Error IOServiceOpen(): " + (String(cString: mach_error_string(result), encoding: String.Encoding.ascii) ?? "unknown error"))
            return
        }
    }

    deinit {
        let result = self.close()
        if result != kIOReturnSuccess && conn != 0 {
            SMCLog.error("error close smc connection: " + (String(cString: mach_error_string(result), encoding: String.Encoding.ascii) ?? "unknown error"))
        }
    }

    public func close() -> kern_return_t {
        if conn != 0 {
            let res = IOServiceClose(conn)
            conn = 0
            return res
        }
        return kIOReturnSuccess
    }

    public func getValue(_ key: String) -> Double? {
        var result: kern_return_t = 0
        var val: SMCVal_t = SMCVal_t(key)

        result = read(&val)
        if result != kIOReturnSuccess {
            return nil
        }

        if val.dataSize > 0 {
            // Filter empty data, but allow zero values for mode/status keys
            if val.bytes.first(where: { $0 != 0 }) == nil && 
                val.key != "FS! " && 
                !val.key.hasSuffix("Md") && 
                !val.key.hasSuffix("md") {
                return nil
            }

            switch val.dataType {
            case SMCDataType.UI8.rawValue:
                return Double(val.bytes[0])
            case SMCDataType.UI16.rawValue:
                guard val.bytes.count >= 2 else { return nil }
                return Double(UInt16(bytes: (val.bytes[0], val.bytes[1])))
            case SMCDataType.UI32.rawValue:
                guard val.bytes.count >= 4 else { return nil }
                return Double(UInt32(bytes: (val.bytes[0], val.bytes[1], val.bytes[2], val.bytes[3])))
            case SMCDataType.SP1E.rawValue:
                guard val.bytes.count >= 2 else { return nil }
                let result: Double = Double(UInt16(val.bytes[0]) * 256 + UInt16(val.bytes[1]))
                return Double(result / 16384)
            case SMCDataType.SP3C.rawValue:
                guard val.bytes.count >= 2 else { return nil }
                let result: Double = Double(UInt16(val.bytes[0]) * 256 + UInt16(val.bytes[1]))
                return Double(result / 4096)
            case SMCDataType.SP4B.rawValue:
                guard val.bytes.count >= 2 else { return nil }
                let result: Double = Double(UInt16(val.bytes[0]) * 256 + UInt16(val.bytes[1]))
                return Double(result / 2048)
            case SMCDataType.SP5A.rawValue:
                guard val.bytes.count >= 2 else { return nil }
                let result: Double = Double(UInt16(val.bytes[0]) * 256 + UInt16(val.bytes[1]))
                return Double(result / 1024)
            case SMCDataType.SP69.rawValue:
                guard val.bytes.count >= 2 else { return nil }
                let result: Double = Double(UInt16(val.bytes[0]) * 256 + UInt16(val.bytes[1]))
                return Double(result / 512)
            case SMCDataType.SP78.rawValue:
                guard val.bytes.count >= 2 else { return nil }
                let intValue: Double = Double(Int(val.bytes[0]) * 256 + Int(val.bytes[1]))
                return Double(intValue / 256)
            case SMCDataType.SP87.rawValue:
                guard val.bytes.count >= 2 else { return nil }
                let intValue: Double = Double(Int(val.bytes[0]) * 256 + Int(val.bytes[1]))
                return Double(intValue / 128)
            case SMCDataType.SP96.rawValue:
                guard val.bytes.count >= 2 else { return nil }
                let intValue: Double = Double(Int(val.bytes[0]) * 256 + Int(val.bytes[1]))
                return Double(intValue / 64)
            case SMCDataType.SPA5.rawValue:
                guard val.bytes.count >= 2 else { return nil }
                let result: Double = Double(UInt16(val.bytes[0]) * 256 + UInt16(val.bytes[1]))
                return Double(result / 32)
            case SMCDataType.SPB4.rawValue:
                guard val.bytes.count >= 2 else { return nil }
                let intValue: Double = Double(Int(val.bytes[0]) * 256 + Int(val.bytes[1]))
                return Double(intValue / 16)
            case SMCDataType.SPF0.rawValue:
                guard val.bytes.count >= 2 else { return nil }
                let intValue: Double = Double(Int(val.bytes[0]) * 256 + Int(val.bytes[1]))
                return intValue
            case SMCDataType.FLT.rawValue:
                let value: Float? = Float(val.bytes)
                if value != nil {
                    return Double(value!)
                }
                return nil
            case SMCDataType.FPE2.rawValue:
                guard val.bytes.count >= 2 else { return nil }
                return Double(Int(fromFPE2: (val.bytes[0], val.bytes[1])))
            default:
                return nil
            }
        }

        return nil
    }

    public func getStringValue(_ key: String) -> String? {
        var result: kern_return_t = 0
        var val: SMCVal_t = SMCVal_t(key)

        result = read(&val)
        if result != kIOReturnSuccess {
            return nil
        }

        if val.dataSize > 0 {
            if val.bytes.first(where: { $0 != 0}) == nil {
                return nil
            }

            switch val.dataType {
            case SMCDataType.FDS.rawValue:
                // An FDS value is a 4-byte header followed by a fixed 12-character,
                // NUL/space padded string. Reading bytes 4...15 off a value the
                // kernel reported as shorter than that would surface uninitialised
                // payload as a bogus name, so refuse undersized values outright.
                guard val.dataSize >= UInt32(SMCVal_t.fdsHeaderLength + SMCVal_t.fdsCharacterCount),
                      val.bytes.count >= SMCVal_t.fdsHeaderLength + SMCVal_t.fdsCharacterCount else {
                    SMCLog.error("[\(key)] fds value too short: dataSize=\(val.dataSize)")
                    return nil
                }

                // Appending scalars directly avoids allocating twelve one-character
                // Strings per fan name on every poll.
                var name = String.UnicodeScalarView()
                for index in SMCVal_t.fdsHeaderLength..<(SMCVal_t.fdsHeaderLength + SMCVal_t.fdsCharacterCount) {
                    name.append(UnicodeScalar(val.bytes[index]))
                }

                return String(name).trimmingCharacters(in: .whitespaces)
            default:
                return nil
            }
        }

        return nil
    }

    public func fanModeKey(_ id: Int) -> String {
        #if arch(arm64)
        if _fanModeKeyIsLower == nil {
            var probe = SMCVal_t("F0md")
            _fanModeKeyIsLower = read(&probe) == kIOReturnSuccess && probe.dataSize > 0
        }
        return _fanModeKeyIsLower! ? "F\(id)md" : "F\(id)Md"
        #else
        return "F\(id)Md"
        #endif
    }

    public func setFanMode(_ id: Int, mode: FanMode) -> Bool {
        #if arch(arm64)
        if mode == .forced {
            return unlockFanControl(fanId: id)
        } else {
            return setFanAutomatic(id, deadline: nil)
        }
        #else
        // Intel
        if self.getValue("F\(id)Md") != nil {
            var result: kern_return_t = 0
            var value = SMCVal_t("F\(id)Md")

            result = read(&value)
            if result != kIOReturnSuccess {
                SMCLog.error("Error read fan mode: " + (String(cString: mach_error_string(result), encoding: String.Encoding.ascii) ?? "unknown error"))
                return false
            }

            value.bytes = [UInt8(mode.rawValue), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                           UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                           UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                           UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                           UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                           UInt8(0), UInt8(0)]

            result = write(value)
            if result != kIOReturnSuccess {
                SMCLog.error("Error write: " + (String(cString: mach_error_string(result), encoding: String.Encoding.ascii) ?? "unknown error"))
                return false
            }
        }

        let fansMode = Int(self.getValue("FS! ") ?? 0)
        var newMode: UInt8 = 0

        if fansMode == 0 && id == 0 && mode == .forced {
            newMode = 1
        } else if fansMode == 0 && id == 1 && mode == .forced {
            newMode = 2
        } else if fansMode == 1 && id == 0 && mode == .automatic {
            newMode = 0
        } else if fansMode == 1 && id == 1 && mode == .forced {
            newMode = 3
        } else if fansMode == 2 && id == 1 && mode == .automatic {
            newMode = 0
        } else if fansMode == 2 && id == 0 && mode == .forced {
            newMode = 3
        } else if fansMode == 3 && id == 0 && mode == .automatic {
            newMode = 2
        } else if fansMode == 3 && id == 1 && mode == .automatic {
            newMode = 1
        }

        if fansMode == newMode {
            return true
        }

        var result: kern_return_t = 0
        var value = SMCVal_t("FS! ")

        result = read(&value)
        if result != kIOReturnSuccess {
            SMCLog.error("Error read fan mode: " + (String(cString: mach_error_string(result), encoding: String.Encoding.ascii) ?? "unknown error"))
            return false
        }

        value.bytes = [0, newMode, UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                       UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                       UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                       UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                       UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                       UInt8(0), UInt8(0)]

        result = write(value)
        if result != kIOReturnSuccess {
            SMCLog.error("Error write: " + (String(cString: mach_error_string(result), encoding: String.Encoding.ascii) ?? "unknown error"))
            return false
        }
        return true
        #endif
    }

    public func setFanSpeed(_ id: Int, speed: Int) -> Bool {
        guard let maxSpeed = self.getValue("F\(id)Mx") else { return false }
        let targetSpeed = min(speed, Int(maxSpeed))

        #if arch(arm64)
        var modeVal = SMCVal_t(fanModeKey(id))
        let modeResult = read(&modeVal)
        guard modeResult == kIOReturnSuccess else {
            SMCLog.error("Error read fan mode: " + (String(cString: mach_error_string(modeResult), encoding: String.Encoding.ascii) ?? "unknown error"))
            return false
        }
        if modeVal.bytes[0] != 1 {
            if !unlockFanControl(fanId: id) { return false }
        }
        #endif

        var result: kern_return_t = 0
        var value = SMCVal_t("F\(id)Tg")

        result = read(&value)
        if result != kIOReturnSuccess {
            SMCLog.error("Error read fan value: " + (String(cString: mach_error_string(result), encoding: String.Encoding.ascii) ?? "unknown error"))
            return false
        }

        if value.dataType == "flt " {
            let bytes = Float(targetSpeed).bytes
            value.bytes[0] = bytes[0]
            value.bytes[1] = bytes[1]
            value.bytes[2] = bytes[2]
            value.bytes[3] = bytes[3]
        } else if value.dataType == "fpe2" {
            value.bytes[0] = UInt8(targetSpeed >> 6)
            value.bytes[1] = UInt8((targetSpeed << 2) ^ ((targetSpeed >> 6) << 8))
            value.bytes[2] = UInt8(0)
            value.bytes[3] = UInt8(0)
        }

        #if arch(arm64)
        return writeWithRetry(value)
        #else
        result = write(value)
        if result != kIOReturnSuccess {
            SMCLog.error("Error write: " + (String(cString: mach_error_string(result), encoding: String.Encoding.ascii) ?? "unknown error"))
            return false
        }
        return true
        #endif
    }

    // MARK: - Apple Silicon Fan Control

    #if arch(arm64)
    /// Tunable timings for the Apple Silicon unlock/reset paths.
    ///
    /// Every retry loop below is additionally bounded by a wall-clock `Deadline`,
    /// so these numbers only control retry *spacing*, not the worst-case block.
    ///
    /// Override `FANCONTROL_UNLOCK_BUDGET_SECONDS` (and
    /// `FANCONTROL_RESET_BUDGET_SECONDS`) to give stubborn hardware more patience
    /// without recompiling.
    internal enum UnlockTiming {
        /// Spacing between plain SMC write retries (the ordinary, non-unlock case).
        static let writeDelayMicros: UInt32 = 50_000
        static let writeAttempts = 10

        /// Retries for the `Ftst` unlock write. Spaced tightly because the SMC
        /// rejects the write while thermalmonitord still owns the fan keys.
        static let ftstAttempts = 20

        /// How long to let thermalmonitord hand control back after `Ftst` is set.
        /// This delay is hardware-validated behaviour and is deliberately left at
        /// its proven 3s; it is only truncated if the overall budget runs out.
        static let thermalmonitordYieldMicros: UInt32 = 3_000_000

        /// Spacing between mode-write retries after the yield.
        static let modeWriteDelayMicros: UInt32 = 100_000

        /// Hard wall-clock ceiling for a single `unlockFanControl` call.
        static var unlockBudgetSeconds: Double {
            Self.positiveDouble(fromEnvironment: "FANCONTROL_UNLOCK_BUDGET_SECONDS", default: 8.0)
        }

        /// Hard wall-clock ceiling for a single `resetFanControl` call.
        static var resetBudgetSeconds: Double {
            Self.positiveDouble(fromEnvironment: "FANCONTROL_RESET_BUDGET_SECONDS", default: 6.0)
        }

        private static func positiveDouble(fromEnvironment name: String, default fallback: Double) -> Double {
            guard let raw = ProcessInfo.processInfo.environment[name],
                  let value = Double(raw),
                  value > 0, value.isFinite else {
                return fallback
            }
            return value
        }
    }

    /// A monotonic wall-clock budget for a sequence of retries.
    ///
    /// Historically the unlock path used raw attempt counts — 100 retries at 50 ms
    /// plus a 3 s yield plus 300 retries at 100 ms — so a single stuck unlock
    /// blocked for ~38 s and a reset for ~11 s. Both run inside the setuid helper,
    /// and the app waits on `Process.waitUntilExit()`, so every one of those
    /// seconds is a frozen UI and a stalled poll.
    ///
    /// Retries now stop at a deadline. The *sequence* of operations is unchanged
    /// (direct mode write -> `Ftst` -> thermalmonitord yield -> mode retry) and so
    /// are the keys involved, which means the success path performs exactly the
    /// same work in exactly the same order as before; only the failure path is
    /// now bounded.
    private struct Deadline {
        private let expiresAt: DispatchTime

        init(seconds: Double) {
            // Clamp before converting: an absurd environment override must not
            // overflow the nanosecond conversion.
            let clamped = seconds.isFinite ? min(max(seconds, 0), 3_600) : 0
            self.expiresAt = DispatchTime.now() + .nanoseconds(Int(clamped * 1_000_000_000))
        }

        var isExpired: Bool {
            DispatchTime.now() >= expiresAt
        }

        /// Microseconds left, never negative.
        private var remainingMicros: UInt64 {
            let now = DispatchTime.now()
            guard expiresAt > now else { return 0 }
            return (expiresAt.uptimeNanoseconds - now.uptimeNanoseconds) / 1_000
        }

        /// Remaining budget for a sleep, capped at `cap` so a nearly-spent deadline
        /// cannot stretch a fixed wait past the ceiling.
        func sleepBudgetMicros(cappedAt cap: UInt32) -> UInt32 {
            UInt32(min(UInt64(cap), remainingMicros))
        }
    }

    private func smcError(_ operation: String, key: String, result: kern_return_t) -> String {
        let errorDesc = String(cString: mach_error_string(result), encoding: String.Encoding.ascii) ?? "unknown error"
        return "[\(key)] \(operation) failed: \(errorDesc) (0x\(String(result, radix: 16)))"
    }

    /// Writes `value`, retrying on failure.
    ///
    /// - Parameters:
    ///   - maxAttempts: upper bound on write attempts (the sleep budget may end the
    ///     loop earlier).
    ///   - delayMicros: sleep between attempts.
    ///   - deadline: optional wall-clock ceiling shared across a longer operation.
    private func writeWithRetry(_ value: SMCVal_t,
                                maxAttempts: Int = UnlockTiming.writeAttempts,
                                delayMicros: UInt32 = UnlockTiming.writeDelayMicros,
                                deadline: Deadline? = nil) -> Bool {
        let mutableValue = value
        var lastResult: kern_return_t = kIOReturnSuccess
        for attempt in 0..<maxAttempts {
            lastResult = write(mutableValue)
            if lastResult == kIOReturnSuccess {
                return true
            }
            if attempt < maxAttempts - 1 {
                if let deadline = deadline {
                    guard !deadline.isExpired else {
                        SMCLog.error(smcError("write", key: value.key, result: lastResult) + " (budget exhausted)")
                        return false
                    }
                    let sleep = deadline.sleepBudgetMicros(cappedAt: delayMicros)
                    if sleep > 0 { usleep(sleep) }
                } else {
                    usleep(delayMicros)
                }
            }
        }
        SMCLog.error(smcError("write", key: value.key, result: lastResult))
        return false
    }

    /// Hands one fan back to automatic control on Apple Silicon.
    ///
    /// `deadline` bounds the retries when the caller has a time budget, as the
    /// reset does. Without one, the writes retry on their own schedule, which
    /// is how a single `set 0` has always behaved.
    private func setFanAutomatic(_ id: Int, deadline: Deadline?) -> Bool {
        let modeKey = fanModeKey(id)
        let targetKey = "F\(id)Tg"

        if self.getValue(modeKey) != nil {
            var modeVal = SMCVal_t(modeKey)
            let readResult = read(&modeVal)
            guard readResult == kIOReturnSuccess else {
                SMCLog.error(smcError("read", key: modeKey, result: readResult))
                return false
            }
            if modeVal.bytes[0] != 0 {
                modeVal.bytes[0] = 0
                if !writeWithRetry(modeVal, deadline: deadline) { return false }
            }
        }

        var targetValue = SMCVal_t(targetKey)
        let result = read(&targetValue)
        guard result == kIOReturnSuccess else {
            SMCLog.error(smcError("read", key: targetKey, result: result))
            return false
        }

        let bytes = Float(0).bytes
        targetValue.bytes[0] = bytes[0]
        targetValue.bytes[1] = bytes[1]
        targetValue.bytes[2] = bytes[2]
        targetValue.bytes[3] = bytes[3]

        return writeWithRetry(targetValue, deadline: deadline)
    }

    private func unlockFanControl(fanId: Int) -> Bool {
        let deadline = Deadline(seconds: UnlockTiming.unlockBudgetSeconds)

        // Try direct mode write first (works on M5+ without Ftst)
        let modeKey = fanModeKey(fanId)
        var modeVal = SMCVal_t(modeKey)
        let modeRead = read(&modeVal)
        guard modeRead == kIOReturnSuccess else {
            SMCLog.error(smcError("read", key: modeKey, result: modeRead))
            return false
        }
        modeVal.bytes[0] = 1
        if write(modeVal) == kIOReturnSuccess {
            return true
        }

        // Direct failed; try Ftst unlock (M1-M4)
        var ftstVal = SMCVal_t("Ftst")
        let ftstResult = read(&ftstVal)
        guard ftstResult == kIOReturnSuccess, ftstVal.dataSize > 0 else {
            return false
        }

        if ftstVal.bytes[0] == 1 {
            return retryModeWrite(fanId: fanId, deadline: deadline)
        }

        ftstVal.bytes[0] = 1
        if !writeWithRetry(ftstVal, maxAttempts: UnlockTiming.ftstAttempts, deadline: deadline) {
            return false
        }

        // Wait for thermalmonitord to yield control
        let yieldMicros = deadline.sleepBudgetMicros(cappedAt: UnlockTiming.thermalmonitordYieldMicros)
        if yieldMicros > 0 {
            usleep(yieldMicros)
        }

        return retryModeWrite(fanId: fanId, deadline: deadline)
    }

    private func retryModeWrite(fanId: Int, deadline: Deadline? = nil) -> Bool {
        let modeKey = fanModeKey(fanId)
        var modeVal = SMCVal_t(modeKey)
        let result = read(&modeVal)
        guard result == kIOReturnSuccess else {
            SMCLog.error(smcError("read", key: modeKey, result: result))
            return false
        }
        modeVal.bytes[0] = 1
        // The attempt count is deliberately far larger than the budget allows to be
        // spent: the deadline is what actually terminates this loop, so the retry
        // window stays at "as long as the budget allows" rather than being cut to
        // an arbitrary attempt number.
        return writeWithRetry(modeVal,
                              maxAttempts: UnlockTiming.ftstAttempts * 15,
                              delayMicros: UnlockTiming.modeWriteDelayMicros,
                              deadline: deadline)
    }

    #endif

    public func resetFanControl() -> Bool {
        var success = true
        var hasFtst = false
        var ftstVal = SMCVal_t("Ftst")
        
        #if arch(arm64)
        // A single deadline covers the whole reset: the `Ftst` unlock, the yield,
        // the per-fan mode writes and the final `Ftst` relock all share it. This
        // previously capped out at ~11s (2 x 100 retries at 50 ms, plus sleeps).
        let deadline = Deadline(seconds: UnlockTiming.resetBudgetSeconds)

        let ftstReadResult = read(&ftstVal)
        hasFtst = (ftstReadResult == kIOReturnSuccess && ftstVal.dataSize > 0)
        
        if hasFtst {
            if ftstVal.bytes[0] != 1 {
                ftstVal.bytes[0] = 1
                if !writeWithRetry(ftstVal, maxAttempts: UnlockTiming.ftstAttempts, deadline: deadline) {
                    SMCLog.error("Failed to unlock Ftst for reset")
                } else {
                    // Wait briefly for thermalmonitord to yield control
                    let yieldMicros = deadline.sleepBudgetMicros(
                        cappedAt: UnlockTiming.thermalmonitordYieldMicros / 3
                    )
                    if yieldMicros > 0 { usleep(yieldMicros) }
                }
            }
        }
        #endif

        guard let count = getValue("FNum") else { return false }
        for i in 0..<Int(count) {
            #if arch(arm64)
            // Share the reset's deadline. Without it, each fan's mode and target
            // writes could retry for about a second beyond the budget, which is
            // how a reset ran past the app's quit-time timeout.
            let fanReset = setFanAutomatic(i, deadline: deadline)
            #else
            let fanReset = setFanMode(i, mode: .automatic)
            #endif
            if !fanReset {
                success = false
            }
        }

        #if arch(arm64)
        if hasFtst {
            ftstVal.bytes[0] = 0
            if !writeWithRetry(ftstVal, maxAttempts: UnlockTiming.ftstAttempts, deadline: deadline) {
                success = false
            }
        }
        #endif

        return success
    }

    // MARK: - Low-Level connection methods

    private func read(_ value: UnsafeMutablePointer<SMCVal_t>) -> kern_return_t {
        var result: kern_return_t = 0
        var input = SMCKeyData_t()
        var output = SMCKeyData_t()

        input.key = FourCharCode(fromString: value.pointee.key)
        input.data8 = SMCKeys.readKeyInfo.rawValue

        result = call(SMCKeys.kernelIndex.rawValue, input: &input, output: &output)
        if result != kIOReturnSuccess {
            return result
        }

        value.pointee.dataSize = UInt32(output.keyInfo.dataSize)
        value.pointee.dataType = output.keyInfo.dataType.toString()
        input.keyInfo.dataSize = output.keyInfo.dataSize
        input.data8 = SMCKeys.readBytes.rawValue

        result = call(SMCKeys.kernelIndex.rawValue, input: &input, output: &output)
        if result != kIOReturnSuccess {
            return result
        }

        // The kernel reports `dataSize` in `readKeyInfo` and we echo it straight
        // back to ask for that many bytes, but the payload we hand back is a
        // fixed 32-element tuple inside a fixed-size stack struct. Copying
        // `dataSize` bytes unconditionally would smash the stack for any key whose
        // reported size exceeds the payload, so clamp against the real capacity of
        // both the destination and the source struct.
        let copyLength = min(
            Int(value.pointee.dataSize),
            min(value.pointee.bytes.count, SMCLimits.payloadCapacity)
        )
        if copyLength > 0 {
            memcpy(&value.pointee.bytes, &output.bytes, copyLength)
        }
        if Int(value.pointee.dataSize) > copyLength {
            SMCLog.error("[\(value.pointee.key)] truncated read: dataSize=\(value.pointee.dataSize) > capacity=\(copyLength)")
        }
        return kIOReturnSuccess
    }

    private func write(_ value: SMCVal_t) -> kern_return_t {
        var input = SMCKeyData_t()
        var output = SMCKeyData_t()

        let capacity = MemoryLayout<SMCKeyData_t.SMCBytes_t>.size
        precondition(capacity == SMCLimits.payloadCapacity,
                     "SMCLimits.payloadCapacity must match SMCKeyData_t.SMCBytes_t")

        // `input.bytes` is a fixed-size tuple and the value's buffer is fixed at the
        // same capacity, so an undersized value would trap below and an oversized
        // `dataSize` would make the kernel read past the end of `input`. Refuse the
        // former and clamp the latter.
        guard value.bytes.count >= capacity else {
            SMCLog.error("[\(value.key)] write skipped: value holds \(value.bytes.count) bytes, need \(capacity)")
            return kIOReturnError
        }
        let writeLength = min(Int(value.dataSize), capacity)

        input.key = FourCharCode(fromString: value.key)
        input.data8 = SMCKeys.writeBytes.rawValue
        input.keyInfo.dataSize = IOByteCount32(writeLength)
        if Int(value.dataSize) > writeLength {
            SMCLog.error("[\(value.key)] truncated write: dataSize=\(value.dataSize) > capacity=\(writeLength)")
        }
        input.bytes = (value.bytes[0], value.bytes[1], value.bytes[2], value.bytes[3], value.bytes[4], value.bytes[5],
                       value.bytes[6], value.bytes[7], value.bytes[8], value.bytes[9], value.bytes[10], value.bytes[11],
                       value.bytes[12], value.bytes[13], value.bytes[14], value.bytes[15], value.bytes[16], value.bytes[17],
                       value.bytes[18], value.bytes[19], value.bytes[20], value.bytes[21], value.bytes[22], value.bytes[23],
                       value.bytes[24], value.bytes[25], value.bytes[26], value.bytes[27], value.bytes[28], value.bytes[29],
                       value.bytes[30], value.bytes[31])

        let result = self.call(SMCKeys.kernelIndex.rawValue, input: &input, output: &output)
        if result != kIOReturnSuccess {
            return result
        }

        if output.result != 0x00 {
            return kIOReturnError
        }

        return kIOReturnSuccess
    }

    private func call(_ index: UInt8, input: inout SMCKeyData_t, output: inout SMCKeyData_t) -> kern_return_t {
        if conn == 0 { return kIOReturnNotOpen }
        let inputSize = MemoryLayout<SMCKeyData_t>.stride
        var outputSize = MemoryLayout<SMCKeyData_t>.stride
        return IOConnectCallStructMethod(conn, UInt32(index), &input, inputSize, &output, &outputSize)
    }
}
