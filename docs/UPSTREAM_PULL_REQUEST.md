# Proposed upstream pull request

## Title

Fan-control safety and correctness hardening: single controller, serialized
helper writes, safe termination, and a reviewable control law — **too large for
one review; a split is proposed below**

---

## 1. Summary and scope of the diff

**Please read this section first, because it is the one that determines whether
this is even reviewable as a single PR.**

This branch has diverged substantially from upstream. It is not a small pull
request, and I would rather say so than present it as one.

Measured against `origin/main` (`git diff --stat origin/main...HEAD`, base
`31d32bb`, the merge of upstream PR #14):

| Measure | Value |
|---|---|
| Files changed | **32** |
| Lines added | **+7,046** |
| Lines removed | **−1,308** |

Eight of those files are **new** (`git diff --diff-filter=A origin/main...HEAD`),
in four groups: `Core/FanControlLaw.swift` (457 lines, the extracted control
law), `ViewModels/FanStores.swift` (273 lines), the `tests/` tree
(`tests/run-tests.sh` plus 354 lines of checks), and the `.github/` CI assets
(`.github/workflows/ci.yml`, `.github/scripts/verify-build.sh`,
`.github/scripts/check-localization.sh`, `.github/workflows/README.md`). Two
files were **deleted**: `.github/SECURITY.md`, an unmodified GitHub template
carrying a fictional `5.1.x` version number — the real security policy is
`SECURITY.md` at the repository root — and `Views/TempMetricCard.swift`.

The largest single changes are `ViewModels/FanViewModel.swift` (+771 / −493),
`Views/RulesEngineView.swift` (+532 / −144), `Core/FanControlLaw.swift` (+458),
`App/FanControlApp.swift` (+312 / −87), `Core/SMC.swift` (+310 / −75),
`Views/TempHistoryChartView.swift` (+333 / −80), and `build.sh` (+302 / −16).

**This touches privileged-helper invocation, fan-write ordering, termination
behaviour, on-disk persistence, and packaging.** Those are five areas a
maintainer may reasonably want to review separately, and several of them are
safety-relevant enough that they deserve their own approval. I do not think the
right answer is "take it all or leave it".

It was developed and interactively tested on **two** machines, and both parts of
that are true:

- **Apple M4 Pro MacBook Pro** — Round 1/2 interactive testing: manual fan
  control, automatic rules, window resizing, background operation, history
  display, and CPU/Metal load transitions.
- **Apple M5 Max MacBook Pro (`Mac17,7`), macOS 27.2** — Round 3/4 hardware
  validation and every measurement quoted in §7. Both fans, each with a range
  of 2317–7826 RPM.

The principal changes, grouped:

- validate temperature samples and use the highest plausible CPU reading from
  the available CPU-oriented SMC keys;
- retain one-second SMC polling regardless of window visibility, and register
  the timer in `.common` run-loop mode so a UI gesture cannot suspend it;
- add adjustable asymmetric command-rate limits, cooling hysteresis, a target
  deadband, cooling confirmation, and a 90 % emergency bypass;
- add an overlaid, selectable temperature-and-fan-target history chart with a
  rolling time range, hover inspection, and grid;
- replace continuous SwiftUI fan drawing with Core Animation to reduce visible
  UI CPU usage while keeping the fan indicator proportional and monotonic;
- improve normal window behaviour, Dock presence, menu-bar reopening,
  responsive sizing, and compact notebook layouts;
- add native macOS localizations for English, French, German, Spanish, and
  Simplified Chinese, including translated runtime-generated labels;
- add an opt-in, bounded CPU/Metal thermal-load utility for local comparisons;
- run exactly one controller, and serialize all helper writes in order, so that
  writes never race and a reset cannot be overtaken by a write in flight;
- condition temperature samples so that a sustained change is accepted after
  about two seconds, instead of being frozen out, and use a monotonic clock for
  rate limiting and cooling confirmation;
- re-send the current demand after wake, and when a fan is found in automatic
  mode while a rule is in charge, at most once every 30 seconds;
- store history as an append-only JSON-lines file off the main thread, instead
  of rewriting it into UserDefaults every 30 seconds;
- show the menu-bar readout rounded to 50 RPM, without a thousands separator, in
  a slot sized for the widest reading, so the menu-bar item does not resize; and
- replace the upstream first-run **threshold** rules (CPU ≥ 75 °C → 80 %,
  battery ≥ 40 °C → 60 %) with **curves**, which start disabled.

### Rule resolution and asymmetric rates — unchanged intent, now testable

Multiple active rules are still evaluated together and the **highest** matching
target wins (`Core/FanControlLaw.swift`, `evaluate`, lines 327–388; the
aggregation loop is 334–361): a threshold rule fires when the reading is at or
above its threshold, and a curve interpolates linearly between its min/max
temperature and min/max speed. Every rule that matches contributes, and the
maximum is taken, so a more aggressive rule can never be out-voted by a gentler
one.

The cooling side is tuned rather than fast, so acoustic hunting is reduced
without delaying a thermal rise:

| Control | Default | Persisted key |
|---|---|---|
| Rise rate (command %/s) | 6 | `maximumCommandRiseRatePercentPerSecond` |
| Fall rate (command %/s) | 3 | `maximumCommandFallRatePercentPerSecond` |
| Cooling hysteresis | 5 °C | `coolingTemperatureHysteresis` |
| Target deadband | 4 % | `minimumCommandChangePercent` |
| Cooling confirmation | 8 s | `coolingConfirmationSeconds` |
| Emergency bypass | 90 % (fixed) | — |

A request of 90 % or more bypasses both the deadband and the slew-rate limiter
(`Core/FanControlLaw.swift:45–46, 166–167, 235`). The starter curves are
deliberately capped below that bypass so they never skip the limiter — those
controls are for real emergencies, not for routine warming. Defaults are at
`ViewModels/FanViewModel.swift:75–104`.

The starter curves themselves (`Models/FanJSON.swift:98–121`), **both starting
disabled, and with the rules engine itself off by default**:

| Sensor | Ramp | Ceiling |
|---|---|---|
| CPU | 20 % at 50 °C → 85 % at 90 °C | below the 90 % bypass, on purpose |
| Battery | 15 % at 35 °C → 60 % at 45 °C | — |

So nothing changes until a user turns the rules engine on, and existing users
keep whatever rules they already had saved. The curve shape is covered by tests:
CPU at 45 °C produces no demand, at 60 °C asks 36.25 %, at 75 °C asks 60.625 %,
at 90 °C reaches the 85 % ceiling, and never crosses 90 % even at 115 °C
(`tests/unit/main.swift:276–289`).

The substantive change here is not the policy; it is that the policy now lives in
one plain value type with no SwiftUI, no `Process`, and no `UserDefaults`
(`Core/FanControlLaw.swift`), so it can be compiled and exercised by
`tests/run-tests.sh` without a window server, a signature, or the helper.

---

## 2. Safety-relevant behaviour changes

These are the items a maintainer has to weigh. I have put them first because
they matter more than the feature list.

### 2.1 Fans are released to macOS on quit — but `SIGKILL` still latches them

This is the main behavioural change, and its residual limit is the main residual
risk.

`App/FanControlApp.swift` installs an `NSApplicationDelegate` whose termination
paths all funnel into one one-shot guard, `releaseFansToAutomaticControl()`
(lines 48–99):

- `applicationShouldTerminate` releases the fans *before* AppKit tears the app
  down and returns `.terminateNow`;
- `applicationWillTerminate` is the last-resort backstop;
- `SIGTERM`, `SIGINT`, and `SIGHUP` are wired to `DispatchSource` signal sources
  on the main queue (lines 87–99), because `kill`/`killall` never reach AppKit.

`FanViewModel.resetAllAndWait()` (`ViewModels/FanViewModel.swift:804–831`,
with `resetTimeout = 8 s` at 797 and `quitWaitTimeout = 12 s` at 802)
invalidates the poll timer, sets `isTerminating` so no new write can be queued,
flushes history, and then runs the helper's `reset` **synchronously** on the same
serial `writeQueue` as every other write — so the reset runs after any write
already in flight and cannot be overtaken by one. It waits at most **12 s**, and
the helper itself is stopped after **8 s** (its own reset budget is 6 s, and the
previous 5 s timeout could stop it mid-reset). A 10 s `exit(0)` backstop is
armed on the main thread, which is blocked during the wait, so it cannot fire
early; **12 s is the real ceiling**, and in the worst case quitting stalls for
about that long.

**`SIGKILL` / Force Quit is still not handled, and cannot be.** The kernel does
not deliver it, so no handler exists for it. Fan targets written to the SMC are
latched in hardware and survive process exit: if the app is killed that way, the
fans stay at the last written RPM until the app is relaunched and reset, or the
Mac is restarted. This is an OS-level limit, not something the app can work
around. It is stated here first because it is the one case where this branch's
own safety work does not help.

The app also always retains the existing **Reset All to Auto** path, in the
window and in the menu-bar menu.

### 2.2 While a rule is in charge, a user's Auto selection is overridden

If the firmware returns a fan to automatic on its own, the control law would
never notice — its demand has not changed, so it would issue no write. So while
the law believes it is in control, a fan reported in automatic mode on **two
consecutive polls** is treated as lost and the demand is re-sent
(`ViewModels/FanViewModel.swift:472–499`).

Three limits keep this from becoming a write every two seconds: it fires at most
once per **`driftReassertCooldown` (30 s)**; it does not fire after a failed
write, so a de-authorized helper or a fan that will not unlock is not retried in
a loop; and polls taken while a write is in flight are ignored, because the mode
is mid-change.

**A maintainer should weigh this explicitly as a change in how user choices are
honoured.** If a user selects Auto on a fan while the rules engine is in charge,
the app forces that fan back to manual — at most once every 30 s. The rationale
is that a rule in charge that silently loses a fan is the worse failure. The
alternative is a toggle the user has to re-assert every 30 seconds. Turning the
rules engine off stops it entirely. I am flagging it because it is the one place
in this branch where the app deliberately overrides a user selection, and that
is a product decision as much as an engineering one.

Related, and in the opposite direction: a **lost-control watchdog**. If the
helper stops answering for **five consecutive 1 Hz polls** while a rule is in
charge, the app hands the fans back to macOS Auto and says so in the window
(`pollFailureRecoveryThreshold = 5`, `ViewModels/FanViewModel.swift:125`; the
handling is `recordPollFailure()`, 511–532). It would rather lose control than
keep commanding fans it can no longer confirm. In manual-only mode there is no
reset to issue, because there is no demand to give up.

### 2.3 The setuid exposure: stated as a trade-off, not as solved

Setuid-root **plus** world-executable means any local user — or malware running
as them — can drive the fans, including to zero. **This design cannot remove
that.** Describing the current posture as "safe" or "hardened" would be
inaccurate. `SECURITY.md` says so explicitly, and I am not going to soften it
here.

What bounds it today:

- the helper's command surface grants **no capability that upstream's did not**.
  Upstream was `get`, `set`, `reset`; this branch adds exactly one verb,
  `setall <percent>`, which replaced N separate `set` processes for linked-fan
  changes. It drives the SMC through the same `writeFan` call sequence as `set`,
  computes each fan's target from that fan's own `F<i>Mn`/`F<i>Mx`, and `setFanSpeed`
  still performs the clamp to `F<i>Mx` — so no caller can skip it. The argument
  parsing is stricter than upstream's, not looser (`isFinite` and a `0.0...1.0`
  range check on the percentage);
