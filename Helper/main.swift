//
//  main.swift
//  Fan Control Helper CLI
//

import Foundation
import Darwin

struct FanJSON: Codable {
    let id: Int
    let name: String
    let currentSpeed: Int
    let minSpeed: Int
    let maxSpeed: Int
    let targetSpeed: Int
    let mode: Int
}

struct SystemStatusJSON: Codable {
    let fans: [FanJSON]
    let cpuTemp: Double?
    let gpuTemp: Double?
    let batteryTemp: Double?
}

// MARK: - Output contract
//
// stdout is the channel a caller parses; stderr is everything else. `get` puts
// a JSON document on stdout and nothing else, so a caller can decode stdout
// without first having to filter diagnostics out of it — which is the whole
// point, and the reason the two channels must never be merged into one pipe.
// Diagnostics and errors therefore always go to stderr, including for `set`
// and `reset`, so that "stdout is non-empty" means "this command succeeded".

private func logDiagnostic(_ line: String) {
    FileHandle.standardError.write(Data((line + "\n").utf8))
}

func printHelpText() -> String {
    """
    SMC Fan Control Helper CLI
    Usage:
      smc-helper get
      smc-helper set <fanId> <mode> [<speed>]   (mode: 0 = auto, 1 = manual; speed in RPM)
      smc-helper setall <percent>               (0.0...1.0, of each fan's own min/max range)
      smc-helper reset

    Environment:
      SMC_HELPER_VERBOSE=1                      Keep SMC diagnostics on stderr for `get`.
      FANCONTROL_UNLOCK_BUDGET_SECONDS=<n>      Wall-clock ceiling for one unlock attempt (default 8).
      FANCONTROL_RESET_BUDGET_SECONDS=<n>      Wall-clock ceiling for one reset (default 6).

    Output:
      stdout carries the machine-readable result only — one JSON document for
      `get`, one SUCCESS line for `set`/`setall`/`reset`. Diagnostics, errors, and
      this help text go to stderr.
    """
}

func printHelp() {
    print(printHelpText())
}

// MARK: - Temperature sensors
//
// The candidate key lists below are deliberately broad: different MacBook models
// expose different subsets, and a key that is absent simply fails to read.
//
// COST NOTE
// `get` performs ~41 SMC reads per invocation (fan metadata + 15 CPU + 8 GPU +
// 6 battery temperature candidates), and the app re-execs this binary every poll
// interval. Measured on an M5 Max, one invocation costs about 4 ms of CPU, so the
// poll loop is well under 1% of a core at one poll per second. Fork-per-poll is
// not the cost to optimise; a poll that stalls is the risk, and the app bounds
// each poll with a timeout. Reads do not need root, so the app could read the
// SMC in-process if that is ever worth a change to the CLI contract that the app
// depends on (`Process` + JSON on stdout).
//
// Within that constraint, the reads below were made cheaper only where the result
// is provably identical. Sensor *selection* semantics are a thermal-safety
// decision and are unchanged; see `getMaximumValidTemp`.
private let cpuTemperatureKeys = [
    "TC0P", "TC0D", "TC0F", "TC1C", "TCAD", "TCBD",
    "Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D", "Tp0C", "Tp0g", "Tp0h", "Te0S"
]
private let gpuTemperatureKeys = [
    "TG0D", "TG0H", "TG0P",
    "Tg05", "Tg0j", "Tg0g", "Tg01", "Tg0c"
]
private let batteryTemperatureKeys = [
    "TB0T", "TB1T", "TB2T", "Tw0P", "Ts0P", "Th0H"
]

/// Range a die/battery temperature must fall in to be considered real.
/// Some Apple Silicon SMC keys briefly report implausibly small non-zero values.
private let plausibleTemperatureRange: ClosedRange<Double> = 10...115

private func isPlausibleTemperature(_ value: Double) -> Bool {
    value.isFinite
        && plausibleTemperatureRange.contains(value)
}

