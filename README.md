# macOS Fan Control Utility

A sleek, native SwiftUI macOS application designed for real-time monitoring and manual/automated control of MacBook fan speeds. Compatible with both Intel and Apple Silicon (M1/M2/M3/M4/M5+) architectures.

![Main dashboard](screenshot.png)

![Dashboard with temperature history](screenshot1.png)

![Rules engine and setup details](screnshoot2.png)


It features a dual-component design: a SwiftUI GUI front-end that runs the setuid command-line helper (`smc-helper`) to read and write System Management Controller (SMC) registers.

The app is **not** sandboxed and does not claim to be. Driving the SMC requires a
root-privileged process, and that process ships inside the app bundle, so App
Sandbox would have to be switched off for the app to work at all. What the build
does assert is a hardened-runtime signature: both binaries are signed with
`--options runtime`, and the app carries a deliberately minimal entitlements file
whose only entry is `com.apple.security.get-task-allow = false`, so a distributed
build cannot be attached to with a debugger.

---

## Features

- **Real-Time RPM Monitor**: Displays actual fan speeds with a custom rotating vector fan blade animation that responds to changes in RPM.
- **Auto-Trigger Rules Engine**: Set custom, automated temperature rules for **CPU**, **GPU**, or **Battery** (e.g., _if CPU ≥ 75°C, override all fans to 80%_). Multiple active rules are evaluated dynamically, prioritizing the highest safety speed, and automatically returning control to macOS once the sensors cool down. The first-run starter rules are gentle curves: CPU ramps from 20% at 50 °C to 85% at 90 °C, and battery ramps from 15% at 35 °C to 60% at 45 °C. They start disabled, so nothing changes until you turn the rules engine on.
- **Stable Automatic Response**: Independently configurable rise (default 6%/s) and fall (default 3%/s) command rates, cooling hysteresis (default 5°C), a target deadband (default 4%), and an 8-second cooling confirmation reduce audible target hunting while retaining a prompt thermal response. Requests of 90% or more bypass the rate limit.
- **Manual Mode Controls**: Precise target speed adjustment sliders, with the detent derived from each fan's own RPM span rather than a fixed step.
- **Quick Presets**: Set speed thresholds instantly using the **Min**, **20%**, **50%**, **80%**, or **Max** buttons.
- **Linked Fan Tuning**: Option to sync adjustments across all system fans simultaneously. The initiating fan's *percentage* is projected into every other fan's own min/max range, so two fans with different RPM spans still receive the same fraction of their range instead of one fan's raw RPM.
- **System Metrics**: Monitors battery and sensor temperatures alongside active speed states.
- **Menu-bar readout**: Shows the first fan's speed, rounded to the nearest 50 RPM with no thousands separator. The readout sits in a slot sized for the widest value the fan can show, so the menu-bar item keeps one width as the speed changes.
- **Temperature history**: Keeps 24 hours of samples, one every 30 seconds, in an append-only file at `~/Library/Application Support/com.pair.FanControl/temperature-history.jsonl`. The chart's rolling window moves every five seconds.
- **Sensor validation**: A single implausible reading is ignored. A sustained change is accepted after three agreeing readings, about two seconds, so a real change is never frozen out.
- **Sleep, wake and fan drift**: After wake, the app re-sends its current command. If a fan is found in automatic mode while a rule is in charge, the command is re-sent, at most once every 30 seconds, and not after a failed write.
- **Lost-Control Watchdog**: If the helper stops answering for five consecutive 1 Hz polls while a rule is in charge, the app hands the fans back to macOS Auto and says so in the window. It would rather lose control than keep commanding fans it can no longer confirm.
- **Your rules file is never silently overwritten.** A saved rules payload that
  cannot be decoded is left **untouched on disk**, the rules engine is switched
  **off** so macOS keeps driving the fans, and a localized message says what
  happened. Only a genuinely absent payload seeds the starter rules. See
  [Rules durability](#rules-durability-a-data-loss-bug-that-was-real).
- **Safe Exit**: Quitting — via ⌘Q, the menu-bar **Quit** item, or a `SIGTERM`/`SIGINT`/`SIGHUP` — releases manual overrides before the process goes away. **Force Quit (`kill -9`) cannot be caught by any process**, so that path leaves the fans latched at the last written RPM. See [Safety & System Restoration](#-safety--system-restoration).
- **Native macOS localization**: 99 keys across English, French, German, Spanish, and Simplified Chinese, automatically following the system or per-app language setting. English and French have been manually verified; the other three still need native-speaker review and must not be presented as release-ready translations.

---

## 📂 Project Architecture & Code Structure

The codebase is organized into clean, single-responsibility files conforming to MVVM patterns:

- 📂 **`Core/`**: The logic that does not need a window.
  - `SMC.swift`: The raw AppleSMC register reads/writes, data-type decoding, and the Apple Silicon fan-unlock and reset sequences.
  - `FanControlLaw.swift`: The extracted control law — sensor conditioning (`TemperatureConditioner`), rule aggregation, the target deadband, the slew-rate limiter on a monotonic clock, cooling hysteresis, and cooling confirmation. A plain value type with no SwiftUI, `Process`, or `UserDefaults`, so thermal behaviour is reviewable and testable on its own. `tests/run-tests.sh` compiles it with its models and runs the checks in `tests/unit/`.
  - `Localization.swift`: The `L10n` wrapper used for labels assembled at runtime. `format` localizes decimals; `formatCount` formats whole counts such as RPM without a thousands separator. See [docs/LOCALIZATION.md](docs/LOCALIZATION.md).
- 📂 **`Models/`**: Shared structs (`FanJSON.swift`, `TempRecord.swift`) describing deserialized telemetry packages, auto-rules, and history records. `FanJSON.swift` also holds `TriggerRule` and its `starterRules`, the first-run curves.
- 📂 **`ViewModels/`**: Orchestration logic. `FanViewModel.swift` is an adapter: it polls the helper, conditions the samples, hands them to `FanControlLaw`, publishes what the law decides, and owns the privileged-helper invocation. Every helper write goes through one serial queue, so writes never overlap. It no longer contains fan-control decisions of its own. It is a single shared instance (`FanViewModel.shared`); a second instance would poll the helper and run the rules on its own.
  - `FanStores.swift`: The state the window observes, split by how often it changes. `FanTelemetry` holds the live fan readings, `MenuBarStatus` the rounded menu-bar RPM and the width reserved for it, and `FanHistoryStore` the 24-hour temperature history, kept as an append-only file in Application Support.
- 📂 **`tests/`**: Plain executable checks for the control law and the stores, run with `tests/run-tests.sh`. There is no XCTest target.
- 📂 **`Views/`**: Reusable SwiftUI layout pieces.
  - `SpinningFanView.swift`: Animated Core Animation fan widget.
  - `TempHistoryChartView.swift`: Multi-series temperature and fan-target history graph. `TempHistoryChartContainer` refreshes it every five seconds.
  - `FanControlRow.swift`: Single-fan state picking and speed slider row.
  - `RulesEngineView.swift`: Dynamic rules addition board and fan-response tuning.
  - `ContentView.swift`: Window layout coordinator. The fan cards are in `FanRowsView`, which observes live readings on its own.
- 📂 **`App/`**: Application entry scene (`FanControlApp.swift`) plus the `NSApplicationDelegate` that owns menu-bar access, window reopening, and the termination-time fan release.
- 📂 **`Helper/`**: Privilege operations wrapper (`main.swift`) serving as a setuid execution client. It shares only `SMC.swift` with the app — the control law has no business inside a root process.

---

## Prerequisites

- **Operating System**: macOS 13.0 Ventura or newer.
- **Build Tools**: Swift compiler (installed via Xcode or Xcode Command Line Tools).

---

## 🛠️ Build and Compilation

Clone the repository and run the automated packager script inside the project directory:

```bash
# Make the build script executable
chmod +x build.sh

# Compile and package the application bundle
./build.sh
```

This compiles `smc-helper` and `FanControl`, drafts the app metadata (`Info.plist`), generates a real `AppIcon.icns` from `app_icon.png` with `sips` + `iconutil`, writes an entitlements plist, code-signs everything with the hardened runtime, and outputs a standard application bundle: **`Fan Control.app`**. It normally also creates **`Fan Control.dmg`**. If the local macOS environment cannot create a disk image, it creates **`Fan Control.zip`** instead; unzip it and move the app to Applications.

Notable details of the current script:

- Both binaries compile with `-O -whole-module-optimization`. (`swiftc` defaults to `-Onone` when no optimization flag is passed, so this has to be explicit.)
- `AppIcon.icns` is compiled from a correctly sized `.iconset`. Copying a bare `AppIcon.png` into `Resources` does not give the app an icon — the Finder and Dock read `CFBundleIconFile` as an `.icns`.
- The version is single-sourced: `APP_VERSION` feeds both `CFBundleShortVersionString` and the DMG volume name. The window header's `v…` badge reads `CFBundleShortVersionString` from `Bundle.main` at runtime rather than hardcoding a string, so all three stay in step.
- Notarization is **opt-in and has not been exercised on this machine**. Set `NOTARY_PROFILE` to a `notarytool` store-credentials profile to submit and staple; leave it unset and the build never touches the network.
- `SETUID_HELPER=1` applies the setuid bit to the bundled helper after signing. It is **off by default**, and it is a convenience only — see [Configure Privilege Setup](#2-configure-privilege-setup-required-once).

By default, the build script pins the app and helper binaries to macOS 13.0 and creates a Universal 2 bundle for both Intel and Apple Silicon Macs. Every knob is overridable from the environment:

| Variable | Default | Purpose |
|---|---|---|
| `MACOS_DEPLOYMENT_TARGET` | `13.0` | Minimum macOS for both binaries and `LSMinimumSystemVersion`. |
| `ARCHS` | `arm64 x86_64` | Architectures to compile and lipo together. A single value skips `lipo`. |
| `SIGNING_IDENTITY` | the original Developer's Developer ID | Falls back to ad-hoc (`-`) if that identity is not in the keychain. |
| `BUILD_DIR` | `.build` | Scratch directory for intermediates, module cache, entitlements. |
| `APP_VERSION` | `2.0` | `CFBundleShortVersionString` and DMG volume name. |
| `BUILD_NUMBER` | `1` | `CFBundleVersion`. |
| `NOTARY_PROFILE` | *(unset)* | `notarytool` profile name. Unset means no notarization. |
| `SETUID_HELPER` | `0` | `1` applies `chmod 4755` to the bundled helper (setuid root + executable by the logged-in user). See [the `4755` trade-off](#why-4755-is-the-mode-and-why-it-is-a-trade-off). |

```bash
MACOS_DEPLOYMENT_TARGET=14.0 ARCHS="arm64" ./build.sh
```

For a local build without the original developer's signing certificate, use an ad hoc signature:

```bash
ARCHS="arm64" SIGNING_IDENTITY="-" ./build.sh
```

Two read-only check scripts assert the packaging invariants after a build, and
both run in CI:

```bash
./.github/scripts/verify-build.sh          # signature, archs, minos, optimization, icon, localizations
./.github/scripts/check-localization.sh   # .strings key parity across languages
```

Unit checks for the control law, the history and telemetry stores, the starter
rules and the localization helper are plain executable assertions, with no
XCTest target. They need no window server, signing or helper:

```bash
tests/run-tests.sh                        # compiles tests/unit/ with the shared sources and runs it
```

CI does not run these checks yet. Run them locally before a change to the
control law or the stores.

---

## 🚀 How to Run the App

1. **Launch the Application**:
   Open the application bundle in Finder or launch it from your terminal:

   ```bash
   open "Fan Control.app"
   ```

2. **Configure Privilege Setup (Required Once)**:
   Writing custom values to the SMC requires administrative permission. On the first launch, follow these steps to configure access:
   - Click the orange **"Authorize & Enable Fan Adjustments"** button in the app window.
   - Enter your macOS administrator password when prompted.

   That step runs `chown root:wheel` and `chmod 4755` on the helper, then **reads
   the permissions back** rather than assuming the shell succeeded — a hardened
   runtime, an ACL, or a read-only volume can turn the `chmod` into a silent
   no-op, and the app will tell you so rather than act as if it is authorized.

   _Alternatively, you can set the privileged helper permissions by hand:_

   ```bash
   sudo chown root:wheel "Fan Control.app/Contents/MacOS/smc-helper"
   sudo chmod 4755 "Fan Control.app/Contents/MacOS/smc-helper"
   ```

#### Why `4755` is the mode, and why it is a trade-off

**`4755`, not `4700`, and not `chmod +s` on a tighter base.** The app spawns the
helper **directly with `Process`, running as the logged-in user**. It never runs
it through `sudo`. The helper therefore *must* be executable by that user, which
rules the restrictive modes out on mechanical grounds:

| Mode | What happens |
|---|---|
| `4700` | Only root can execute it. The logged-in user gets `EACCES`, `Process.run()` fails, and **every thermal poll is lost** — the app sits on "Reading SMC registers…" forever. |
| `4750 root:wheel` | Same failure, for a different reason: an ordinary user is in group `staff`, not `wheel`. |
| **`4755`** | **What ships**, in both `FanViewModel.authorize()` and the opt-in `SETUID_HELPER=1` build path. Setuid root *and* executable by the logged-in user. |

The shipped helper is `0755`, so `chmod +s` lands on `4755` anyway — which is
why the in-app authorize step and the build script both spell the full mode out
rather than relying on `+s`.

Note that a setuid bit applied inside the bundle does **not** survive the trip
out of a DMG: copying the app into `/Applications` gives the file your
ownership and default permissions. That is why the in-app authorize step
exists, and why it re-checks after running. `SETUID_HELPER=1` at build time
only helps if the resulting bundle is installed without the file being
rewritten.

#### The exposure this creates, stated plainly

Setuid-root **plus** world-executable is a real exposure, and this design cannot
remove it. A helper installed that way accepts
`smc-helper set <id> 1 <rpm>` from anyone who can execute it: any local user —
or any malware running as that user — can drive your fans, including to zero.
Three things bound it today:

- the helper's command surface is minimal and unchanged: `get`, `set`, `reset`;
- both binaries are signed with the **hardened runtime**, so **library
  validation** blocks a `DYLD_*` injection into the setuid binary;
- `checkAuthorization()` rejects a helper that is not root-owned, is not setuid,
  is not executable, or is **writable by group or other** — the last of which
  would otherwise let an unprivileged user replace the binary that runs as root.

What it does **not** do is identify the caller. The correct fix is an **XPC
privileged helper (`SMJobBless`)** that authenticates the connecting process, so
that only the signed GUI app can obtain SMC writes. That is documented follow-up,
not shipped — see [`SECURITY.md`](SECURITY.md) for the full threat model and
[`docs/FORK_CHANGELOG.md`](docs/FORK_CHANGELOG.md) for the follow-up list. Treat
the current posture as *functional and bounded, not safe in the strict sense*.

> **Diagnosing a permissions problem.** It reports as a **missing file**, which
> sends people hunting a packaging bug that does not exist. `Foundation`
> surfaces an `EACCES` on `exec` as `NSCocoaErrorDomain` **Code=4, "the file
> doesn't exist"**
> ([Apple Developer Forums thread 726994](https://developer.apple.com/forums/thread/726994)).
> The app's `runHelper` now detects that exact domain/code pair and prints an
> explicit hint about `ls -l`, mode `4755`, and the fact that the helper is run
> directly rather than via `sudo`
> (`runHelper` in `ViewModels/FanViewModel.swift`).

---

## 🔒 Safety & System Restoration

To return your fans to macOS automatic controller management:

- Select **Auto** in the mode picker for individual fans.
- Click the **"Reset All to Auto"** button, in the window or in the menu-bar menu.
- Quitting the app also releases manual overrides. `⌘Q`, the menu-bar **Quit**
  item, and `SIGTERM`/`SIGINT`/`SIGHUP` all reach an application delegate that
  invalidates the poll timer, refuses any new write, and then runs the helper's
  `reset` **synchronously**. The reset joins the same serial queue as every
  other write, so it runs after any write already in flight. The app waits at
  most 12 seconds for it, and the helper itself is stopped after 8 seconds, which
  leaves room for its own 6-second budget. The release runs at most once per
  process. The 10-second `exit(0)` backstop is scheduled on the main thread,
  which is blocked during that wait, so it cannot fire until the wait ends. The
  12-second bound is the real ceiling. A reset that cannot finish within it is
  abandoned, and the app quits. In the worst case, quitting or logging out can
  stall for up to about 12 seconds.

### Rules durability: a data-loss bug that was real

`loadRules()` used to read as one condition with one fallback:

```swift
if let data = …, let decoded = try? JSONDecoder().decode(…) { … } else { starter rules }
```

That made "you have no saved rules" and "your saved rules failed to decode"
**indistinguishable**. Both took the `else` branch. And because `rules` has a
`didSet` that calls `saveRules()`, substituting the starter defaults **wrote
them straight back over the user's file**. A rules file written by a newer
version, or hand-edited into an invalid shape, therefore destroyed itself on the
next launch — silently, with no error. All the user saw was their thresholds
gone and the rules engine inexplicably inert.

The two cases are now distinguished. A genuinely absent payload still seeds the
starter rules. A **decode failure** leaves the stored bytes **untouched on
disk**, resets the display to empty under a `suppressRuleSaving` guard so the
recovery assignment cannot itself trigger a write, **disables the rules engine**
so the failure is safe — macOS keeps driving the fans — and surfaces a localized
message explaining it. Verified on hardware: a planted invalid rule was launched,
the engine went off, the original bytes survived, and the fans were untouched.
See `loadRules()` in `ViewModels/FanViewModel.swift`.

It is worth naming as a class of bug rather than a one-off: a `try?` inside an
`if let` chain conflates *absent* with *invalid*, and a `didSet` that persists
turns a read failure into a write. Either one alone is survivable.

### Verified on hardware

Measured on an **Apple M5 Max MacBook Pro, macOS 27.2**, against the `4755`
helper described above. Not a claim about every Mac.

| Check | Result |
|---|---|
| Helper read path | Valid JSON on stdout, **0 bytes on stderr** — the stdout/stderr split holds, so diagnostics cannot corrupt the payload channel. |
| Manual control accuracy | Commanded **3000 RPM → actual 3002**; commanded **6500 → actual 6499**. |
| `reset` | Returns all fans to macOS automatic control (**mode 0**); macOS resumes managing them. |
| Rules engine, end to end | Rule `CPU ≥ 55 °C → 45 %` at a live CPU of **65.8 °C** produced `setall 45.00 %`; both fans landed on target **4796 RPM = exactly 45.00 %** of each fan's own 2317–7826 range, and the engine then correctly stopped issuing redundant writes. |
| Quit safety | With fans app-controlled at 4796 RPM, `SIGTERM` → process exits → fans return to **mode 0 AUTO**. (`SIGKILL` remains uncatchable — see below.) |
| Rules decode failure | Planted invalid rule → engine disabled, original bytes survived, fans untouched. |

The table above was measured on an earlier build, before the changes in
[the Round 4 record](docs/FORK_CHANGELOG.md#round-4--2026-10-13-single-controller-write-ordering-and-the-menu-bar).
Checked since, on the installed build: the helper is `root:wheel`, mode `4755`
after authorization, and the fans read back in automatic mode. **Not yet
verified on hardware:** the drift re-send under a live rule, the menu-bar width
across a range of readings, the moving chart, and the starter curves under load.

### Known limitations

- **Upgrading from a build before Round 4.** Replacing the app drops the
  helper's authorization, so click **Authorize** again. Saved rules carry over.
  The history is moved once from UserDefaults into the Application Support file.
  If you go back to an older build, that history is not restored.

- **Closing the window does not reset anything.** The main window is ordered out
  instead of closed, and the app keeps polling and keeps applying rules. Use
  **Reset All to Auto**, or quit, if you want the fans handed back.
- **`kill -9` / Force Quit sends `SIGKILL`, which no process can catch.** The
  reset handler never runs, and the last written RPM stays latched in SMC
  hardware until you relaunch the app and reset, or restart the Mac. This is an
  OS-level limit, not something the app can work around — there is no handler for
  `SIGKILL` because the kernel does not deliver it.
- The lost-control watchdog needs **five consecutive failed polls** (about five
  seconds at the 1 Hz rate) before it resets, and only acts while a rule is
  applied. In manual-only mode there is no reset to issue.
- **The window can be restored off-screen.** On a wide multi-display setup the
  window has been observed coming back at an origin outside the visible area
  (x = −1728), which looks like the app failed to open. It is a saved-position
  problem, not a launch failure — the app is running and the menu-bar item is
  live. Known and unfixed.
- **The setuid exposure described above is not solved by this design.** If that
  matters to you, do not run the app as a user whose local accounts or malware
  you do not trust.

---

## 📄 License

This project is open-source software licensed under the [MIT License](LICENSE).

## Fork and upstream handoff notes

For the full change record, safety notes, local validation, and the proposed
upstream pull-request split for this fork, see [docs/FORK_CHANGELOG.md](docs/FORK_CHANGELOG.md).

The reviewer-facing summary of that contribution is in
[docs/UPSTREAM_PULL_REQUEST.md](docs/UPSTREAM_PULL_REQUEST.md).

Translation coverage and the standard macOS localization workflow are described
in [docs/LOCALIZATION.md](docs/LOCALIZATION.md).

The helper's privilege model, threat model, and vulnerability-reporting route are
described in [SECURITY.md](SECURITY.md).

## Upstream

This fork of [ShahzaibAli02/Fanny-MacOs-FanControl](https://github.com/ShahzaibAli02/Fanny-MacOs-FanControl)
tracks the upstream remote; the changes listed in the fork handoff notes above
are not part of upstream's published releases.