- both binaries are signed with the **hardened runtime**, so **library
  validation** blocks a `DYLD_*` injection into the setuid binary;
- `checkAuthorization()` / `helperAuthorizationStatus(atPath:)`
  (`ViewModels/FanViewModel.swift:218–238`) rejects a helper that is not
  root-owned, is not setuid, is not owner-executable, is not executable by the
  invoking user, or is **writable by group or other** — the last being the one
  that matters most, because a setuid-root binary anyone can write is a direct
  root compromise.

The correct fix is an **XPC privileged helper (`SMJobBless`)** that
authenticates the connecting process by audit token, so only the signed GUI app
can obtain SMC writes. That is **accepted follow-up, not shipped**. Until it
ships, the helper should be read as root access offered to the local login
session.

---

## 3. A wrong change that shipped, and was corrected

I am including this deliberately. A proposal that only lists its successes gives
a reviewer no way to calibrate the rest of it.

**Round 2 set the helper to `chmod 4700`, tightened `checkAuthorization()` to
reject any group or other permission bits, and shipped it. It broke the app
outright**, because the reasoning was right and the conclusion was wrong.

The mechanism: the app spawns the helper **directly with `Process`, as the
logged-in user**. It never runs it through `sudo`. The helper must therefore be
executable *by that user* — that is the launch style, not a security preference.