func getStatus() {
    let smc = SMC.shared
    
    guard let fanCountVal = smc.getValue("FNum") else {
        print("{}")
        return
    }
    
    let fanCount = Int(fanCountVal)
    var fansList: [FanJSON] = []
    
    for i in 0..<fanCount {
        let name = smc.getStringValue("F\(i)ID") ?? "Fan \(i)"
        let current = Int(smc.getValue("F\(i)Ac") ?? 0)
        let minS = Int(smc.getValue("F\(i)Mn") ?? 0)
        let maxS = Int(smc.getValue("F\(i)Mx") ?? 0)
        let target = Int(smc.getValue("F\(i)Tg") ?? 0)
        
        let modeKey = smc.fanModeKey(i)
        let mode = Int(smc.getValue(modeKey) ?? 0)
        
        fansList.append(FanJSON(
            id: i,
            name: name,
            currentSpeed: current,
            minSpeed: minS,
            maxSpeed: maxS,
            targetSpeed: target,
            mode: mode
        ))
    }
    
    // Returns the first key that reports a plausible temperature, in list order.
    // Short-circuits, so GPU and battery cost one read per candidate at worst.
    func getFirstValidTemp(keys: [String]) -> Double? {
        for key in keys {
            if let value = smc.getValue(key), isPlausibleTemperature(value) {
                return value
            }
        }
        return nil
    }

    // THERMAL SAFETY: the CPU candidate keys describe several plausible
    // CPU-adjacent sensors, and every one of them is read. Using the highest valid
    // reading is deliberately conservative — it makes the reported CPU temperature
    // the warmest of the candidates, so automatic rules err towards spinning the
    // fans up rather than down, and it avoids the result depending on whichever key
    // happens to respond first.
    //
    // This "read all, take the max" behaviour is intentional. Do not convert this
    // into a first-match short circuit.
    func getMaximumValidTemp(keys: [String]) -> Double? {
        // Folded rather than `compactMap(...).max()`: same result, but it avoids
        // materialising a 15-element intermediate array on every poll.
        var best: Double?
        for key in keys {
            guard let value = smc.getValue(key), isPlausibleTemperature(value) else {
                continue
            }
            if best == nil || value > best! {
                best = value
            }
        }
        return best
    }
    
    let cpuTemp = getMaximumValidTemp(keys: cpuTemperatureKeys)
    let gpuTemp = getFirstValidTemp(keys: gpuTemperatureKeys)
    let batteryTemp = getFirstValidTemp(keys: batteryTemperatureKeys)
    
    let status = SystemStatusJSON(
        fans: fansList,
        cpuTemp: cpuTemp,
        gpuTemp: gpuTemp,
        batteryTemp: batteryTemp
    )
    
    if let jsonData = try? JSONEncoder().encode(status),
       let jsonString = String(data: jsonData, encoding: .utf8) {
        print(jsonString)
    } else {
        print("{}")
    }
}

/// Applies one fan command and reports what happened, instead of exiting.
///
/// Shared by the `set` and `setall` verbs so both drive the SMC through exactly
/// the same call sequence — forced mode first, then the target RPM — and so a
/// change to one cannot silently diverge from the other.
///
/// - Note: `setFanSpeed` performs its own clamp to `F<i>Mx`. `setall` also
///   clamps against the range it read, so the value arriving here is already
///   inside the fan's envelope and the clamp is a no-op. That is deliberate:
///   keeping the clamp inside `SMC` means no caller can skip it.
private func writeFan(_ smc: SMC, fanId: Int, mode: Int, speed: Int?) -> (success: Bool, message: String) {
    if mode == 0 {
        // Automatic mode
        if smc.setFanMode(fanId, mode: .automatic) {
            return (true, "Fan \(fanId) set to Automatic")
        }
        return (false, "Failed to set Fan \(fanId) to Automatic")
    }

    if mode == 1 {
        // Manual mode
        guard let targetSpeed = speed else {
            return (false, "Speed in RPM is required for manual mode")
        }

        // 1. Set mode to forced
        guard smc.setFanMode(fanId, mode: .forced) else {
            return (false, "Failed to set Fan \(fanId) mode to Manual")
        }

        // 2. Set speed
        guard smc.setFanSpeed(fanId, speed: targetSpeed) else {
            return (false, "Failed to set Fan \(fanId) speed to \(targetSpeed) RPM")
        }
        return (true, "Fan \(fanId) set to Manual (\(targetSpeed) RPM)")
    }

    return (false, "Invalid mode. Use 0 for auto, 1 for manual.")
}

func setFan(fanId: Int, mode: Int, speed: Int?) {
    let outcome = writeFan(SMC.shared, fanId: fanId, mode: mode, speed: speed)
    if outcome.success {
        print("SUCCESS: \(outcome.message)")
    } else {
        logDiagnostic("ERROR: \(outcome.message)")
        exit(1)
    }
}