| Mode | Outcome |
|---|---|
| `4700` | Only root can execute it. The logged-in user gets `EACCES`, `Process.run()` fails, **every thermal poll is lost**, and the app sits on "Reading SMC registers…" forever — with the helper present and perfectly correct. |
| `4750 root:wheel` | Also fails, for a different reason: an ordinary user is in group `staff`, not `wheel`. |
| **`4755`** | Works. Setuid root **and** executable by the logged-in user. **This is what ships**, in both `FanViewModel.authorize()` (line 305) and the opt-in `SETUID_HELPER=1` build path. |

The wrong justification was "Apple's own `/usr/bin/smc` is `4700`". That claim
was **factually false**. `/usr/bin/smc` is not present at all on the macOS 27.2 /
M5 Max machine these tests ran on; where it does exist it is `4755` and is
invoked *via `sudo`* — precisely because it has to be world-executable. The
error was treating a mode as a security requirement without checking how the
binary is actually launched.

**Why a maintainer should care about the corrected design, not just the mistake:**
the mode is not incidental to this helper. `4755` is a requirement imposed by the
`Process`-spawn style, and it is also a real, documented exposure for every other
tool on the system that can execute it. Anyone reviewing this branch should treat
"how is the helper invoked?" as load-bearing, not as incidental.