/// Drives every fan to the same fraction of its own min…max span.
///
/// This replaces what used to be N separate `smc-helper set` processes: one
/// `AppleSMC` connection, one process, N fans. Two properties keep it
/// semantically identical to that loop.
///
///   1. The target is computed **per fan** from that fan's own `F<i>Mn` and
///      `F<i>Mx`, so fans with different spans each land on the same percentage
///      of their own range. Raw RPM is never carried across fans.
///   2. A failure on one fan does not abort the rest. `writeFan` returns instead
///      of exiting, because exiting would be harmless when each fan had its own
///      process but would strand every fan after the first failure once they
///      share one.
func setAllFans(percent: Double) {
    let smc = SMC.shared

    guard let fanCountValue = smc.getValue("FNum"), fanCountValue >= 0 else {
        logDiagnostic("ERROR: Failed to read the fan count (FNum); no fan was changed.")
        exit(1)
    }
    let fanCount = Int(fanCountValue)

    var failureCount = 0
    for i in 0..<fanCount {
        let minSpeed = Int(smc.getValue("F\(i)Mn") ?? 0)
        let maxSpeed = Int(smc.getValue("F\(i)Mx") ?? 0)
        let range = Double(maxSpeed - minSpeed)
        let target = Double(minSpeed) + range * percent
        // `percent` is validated to 0...1 before this is called and the range
        // comes from the SMC, so the computed value is already inside the fan's
        // own envelope. Clamp anyway, so a nonsensical key can never turn into
        // a request for an RPM the fan does not support.
        let clamped = min(max(target, Double(minSpeed)), Double(maxSpeed))

        let outcome = writeFan(smc, fanId: i, mode: 1, speed: Int(clamped))
        if !outcome.success {
            logDiagnostic("ERROR: \(outcome.message)")
            failureCount += 1
        }
    }

    let percentText = String(format: "%.2f", percent * 100)
    if failureCount > 0 {
        logDiagnostic("ERROR: \(failureCount) of \(fanCount) fan(s) failed at \(percentText)%")
        exit(1)
    }
    print("SUCCESS: \(fanCount) fan(s) set to \(percentText)% of their own speed range")
}

func fail(_ message: String, showHelp: Bool = true) -> Never {
    logDiagnostic("ERROR: \(message)")
    if showHelp {
        // Usage text accompanies an error, so it belongs with the error.
        logDiagnostic(printHelpText())
    }
    exit(1)
}

func main() {
    // The app launches this helper once per poll and may tear the process down as
    // soon as it has read its JSON. Ignoring SIGPIPE turns a closed stdout pipe
    // from "process killed by signal 13" into an ordinary write failure we can
    // exit cleanly from, instead of dying mid-write.
    signal(SIGPIPE, SIG_IGN)

    let args = CommandLine.arguments
    guard args.count > 1 else {
        printHelp()
        return
    }

    // `get` writes a machine-readable JSON document to stdout that the app decodes
    // directly, so SMC diagnostics are suppressed for that command unless the
    // caller explicitly asks for them. `set`/`setall`/`reset` output is only ever
    // read by a human, so their diagnostics are always kept.
    let cmd = args[1].lowercased()
    let verbose = ProcessInfo.processInfo.environment["SMC_HELPER_VERBOSE"] == "1"
    SMCLog.isSuppressed = (cmd == "get") && !verbose

    switch cmd {
    case "get":
        guard args.count == 2 else {
            fail("'get' takes no arguments")
        }
        getStatus()
    case "set":
        guard args.count >= 4 else {
            fail("Missing arguments for 'set'")
        }
        guard args.count <= 5 else {
            fail("Too many arguments for 'set': expected '<fanId> <mode> [<speed>]'")
        }
        guard let fanId = Int(args[2]), fanId >= 0 else {
            fail("Invalid fanId: '\(args[2])' (expected a non-negative integer)")
        }
        guard let mode = Int(args[3]), (0...1).contains(mode) else {
            fail("Invalid mode: '\(args[3])' (expected 0 for auto or 1 for manual)")
        }
        var speed: Int?
        if args.count > 4 {
            guard let parsed = Int(args[4]), parsed >= 0 else {
                fail("Invalid speed: '\(args[4])' (expected a non-negative integer)")
            }
            speed = parsed
        }
        if mode == 1, speed == nil {
            fail("Speed in RPM is required for manual mode")
        }
        setFan(fanId: fanId, mode: mode, speed: speed)
    case "setall":
        guard args.count == 3 else {
            fail("'setall' takes exactly one argument: '<percent>'")
        }
        // `isFinite` matters: `Double("nan")` and `Double("1e999")` both parse.
        guard let percent = Double(args[2]), percent.isFinite, (0.0...1.0).contains(percent) else {
            fail("Invalid percentage: '\(args[2])' (expected a fraction between 0 and 1, e.g. 0.65)")
        }
        setAllFans(percent: percent)
    case "reset":
        guard args.count == 2 else {
            fail("'reset' takes no arguments")
        }
        let success = SMC.shared.resetFanControl()
        if success {
            print("SUCCESS: Reset fan controls")
        } else {
            logDiagnostic("ERROR: Failed to reset fan controls")
            exit(1)
        }
    case "help", "--help", "-h":
        printHelp()
    default:
        fail("Unknown command '\(args[1])'")
    }
}

main()