### A diagnostic worth having

`Foundation` surfaces an `EACCES` on `exec` as `NSCocoaErrorDomain` **Code=4,
"the file doesn't exist"** ([Apple Developer Forums thread
726994](https://developer.apple.com/forums/thread/726994)). A permissions fault
therefore reports as a *missing file*, which sends people hunting a packaging bug
that does not exist — which is exactly the confusion `4700` caused. `runHelper`
now detects that exact domain/code pair and prints an explicit hint about `ls -l`,
mode `4755`, and the fact that the helper is run directly rather than via `sudo`
(`ViewModels/FanViewModel.swift:295–296, 641–648`).

---

## 4. Correctness fixes

These are genuine bugs that were fixed, not preferences.

**The rules data-loss bug.** `loadRules()` used to read as one condition with one
fallback:

```swift
if let data = …, let decoded = try? JSONDecoder().decode(…) { … } else { starter rules }
```

That made "you have no saved rules" and "your saved rules failed to decode"
**indistinguishable** — both took the `else` branch. And because `rules` has a
`didSet` that calls `saveRules()`, substituting the starter defaults **wrote
them straight back over the user's file**. A rules file written by a newer
version, or hand-edited into an invalid shape, therefore destroyed itself on the
next launch — silently, with no error. All the user saw was their thresholds gone
and the rules engine inexplicably inert.

The fix (`ViewModels/FanViewModel.swift:876–913`) distinguishes the two cases. A
genuinely absent payload still seeds the starter rules. A **decode failure**
leaves the stored bytes **untouched on disk**, resets the display to empty under
a `suppressRuleSaving` guard (lines 863–874) so the recovery assignment cannot
itself trigger a write, **disables the rules engine** so the failure is safe —
macOS keeps driving the fans — and surfaces a localized message.

Worth naming as a *class* of bug: a `try?` inside an `if let` chain conflates
*absent* with *invalid*, and a `didSet` that persists turns a read failure into a
write. Either one alone is survivable. Together they are silent data loss.

**The polling timer was registered in `RunLoop.default`.** `Timer.scheduledTimer`
registers in `.default` mode only, and the run loop leaves that mode for the
duration of any event-tracking interaction — opening a SwiftUI `Menu` picker,
resizing the window, dragging a slider inside the `GeometryReader`/`ScrollView`
layout. A `.default`-only timer does not fire for any of it, so **automatic fan
control silently suspended for as long as the user kept interacting**. The timer
is now built directly and added with `RunLoop.main.add(timer, forMode: .common)`
(`ViewModels/FanViewModel.swift:347–366`). Thermal protection no longer depends
on window visibility: the interval is fixed at **1.0 s** regardless of whether
the app is frontmost, covered, or hidden (lines 378–385).

**The SMC `dataSize` clamp.** The kernel reports `dataSize` in `readKeyInfo` and
the code echoed it straight back, but the payload is a fixed 32-element tuple
inside a fixed-size stack struct — copying `dataSize` bytes unconditionally would
**smash the stack** for any key whose reported size exceeds the payload. Reads
and writes are now clamped against the real capacity of both the destination and
the source struct, with an error log on truncation (`Core/SMC.swift:835–851` for
reads, `858–877` for writes). The write path additionally refuses a value that
holds fewer bytes than the kernel struct needs, rather than trapping.

**The stdout/stderr split.** The app decoded only stdout, but `SMCLog` wrote
diagnostics to stdout too, so a single diagnostic line could corrupt the JSON
payload channel. Diagnostics now go to stderr (`Core/SMC.swift:140–149`,
`Helper/main.swift:28–36`), and the helper's stdout and stderr get **separate
pipes**, reported separately (`ViewModels/FanViewModel.swift:608–636, 695`).

**The bounded unlock.** The Apple Silicon unlock path used raw attempt counts —
100 retries at 50 ms, a 3 s yield, then 300 retries at 100 ms — so a single stuck
unlock could block for a long and unpredictable time. It is now bounded by a hard
wall-clock deadline (`Core/SMC.swift:527–560`) that is threaded explicitly
through every retry: `unlockFanControl` (691–730), the per-fan mode-write retry
(732–751), and `resetFanControl` (753–~805), whose comment records the specific
bug this fixed — per-fan writes could each retry for about a second past the
budget, which is how a reset overran the app's quit-time timeout. The whole
sequence — the `Ftst` unlock, the `thermalmonitord` yield, the per-fan mode
writes, and the final `Ftst` relock — shares one deadline.

Also in this category: the helper's arguments are now validated before use
(`isFinite` plus a `0.0...1.0` range check on the `setall` percentage, and
explicit parsing and range checks on the `set` fan id and speed),
the `AppleScript` and POSIX-shell quoting helpers escape their inputs — a bundle
path containing a single quote previously broke the authorize command — and the
authorize step **re-reads the file's ownership and mode afterwards** instead of
trusting that the shell command succeeded.

---

## 5. Localization

**99 keys across `en`, `fr`, `de`, `es`, and `zh-Hans`.** Parity is enforced by
`.github/scripts/check-localization.sh`, which runs in CI.

Precise statement of what parity proves, because it is easy to over-claim: the
check compares languages **to each other**, never against the literals actually
used in source. It therefore proves **parity, not coverage** — it cannot detect
a key that SwiftUI uses and no `.strings` file declares.

```
Localization key parity (baseline: en, 99 keys)
  LANGUAGE      KEYS
  de              99
  en              99
  es              99
  fr              99
  zh-Hans         99

  PASS  de matches en
  PASS  es matches en
  PASS  fr matches en
  PASS  zh-Hans matches en

OK: all 5 languages share the same 99 key set.
```

**English and French** are the only variants manually verified in the running
app. German, Spanish, and Simplified Chinese have **not** been reviewed by
native speakers and have **not** been exercised end to end in the running app.
They should not be presented as release-ready, and this proposal does not.

---

## 6. Tests and CI

`tests/run-tests.sh` compiles `tests/unit/main.swift` together with the shared
sources and runs **44 executable checks**, grouped as: temperature conditioning,
monotonic time and the slew limiter, re-asserting a command, the history store,
publishing only on value change, the starter rules, the menu-bar width, and
localized counts.

There is **no XCTest target**. The checks need **no window server, no code
signature, and no helper binary**, which is what makes them cheap enough to run
before every change to the control law or the stores. `44/44 checks passed` on
the current tree.

CI is `.github/workflows/ci.yml`, two jobs, both **check-only and read-only**
(`permissions: contents: read`):

- `build` — a `macos-14` / `macos-15` matrix that builds the universal bundle
  ad-hoc signed and then asserts signature, architectures, deployment target,
  optimization, binary size, icon, `Info.plist`, and bundled localizations via
  `.github/scripts/verify-build.sh`;
- `localization` — a fast parity check on `ubuntu-latest` via
  `.github/scripts/check-localization.sh`.

**The 44 unit checks in `tests/` are not wired into CI.** That is a real gap and
I am not going to describe it otherwise: adding them as a third job is a
separate, unstarted change. Run them locally with `tests/run-tests.sh`.

---

## 7. Validation actually performed

All figures below are from the **Apple M5 Max / macOS 27.2** machine, except
where the M4 Pro is named.

### Static and build gates

| Gate | Result |
|---|---|
| App typecheck | **0 errors, 0 warnings** at `arm64@13.0`, `x86_64@13.0`, `arm64@15.0` |
| Helper typecheck | **0 errors, 0 warnings** at `arm64@13.0` |
| Universal build | `x86_64 arm64`, `minos 13.0` on both binaries |
| Signature | `codesign --verify --deep --strict` → **PASS** (ad-hoc `-`) |
| `verify-build.sh` | **10/10 build checks passed** |
| `check-localization.sh` | **PASS**, exit 0 — 99 keys × 5 languages in parity |
| `tests/run-tests.sh` | **44/44 checks passed** |
| `build.sh` syntax | `bash -n` OK |

### Hardware, on the M5 Max

| Check | Result |
|---|---|
| Helper read path | Valid JSON on stdout, **0 bytes on stderr** — the split holds |
| Manual control accuracy | Commanded **3000 RPM → actual 3002**; commanded **6500 → actual 6499** |
| `setall` arithmetic | Exact: `0.45` → 4796, `0.40` → 4520, `0.20` → 3418, each against that fan's own 2317–7826 range |
| Rules engine, end to end | Rule `CPU ≥ 55 °C → 45 %` at a live CPU of **65.8 °C** produced `setall 45.00 %`; both fans landed on target **4796 RPM** — the helper's own `min + (max − min) × 0.45` = 4796.05 truncated to an integer, i.e. 45.00 % of the 2317–7826 range to two decimals (2479/5509 = 44.9991 %) — then correctly stopped issuing redundant writes |
| `reset` | All fans return to macOS automatic control (**mode 0**); macOS resumes managing them |
| Quit safety | Fans app-controlled at 4796 RPM → `SIGTERM` → process exits → fans return to **mode 0 AUTO** |
| Rules decode failure | Planted an invalid rule → engine disabled, original bytes survived on disk, fans untouched |
| Chart + menu-bar readout | Verified **in the installed build** via screen capture; UI matched hardware exactly (Fan 0: UI 3420 / hardware 3420; Fan 1: UI 3692 / hardware 3693) |
| App does not self-force fans | 12 samples with no interaction: targets tracked thermal demand smoothly (3500 → 3470) |
| Polling cadence | **1 Hz** |
| App cost at rest | ≈ 0.4–0.8 % CPU, ≈ 127–143 MB RSS |

On the **M4 Pro**, interactive testing covered manual fan control, automatic
rules, window resizing, background operation, history display, and CPU/Metal load
transitions. No hardware measurement is quoted from that machine.

One methodology note, because it invalidated an earlier round of observations:
stale duplicate app processes from earlier ad-hoc terminal launches were found
running old code, which produced misleading results (old rules, stale fan modes,
racing logs). Kill every instance and confirm zero before drawing a conclusion.
This is **not** the same as the Round 4 finding of two `FanViewModel` instances
in one process, whose cause remains unconfirmed.

---

## 8. Not verified

Stated plainly, because a maintainer should not have to discover these.

- **`SIGKILL` / Force Quit still latches the fans.** No process can catch it. The
  catchable signals are handled.
- **The Intel path.** `x86_64` compiles cleanly and the universal build
  succeeds, but it has **never been run**. No Intel Mac was used.
- **Notarization / stapling.** `NOTARY_PROFILE` is opt-in and has **never been
  exercised**. The tested build is **ad-hoc signed** (`-`), not Developer ID
  signed, and would be rejected by Gatekeeper on another Mac.
- **Linked-fan toggling through the real UI.** The projection logic and the
  single-`setall` path are verified by code reading and by direct `setall`
  execution; the toggle itself was not clicked through.
- **Non-English in-app rendering**, beyond the English and French runs noted
  above.
- **Native-speaker translation review** for `de`, `es`, and `zh-Hans`.
- **A VoiceOver pass.** Never performed.
- **Migration from a real pre-Round-4 UserDefaults history.** Unit test only.
- **The cause of Round 4's second in-process `FanViewModel`.** The
  single-instance fix is verified by the count; why there were two is not.
- **The drift re-send under a live rule**, and **the menu-bar width across the
  full fan range**, in the running app.
- **The starter curves under load** in the installed build.
- **Moving chart animation** in the installed build.

---

## 9. Suggested PR split and review guidance

**This should not go up as one PR.** My recommendation, in dependency order:

1. **Sensor conditioning and control-law extraction** — `Core/FanControlLaw.swift`,
   the `TemperatureConditioner`, the monotonic clock, the `.common` polling
   registration, and `tests/`. Pure extraction plus a test harness; no behaviour
   change intended. This is the smallest, safest, and most reviewable unit, and
   everything after it is easier to review once the law is a value type.
2. **Helper invocation and write ordering** — `Helper/main.swift` (`setall`,
   argument validation), the single serial `writeQueue`, the one-shot
   `FanViewModel.shared`, the wake and drift re-sends, the lost-control
   watchdog, and the SMC `dataSize` clamp. **This is the safety-critical one**
   and wants its own review and its own approval.
3. **Termination and quit ordering** — `App/FanControlApp.swift`,
   `resetAllAndWait()`, the signal sources, the bounded waits. Small, but it
   changes what happens on every quit, so it should not be buried in a
   6,000-line diff.
4. **The `4700` → `4755` correction and the security posture** —
   `ViewModels/FanViewModel.swift` (`authorize()`,
   `helperAuthorizationStatus`), the `EACCES` hint, `SECURITY.md`. Put it in its
   own PR so the mode change and its documented exposure are impossible to miss.
   The `SMJobBless` migration is **not** in this branch and should be discussed
   as a separate architectural change, not bundled here.
5. **Persistence and state** — `ViewModels/FanStores.swift`, the append-only
   history file, and the UserDefaults migration.
6. **UI, chart, and menu bar** — `Views/*`, `TempHistoryChartView.swift`,
   `SpinningFanView.swift`, the removed `TempMetricCard.swift`.
7. **Packaging, CI, and docs** — `build.sh`, `.github/workflows/ci.yml`, the two
   check scripts, and the documentation set.

Reviewer guidance:

- **Start with `SECURITY.md`.** If the `4755` trade-off is unacceptable to
  upstream as a matter of policy, then item 4 of the split above is the wrong
  shape and the right answer is `SMJobBless` first. That is a design
  conversation, not a review question, and it should happen before anyone reads
  a line of this.
- **Treat the seven units above as independently releasable.** If a maintainer
  wants the correctness fixes but not the UI work, that should be a valid
  outcome.
- **The control law is the part worth arguing about on the merits.** Everything
  else in PR 1–3 is plumbing around it.
- **`tests/run-tests.sh` should be wired into CI as part of PR 1.** The checks
  exist and pass; only the job is missing. Leaving that out of a PR that
  introduces a control law would be a regression in practice.
- **Please do not treat the Round 2 `4700` mistake as a reason to distrust the
  rest.** It is in §3 because it is load-bearing for the corrected design and
  because I would rather you could calibrate against it.

---

## 10. Per-round record

`docs/FORK_CHANGELOG.md` contains the detailed behavioural record, persisted
setting names, measurement bounds, known limitations, and the follow-up list. It
is **newest-round-first** and deliberately preserves earlier rounds **verbatim,
including claims that later rounds corrected**, with inline **Correction
(Round N)** notes. The wrong text stays in place on purpose: deleting it would
hide the sequence, and the §3 mistake above is only useful to a reviewer because
the reasoning that produced it is still legible.

That file also records the round-by-round corrections, including the `4700` →
`4755` correction, the false `/usr/bin/smc` claim, the data-loss bug, and the
superseded "not validated" items that hardware testing later retired.

Thank you for considering this. I would rather split it into the seven units
above than have you take 32 files in one pass, and I am happy to reshape any of
them to match the project's preferred design and review boundaries.