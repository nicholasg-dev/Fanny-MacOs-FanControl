# Fork Change Record and Upstream Handoff Notes

This document is a running record in four parts:

1. **Round 4 — 2026-10-13** (everything from the next heading down to the Round 3
   heading): one shared controller instead of two, serialized helper writes and
   quit ordering, sensor conditioning, a monotonic clock, wake and drift
   re-sends, a split of the window's state, history stored as a file, and the
   menu-bar readout. It also corrects several Round 2 and Round 3 claims, marked
   inline.
2. **Round 3 — 2026-10-13** (everything from the Round 3 heading down to the Round 2
   heading): hardware validation on an Apple M5 Max / macOS 27.2, plus the
   correction of Round 2's `chmod 4700` decision, which shipped broken.
3. **Round 2 — 2026-10-13** (everything from the Round 2 heading down to the
   Round 1 divider): the earlier, larger round of work. Safety-relevant fixes,
   correctness fixes, build/packaging, and CI.
4. **Round 1** (everything below the divider): the original contribution
   described in the [`feature/asymmetric-fan-response`](https://github.com/ShahzaibAli02/Fanny-MacOs-FanControl/tree/feature/asymmetric-fan-response)
   work after upstream base commit `60a57f3`. It is kept **verbatim** as the
   historical record and is not retro-fitted. Where Round 1's claims are now
   stale, Round 2 says so explicitly; the original text is left alone so the
   difference between what was true then and what is true now stays visible.

Rounds 1, 2 and 3 are preserved rather than rewritten, including the parts of
Round 2 that Round 3 **corrects**, and the parts of Rounds 2 and 3 that Round 4
corrects. Where a round's reasoning no longer holds, the wrong text stays in
place and carries a short inline **Correction (Round 3)** or **Correction
(Round 4)** note pointing at the current position. Deleting the mistake would hide it;
the point of this record is that the sequence of beliefs is auditable, including
the one that was confidently argued and wrong.

Round 1 was merged upstream as pull request #13; a later activation-policy change
landed as #14, so the branch named in Round 1 is no longer where this work lives.

---

## Round 4 — 2026-10-13: single controller, write ordering, and the menu bar

### Scope

Round 4 implements the findings of a review of stability and performance on the
Apple M5 Max / macOS 27.2 machine, and the follow-up changes to the menu bar and
the default rules. Behaviour changes are listed below, so a reader can see what a
user will notice. Two things are measured on the working tree rather than on a
release: the app and helper binaries were built locally, ad-hoc signed.

### What changed

- **One controller, not two.** `FanViewModel` was created twice. Both instances
  polled the helper and ran the automatic rules. `heap` on the unchanged build
  showed two `FanViewModel`, two `FanHistoryStore`, and two `FanTelemetry`. The
  view model is now `FanViewModel.shared`, with a private initializer, and the
  installed copy shows one of each. The cause of the second instance is not
  confirmed. The old build's log had no SwiftUI `StateObject` warning, so the
  explanation is unverified, but the single-instance fix is verified by the
  count.
- **Helper writes run one at a time, in order.** `set`, `setall` and `reset` all
  run on one serial queue. Before, they ran on a concurrent queue, so two could
  race on the shared `Ftst` unlock key. Linked-fan changes now send one `setall`
  with the initiating fan's fraction, which applies the same formula the old
  per-fan loop used, rather than one `set` per fan. Writes requested after
  quitting begins are dropped.
- **Quit ordering.** The quit-time reset joins the write queue behind any write
  already in flight. The app waits at most 12 seconds for it, and the helper
  itself is stopped after 8 seconds, which leaves room for its 6-second budget.
  Inside the helper, the per-fan automatic-mode writes now share the reset's
  deadline, so a reset is bounded as a whole.
- **Bounded stop for a stuck helper.** A helper that outlives its timeout is sent
  SIGTERM, then SIGKILL, with each wait bounded. The poll no longer blocks on
  `waitUntilExit()`, which could stop polling for good.
- **Sensor conditioning.** `TemperatureConditioner` replaces the function that
  froze a reading (see the correction below). An out-of-range or missing sample
  is ignored and the last accepted value is held. A step within the cap is
  accepted at once. A step beyond the cap is accepted after three agreeing
  samples, about two seconds at the 1 Hz poll.
- **Monotonic clock.** The slew limiter and cooling confirmation measure elapsed
  time on `ContinuousClock`, which keeps counting through sleep and ignores wall
  clock changes.
- **Wake and drift.** A system wake makes the law re-send its current demand. A
  fan found in automatic mode while a rule is in charge, on two polls in a row,
  has the demand re-sent. The re-send happens at most once every 30 seconds, and
  not after a failed write. See the behaviour change below.
- **Published state split.** `FanViewModel` no longer publishes live readings.
  `FanTelemetry` holds the fan list and the battery temperature, `MenuBarStatus`
  the menu-bar readout, and `FanHistoryStore` the history. Values publish only
  when they change, and the window observes only what it shows. Fan cards observe
  telemetry on their own. Before this round, every poll re-rendered the window.
- **History storage.** The history is an append-only JSON-lines file at
  `~/Library/Application Support/<bundle id>/temperature-history.jsonl`. Each
  sample adds one line, about 150 bytes. While the app runs, the file is rewritten
  only when expired records need removing, at most once an hour. At launch it is
  also rewritten if it holds expired or undecodable lines. All disk work runs on a
  background queue. The old design rewrote about 420 KB into UserDefaults every
  30 seconds, on the main thread. The old UserDefaults key is removed once the new
  file is written. Records that do not decode, for example one cut short by a
  crash, are skipped.
- **Menu-bar readout.** The first fan's speed is rounded to the nearest 50 RPM,
  so the readout changes less often. It has no thousands separator. Digits are
  proportional in the menu-bar font, so the readout's width changed with its
  value. The readout now sits in a slot as wide as the widest four-digit value,
  reserved with hidden text. `L10n.formatCount` formats whole counts, and
  `L10n.format` is kept for decimals.
- **Chart and spinner.** The chart refreshes every five seconds, through
  `TempHistoryChartContainer`, so its rolling window keeps moving. The fan spinner
  reconfigures its rotation only when the rate changes by more than 5%, instead
  of restarting on every RPM jitter.
- **Starter rules (fresh installs only).** The first-run rules are curves rather
  than single steps. The CPU rule ramps from 20% at 50 °C to 85% at 90 °C. The
  battery rule ramps from 15% at 35 °C to 60% at 45 °C. Both start disabled, and
  so does the rules engine. The CPU ceiling is 85%, below the 90% emergency
  bypass, so the starter curve never skips the deadband or the slew limit.
  Existing users keep their saved rules.
- **Tests.** `tests/run-tests.sh` compiles `tests/unit/` with the control law,
  the stores, the models and the localization helper, and runs them. It is not
  run by CI yet. The suite went from 13 checks, to 30, 38, 39, 41, and finally
  44, with each batch written before the code it covers.
- **Comments corrected.** `Helper/main.swift` called fork-per-poll "the dominant
  cost". Measured on this machine, one `get` costs about 4 ms of CPU, which is
  under 0.5% of a core at 1 Hz. The comment now says so.

### Measurements

Measured on the M5 Max, macOS 27.2, against unauthorized copies of the app.
The copies were made so that a second app would not share the installed app's
preferences. The first comparison ran before the single-controller fix, and both
copies had two controllers, so the comparison is fair but not the authorized
state.

| Measurement | Before | After |
|---|---|---|
| App CPU, window visible (30 s) | 2.46% | 0.76% |
| App CPU, window hidden (30 s) | 3.13% | 0.83% |
| Hidden sample: status-item frames | 97 | 17 |
| Hidden sample: layout frames (`_layoutSubtreeWithOldSize`) | 63 | 29 |
| Hidden sample: `ContentView.body` | 12 | 0 |
| Live controllers (`heap`) | 2 | 1 |
| History cadence (3 records) | two writers, 1 s apart | 30.1 s, 30.1 s |
| SIGTERM to exit, unauthorized copy | not measured | about 1 s |
| Menu-bar item width, same value (4,500 RPM) | 108 pt | 105 pt |

The menu-bar width was sampled on the copy at 4,500 RPM and then 2,300 RPM,
with width 105 pt both times. The installed build measured 108 pt at both values.
The sample is short, and it does not cover the whole fan range.

The menu-bar font measurement, with `NSFont.menuBarFont`, shows digit proportions
across 2,300–7,850 RPM: a 3.5 pt spread with proportional digits and 0.0 pt with
tabular digits. The font measurement shows why the width changed. Whether the
status item honours `.monospacedDigit()` was not checked, so the slot is used,
and it does not depend on that. The width samples above are the only evidence of
how the status item renders the readout.

### Corrections to earlier rounds

- **Correction (Round 4), Round 2 quit backstop.** The "10-second `exit(0)`
  backstop" cannot fire during the quit-time reset. `resetAllAndWait()` blocks the
  main thread, and the backstop is scheduled on it. The real ceiling is the
  12-second wait. A reset that has not finished by then is abandoned, and the app
  quits, so logout or quit can stall for up to about 12 seconds. Round 4 also
  puts the reset on the write queue, so it runs after any write already in flight.
- **Correction (Round 4), Round 2 bounded retries.** The deadline covered the
  unlock path and the reset's `Ftst` writes, but not each fan's automatic-mode
  writes inside the reset. Those retried for about a second per fan beyond the
  budget. They now share the reset's deadline.
- **Correction (Round 4), sensor validation.** A step larger than the cap was
  rejected on every sample, and the rejected value never became the reference.
  So a sustained change larger than the cap was never accepted, and the reading
  stayed frozen. It was the wrong direction for a thermal input, and the freeze
  could persist while the chip was hot. `TemperatureConditioner` accepts such a
  change after three agreeing samples. The sentence "an invalid sample keeps the
  previous live value" is still true, for samples that are out of range or
  missing.
- **Correction (Round 4), starter rules.** The first-run rules described earlier
  as CPU ≥ 75 °C → 80% and battery ≥ 40 °C → 60% were single steps. They are now
  the curves listed above, and they apply only when no rules are saved. The
  rules-durability snippet in the Round 3 section shows the old fallback, and
  `loadRules()` in `ViewModels/FanViewModel.swift` is the current location
  (the earlier line range is out of date).
- **Correction (Round 4), the helper's cost comment.** The "dominant cost" note is
  not supported by the measurements above.

### Behaviour changes

These are the changes a user can see. Everything else is internal.

- The menu-bar readout is rounded to 50 RPM and has no thousands separator.
- A sustained temperature change larger than the cap is shown and used after
  about two seconds, where before it was never accepted.
- **If a fan is set to Auto while a rule is in charge, the app forces it back to
  manual, at most once every 30 seconds.** The rule stays in charge, so the fan
  will be driven again. This is deliberate, because the law would otherwise never
  notice the change. It is a change in what the app does with a user's
  choice. To turn the behaviour off, disable the rules engine.
- The starter rules are different on a fresh install. Saved rules are not changed.
- History is stored in a file, and the old UserDefaults copy is moved over once.
  If you return to an older build, the history is not restored.
- The history chart updates every five seconds, not once a second.
- Replacing the app drops the helper's authorization, so the app must be
  authorized again.

### Validation

- Unit checks: 44 of 44 pass, from `tests/run-tests.sh`.
- Type-check of the app and helper, for `arm64` and `x86_64`, with
  `-swift-version 5` and deployment target 13.0: passes.
- Universal build via `build.sh` (ad-hoc): no compiler warnings. The only
  warning is the packaging step's `hdiutil` deprecation notice, which existed
  before this round.
- `verify-build.sh`: pass (signature, both architectures, minos 13.0,
  optimization, icon, five localizations).
- `check-localization.sh`: pass, 99 keys in all five languages.
- Installed build: after authorization, the helper is `root:wheel`, mode `4755`,
  and both fans read back in automatic mode with rules off.

### Not verified

- The drift re-send under a live rule. The gating logic has no unit test, because
  it lives in the view model.
- The menu-bar width across the whole fan range, on the installed build.
- The moving chart, and the menu-bar readout, in the installed build. A screen
  capture was not reliable enough to use.
- The starter curves under real load.
- Linked-fan changes, the quit ordering, and the helper's timeouts, with writes
  to real fans. These were checked by reading the code and by compiling, not by
  running writes, so that no fan was touched during testing.
- The Intel path, which compiles but has not been run.
- Migration from a real pre-Round-4 UserDefaults history. Migration is covered by
  a unit test only.
- The cause of the second `FanViewModel` instance.

### Known limitations after Round 4

- The unit checks are not in CI.
- The setuid exposure in the Round 2 and Round 3 sections is unchanged. A later
  round would have to address it with an XPC helper.
- The response-tuning defaults and the add-rule default (CPU ≥ 60 °C → 50%,
  enabled) are unchanged. They are the next candidates for the cooling-behaviour
  question.

---

## Round 3 — 2026-10-13: hardware validation, and a correction that mattered

### Scope and standing

Round 3 exists because Round 2 shipped a **security-motivated change that broke
the app**, and because the fix for a real data-loss bug landed alongside it.
Unlike Round 2, this round is **hardware-validated**: the results below were
measured on an **Apple M5 Max MacBook Pro running macOS 27.2**. Round 2's claim
that it was "not hardware-validated" is now historical, not current.

### Correction: the helper is `4755`, and `4700` broke thermal polling

Round 2 changed `authorize()` to `chmod 4700` and tightened
`checkAuthorization()` to reject any mode carrying group or other permission
bits, on the reasoning that a world-executable setuid-root helper lets any local
user drive the fans. **That reasoning was correct and the conclusion was
wrong.** The mode broke the app outright.

The mechanism: the app spawns the helper **directly with `Process`, as the
logged-in user**. It never runs it through `sudo`. So the helper must be
executable *by that user* — that is not a preference, it is the launch style.

| Mode | Outcome on this hardware |
|---|---|
| `4700` | Only root can execute it. The logged-in user gets `EACCES`, `Process.run()` fails, **every thermal poll is lost**, and the app sits on "Reading SMC registers…" indefinitely while the helper is present and perfectly correct. |
| `4750 root:wheel` | Also fails: an ordinary user is in group `staff`, not `wheel`. |
| **`4755`** | Works. Setuid root **and** executable by the logged-in user. **This is what ships now.** |

Confirmed on the installed artifact:
`/Applications/Fan Control.app/Contents/MacOS/smc-helper` → `-rwsr-xr-x root wheel`.

Code evidence:

- `ViewModels/FanViewModel.swift:217–234` — the `chmod 4755` shell command, with
  the reasoning in a comment at the point of decision.
- `ViewModels/FanViewModel.swift:137–167` — `helperAuthorizationStatus(atPath:)`:
  root-owned, setuid, owner-executable, **user-executable (required)**, and
  **not group/other-writable**. Group/other *execute* is explicitly required now,
  not a defect; the check that matters is *writability*.
- `build.sh:352–397` — the opt-in `SETUID_HELPER=1` path, `chmod 4755`, which
  verifies the same predicate and warns rather than shipping something the app
  will reject.

The claim that "Apple's own `/usr/bin/smc` is `4700`" was **factually wrong**
and has been removed from `README.md` and `SECURITY.md`. `/usr/bin/smc` is not
present at all on the macOS 27.2 / M5 Max machine these tests ran on. Where it
does exist it is `4755` and is invoked *via `sudo`* — precisely because it has to
be world-executable. The error was treating a mode as a security requirement
without checking how the binary is actually launched.

### The trade-off, stated honestly rather than resolved

Setuid-root **plus** world-executable **is** a real exposure: any local user, or
any malware running as that user, can drive the fans through
`smc-helper set <id> 1 <rpm>`, including to zero. **This design cannot eliminate
it.** What bounds it today:

- the helper's command surface is minimal and unchanged — `get`, `set`, `reset`;
- both binaries are signed with the **hardened runtime**, so **library
  validation** blocks a `DYLD_*` injection into the setuid binary;
- `checkAuthorization()` rejects a helper that is not root-owned, not setuid, not
  executable, or **writable by group or other** — the last being what would
  otherwise let an unprivileged user replace the binary that runs as root.

The correct fix is an **XPC privileged helper (`SMJobBless`)** that authenticates
the connecting process. That is **accepted follow-up, not shipped**; it is now
recorded in the follow-up list below and in [`SECURITY.md`](../SECURITY.md).
Round 2 overshot in the opposite direction: it treated a hard requirement as
optional and broke the product to avoid an exposure that was never actually
removed. The honest position is *functional and bounded, not safe*.

### A diagnostic worth having: `EACCES` reports as "file doesn't exist"

Foundation surfaces an `EACCES` on `exec` as `NSCocoaErrorDomain` **Code=4, "the
file doesn't exist"** ([Apple Developer Forums thread
726994](https://developer.apple.com/forums/thread/726994)). So a permissions
problem presents as a *missing file* and sends people hunting a packaging bug
that does not exist — which is exactly the confusion `4700` caused.

`runHelper` now detects that exact domain/code pair and prints an explicit hint
about `ls -l`, mode `4755`, and the fact that the helper is run directly rather
than via `sudo` (`ViewModels/FanViewModel.swift:534–546`).

### Correctness fix: a `try?` in an `if let` chain destroyed the user's rules

`loadRules()` read as a single condition with a single fallback:

```swift
if let data = …, let decoded = try? JSONDecoder().decode(…) { … } else { starterDefaults }
```

Any decode failure was **indistinguishable from "no saved rules"**, so it
substituted the starter defaults — and because `rules` has a `didSet` that calls
`saveRules()`, the substitution was **written straight back over the user's
file**. A rules file written by a newer version, or hand-edited into an invalid
shape, silently destroyed itself on the next launch: the user found their
thresholds gone and the engine mysteriously inert, with no error anywhere.

The two cases are now distinguished. A genuinely absent payload still seeds the
starter rules. A decode failure **leaves the stored bytes untouched**, resets the
display to empty under a `suppressRuleSaving` guard (without which that
"recovery" assignment would itself fire `didSet` and overwrite the very bytes
being preserved), **disables the rules engine** so the failure is safe — macOS
keeps driving the fans — and surfaces a localized message.
`ViewModels/FanViewModel.swift:713–766`.

> **Correction (Round 4):** the line range above is stale. `loadRules()` in
> `ViewModels/FanViewModel.swift` is now the location, and the first-run rules are
> the curves in `TriggerRule.starterRules`, not the threshold pair described
> above. See Round 4.

**Verified on hardware:** planted an invalid rule, launched, confirmed the engine
went off, the original bytes survived, and the fans were untouched.

Worth keeping as a class of bug rather than a one-off: a `try?` inside an
`if let` chain conflates *absent* with *invalid*, and a `didSet` that persists
turns a read failure into a write. Either alone is survivable; together they are
silent data loss.

### Hardware validation actually performed

Measured on an **Apple M5 Max MacBook Pro, macOS 27.2**:

| Check | Result |
|---|---|
| Helper read path | Valid JSON on stdout, **0 bytes on stderr** — confirms the Round 2 stdout/stderr split holds and a diagnostic cannot corrupt the payload channel. |
| Manual control accuracy | Commanded **3000 RPM → actual 3002**; commanded **6500 → actual 6499**. |
| `reset` | Returns all fans to macOS automatic control (**mode 0**); macOS resumes managing them. |
| Rules engine, end to end | Rule `CPU ≥ 55 °C → 45 %` at a live CPU of **65.8 °C** produced `setall 45.00 %`; both fans landed on target **4796 RPM = exactly 45.00 %** of each fan's own **2317–7826** range, then correctly stopped issuing redundant writes. |
| Quit safety | With fans app-controlled at 4796 RPM: `SIGTERM` → process exits → fans return to **mode 0 AUTO**. |
| Rules decode failure | Planted invalid rule → engine disabled, original bytes survived, fans untouched. |
| Localization parity | `bash .github/scripts/check-localization.sh` → **PASS**, 99 keys, all 5 languages in parity. (The Round 2 note that this script "currently fails" is resolved.) |

This also **retires two Round 2 "Not validated" items**: the termination reset is
now verified on real hardware, and the authorize round trip is verified at
`4755`. The `SIGKILL` limitation is unchanged and remains uncatchable.

### UX issue observed, not fixed

The window can be restored at an **off-screen origin** — observed at
**x = −1728** on a wide multi-display setup — which looks like the app failed to
open. It is a saved-window-position problem; the app is running and the menu-bar
item is live. Recorded in `README.md`'s known-limitations list rather than fixed
here.

### Documentation corrections made this round

`README.md`, `SECURITY.md`, and this file carried the `4700` claim in four places
and the `/usr/bin/smc` claim in three. All were rewritten for `4755` and its
trade-off. `README.md` gained the mode table, the exposure stated plainly, the
`EACCES`→Code-4 diagnostic note, the rules-durability explanation, and the
measured-results table. `SECURITY.md`'s threat model was restructured to lead with
the caller-authentication gap and keep the mode discussion as the constraint it
is. `docs/LOCALIZATION.md` was re-checked against the tables: **99 keys across
en/fr/de/es/zh-Hans**, all in parity, with the non-English native-speaker caveat
retained.

---


## Round 2 — 2026-10-13: hardening, correctness, and packaging

### Scope and standing

Round 2 is an unreviewed working-tree change on `main` at `31d32bb` ("Merge pull
request #14 from leornt/main"), plus uncommitted modifications. It is **not**
hardware-validated. Everything below was verified by reading the code and by
running the two check scripts in `.github/scripts/`; the only interactive testing
behind it is what a person can do with a Mac in front of them, and any claim that
needs a specific Mac's thermal behaviour is explicitly marked as unvalidated.

### Correctness fixes that were real bugs

- **Shutdown left the fans latched.** There was no termination handler at all.
  Closing the window hid it (the window delegate returns `false` from
  `windowShouldClose` and orders the window out), and ⌘Q / `killall` exited
  without touching the SMC, so whatever RPM was last written stayed latched in
  hardware. `FanControlAppDelegate` now releases the fans on
  `applicationShouldTerminate`, on `applicationWillTerminate` as a backstop, and
  from `DispatchSource` handlers for `SIGTERM`, `SIGINT` and `SIGHUP`. The reset
  is **synchronous** (`resetAllAndWait()`), because an async dispatch to a
  background queue is simply cancelled by process exit, which is the original bug
  in a different costume. The poll timer is invalidated first so a timer firing
  around the reset cannot re-apply a speed, the release is one-shot per process,
  and a 10-second `exit(0)` backstop means a wedged helper cannot turn "quit"
  into a hang. **`SIGKILL` (Force Quit, `kill -9`) cannot be caught by any
  process** and still leaves the fans latched; that is an OS limit and is
  documented as a known limitation rather than papered over.

  > **Correction (Round 4):** the 10-second backstop cannot fire during the
  > quit-time reset. The backstop is scheduled on the main thread, and
  > `resetAllAndWait()` blocks it. The real bound is the 12-second wait, after
  > which the app quits even if the reset has not finished. See Round 4.
- **Thermal protection silently stopped during UI interaction.** The 1 Hz poll
  timer was registered with `Timer.scheduledTimer`, i.e. in run-loop `.default`
  mode only. The run loop leaves `.default` for the whole duration of any
  event-tracking interaction — opening a SwiftUI `Menu` picker, resizing the
  window, dragging a slider inside the `GeometryReader`/`ScrollView` layout — and
  a `.default`-only timer does not fire during any of it. Automatic fan control
  suspended itself for exactly as long as the user was touching the UI. The timer
  is now registered in `RunLoop.main` **`.common`** modes.
- **`linkedFans` applied the wrong number.** The linked path took the initiating
  slider's **raw RPM** and clamped it into every other fan's range. Fans rarely
  share a span: with fan A at 1200–5000 and fan B at 1800–6200, asking A for 50%
  (3100 RPM) gave B 29.5%. It now projects the initiating fan's normalized
  position into each target fan's own range, which is what the preset path
  already did. This is Round 1's "linked manual slider semantics need review"
  limitation, now landed.
- **Unbounded SMC retry loops.** The Apple-silicon unlock path used raw attempt
  counts (100 writes at 50 ms, a 3 s thermalmonitord yield, then 300 writes at
  100 ms), so a single stuck unlock blocked for **~38 s** and a reset for ~11 s —
  inside the setuid helper, which the app waits on synchronously, so that is a
  frozen UI and a stalled poll. Retries are now bounded by a wall-clock `Deadline`
  (`FANCONTROL_UNLOCK_BUDGET_SECONDS`, default **8 s**; `FANCONTROL_RESET_BUDGET_SECONDS`,
  default **6 s**). The *sequence* of operations and the keys involved are
  unchanged, so the success path does the same work in the same order; only the
  failure path is bounded.

  > **Correction (Round 4):** the deadline did not reach each fan's automatic-mode
  > writes inside the reset, which could still retry for about a second per fan
  > beyond the budget. Those writes now share the reset's deadline. See Round 4.
- **Stack overflow on a hostile `dataSize`.** `SMCKeyData_t.bytes` is a fixed
  32-element tuple at the end of a stack struct, and `read()`/`write()` echoed the
  kernel-reported `dataSize` straight into a `memcpy`/struct assignment. Any key
  reporting more than 32 bytes would read or write adjacent stack memory. Both
  paths now clamp against the real payload capacity and log a truncation instead
  of trusting the kernel.
- **Diagnostics corrupted the JSON channel.** The helper prints its telemetry
  document to stdout and the app decodes stdout directly. SMC diagnostics went to
  stdout too. All SMC logging now goes to **stderr**, and the helper suppresses it
  for the `get` command unless `SMC_HELPER_VERBOSE=1` is set, so a failed read can
  never interleave with the payload.
- **A wedged helper could stop polling permanently.** One status read held
  `isStatusUpdateInProgress` forever if the child never exited. Polls now have a
  **5-second** upper bound; a hung child is terminated and counted as a failed
  sample rather than silencing the poll loop for the rest of the session.

### New behaviour worth knowing about

- **Lost-control watchdog.** Five consecutive failed polls (about five seconds at
  the 1 Hz rate) while the control law believes it is commanding the fans causes
  the app to relinquish control, issue a reset, and surface the reason in the
  window. It only fires when a rule is actually applied — in manual-only mode
  there is nothing to reset — and re-arms so a later outage can trigger it again.
  A later successful poll clears the message. The invariant it protects is worth
  stating plainly: *if you cannot confirm you are in control, stop commanding.*
- **Authorization is verified, not assumed.** `checkAuthorization()` now requires
  root ownership **and** the setuid bit **and** owner-execute **and** no group or
  other access bits, and `authorize()` re-reads the mode after running rather than
  trusting that the shell succeeded. See the `4700` discussion below.

  > **Correction (Round 3):** the *no group or other access bits* clause was the
  > bug, not the fix. The helper must be executable by the logged-in user
  > because the app spawns it directly with `Process` and never via `sudo`, so
  > user-execute is now **required**; what the check still forbids is
  > group/other **writability**. The `authorize()` round trip stands. See Round 3.
- **Rule slider bounds are enforced.** `RuleBounds` normalizes every stored rule:
  each end of a paired range is derived from the other and clamped, so a
  hand-edited or truncated rules file cannot produce a degenerate `30...30` slider
  range.
- **Chart work is bookkeeping, not rendering.** The history view replaces string
  identities with a hashed `ChartPointID` (building those strings dominated every
  `body` evaluation), binary-searches the history for the rolling window and for
  hover lookups instead of scanning, and caches its two `DateFormatter` templates.
  The plotted geometry is unchanged from Round 1: **240 points high** in the
  regular layout, **160** in the compact layout.

### Security-relevant change: `chmod 4700`, not `chmod +s`

> **Correction (Round 3) — this section is superseded. Read it as a record of a
> mistake, not as the current design.** The exposure described here is real; the
> fix chosen here was wrong and **broke the app**. The mode is `4755`, not
> `4700`, because the app launches the helper directly with `Process` as the
> logged-in user and never through `sudo`, so at `4700` the user cannot execute
> it, `Process.run()` fails, and every thermal poll is lost. The claim below that
> "Apple's own `/usr/bin/smc` is `4700`" is **false** — `/usr/bin/smc` is not
> present on the macOS 27.2 / M5 Max machine these tests ran on, and where it
> does exist it is `4755` and invoked via `sudo`. The exposure itself was never
> removed and is still live; the accepted fix is an XPC privileged helper
> (`SMJobBless`). See Round 3 above. The original text follows unchanged.

Round 1's documented install step was `sudo chmod +s` on the helper. The shipped
file is `0755`, so `+s` produces **`4755`: setuid root *and* world-executable**.
The helper does no caller authentication — it accepts `set <fanId> 1 <rpm>` from
any process that can execute it — so a `4755` helper lets any local user, or any
malware running as that user, drive the fans to zero or pin them at full speed.
That is a local privilege-escalation-grade exposure, not a hardening gap.

It is now `chmod 4700` in `authorize()`, and `checkAuthorization()` rejects any
mode carrying group or other bits, so a manually `chmod +s`'d helper is reported
as unauthorized rather than silently accepted. Apple's own `/usr/bin/smc` is
`4700`. The full threat model is in [`SECURITY.md`](../SECURITY.md).

### Packaging

`build.sh` was substantially rewritten. What was actually broken:

- **It shipped `-Onone`.** `swiftc` defaults to no optimization when no `-O` flag
  is passed, so every release was an unoptimized build. It now passes
  `-O -whole-module-optimization`, and `verify-build.sh` fails the build if the
  optimization flag disappears again (its regex deliberately excludes `-Onone`).
- **It shipped no icon.** It copied `app_icon.png` in as `AppIcon.png` while
  `CFBundleIconFile` was `AppIcon`; the Finder and Dock read that as an `.icns`
  and do not fall back to a PNG resource, so users got the generic application
  icon. The build now generates a real `AppIcon.iconset` with `sips` and compiles
  it with `iconutil`.
- Version strings are single-sourced through `APP_VERSION` / `BUILD_NUMBER` and
  feed both `Info.plist` and the DMG volume name, which could not drift apart.
  **Not yet done:** `Views/ContentView.swift` still renders a hardcoded
  `Text("v2.0")` in the window header, so the on-screen version can disagree with
  `CFBundleShortVersionString`. Known, and marked in `build.sh` itself.
- The build writes a minimal entitlements plist and passes it to `codesign`. The
  only entitlement is `com.apple.security.get-task-allow = false`. There is
  deliberately **no** app-sandbox entitlement: the app launches a setuid helper
  from inside its own bundle, and a sandbox claim the OS would enforce by breaking
  the app would be worse than its absence.
- Notarization is **opt-in** via `NOTARY_PROFILE` and is **untested**. No
  submission has been made from this machine, so the path has not been proven to
  work; a hardened-runtime + setuid binary needs notarization to run anywhere but
  the build machine, and that remains the publisher's job.
- `SETUID_HELPER=1` applies the setuid bit after signing. It is off by default, and
  it is a convenience for a bundle installed without being rewritten: copying the
  app out of a DMG into `/Applications` loses root ownership, so the bit does not
  survive installation and the in-app authorize step is still required.
- Every knob is now an environment variable: `MACOS_DEPLOYMENT_TARGET`, `ARCHS`,
  `SIGNING_IDENTITY`, `BUILD_DIR`, `APP_VERSION`, `BUILD_NUMBER`, `NOTARY_PROFILE`,
  `SETUID_HELPER`. The `hdiutil` → ZIP fallback is unchanged.

### Refactoring

- `Core/FanControlLaw.swift` is new: the control law extracted into a plain value
  type with no SwiftUI, no `ObservableObject`, no `Process` and no `UserDefaults`.
  It holds sensor validation, rule aggregation, the deadband, the slew-rate
  limiter, cooling hysteresis, cooling confirmation, and the linked-fan
  projection. `FanViewModel` is now a thin adapter around it. This is a
  readability change; it does not alter the shipping defaults, which are unchanged
  from Round 1 (6%/s rise, 3%/s fall, 5 °C hysteresis, 4% deadband, 8 s
  confirmation, 90% bypass).
  *Still not done, and still worth doing:* nothing compiles this law in a test
  harness. The file is written so that one can (`Core/FanControlLaw.swift` plus
  `Models/` is self-contained), but no such harness exists in the tree, so
  "testable without a window server" is a design property that has not been
  exercised.
- `Views/TempMetricCard.swift` was deleted as dead code (zero references).
- macOS 13 remains the deployment target. The macOS 14 spellings (`tint`,
  two-parameter `onChange`, `.toggleStyle(.switch)`) are behind small
  `#available` shims, and `.cornerRadius` was replaced with
  `.clipShape(.rect(cornerRadius:))`, which has existed since macOS 12.
  **Recommendation, not a change:** raising the floor to macOS 14 would delete
  those shims outright. It is a deliberate product decision (13.0 is the
  deployment target of the Round 1 build and of the CI matrix), so it is not made
  unilaterally here.

### CI

`.github/workflows/ci.yml` adds two check-only jobs with `contents: read`:

- `build` on a `macos-14`/`macos-15` matrix: build ad-hoc with the same
  `ARCHS`/`MACOS_DEPLOYMENT_TARGET` the script reads, then
  `.github/scripts/verify-build.sh` asserts signature, universal architectures,
  deployment target, that an optimization flag is present, a real `AppIcon.icns`,
  and that all five `.lproj` folders landed in the bundle.
- `localization` on `ubuntu-latest`: `.github/scripts/check-localization.sh`
  checks that every `.strings` file declares the same key set as the English
  baseline and reports duplicates.

### Validation actually performed for Round 2

Recorded precisely, because Round 1's candour about this is the most useful part
of this document:

- `./build.sh` completes and produces `Fan Control.app` with a universal
  (x86_64 + arm64) helper and app, `minos 13.0`, and a 2.4 MB `AppIcon.icns`.
- `.github/scripts/verify-build.sh` → **all checks pass** (signature,
  architectures, deployment targets, optimization flag, icon, localizations,
  `LSMinimumSystemVersion`).
- `.github/scripts/check-localization.sh` → **currently fails**, reporting one
  stale key in `es.lproj` (`Run in accessory mode`) against the English baseline.
  This is being corrected; note that the script only compares languages to each
  other and never against the literals used in source, so a passing run is not
  proof of complete coverage.
- Source review of every behavioural claim in this section against the file and
  line range named in it.

**Not validated:** the watchdog's five-poll threshold under real helper failure,
the deadline-bounded unlock on real Apple-silicon hardware, the `4700` authorize
round trip, the termination reset, `SIGKILL` behaviour, and notarization. All six
need someone with a Mac and an afternoon.

> **Correction (Round 3):** the `4700` authorize round trip and the termination
> reset were subsequently validated on an M5 Max / macOS 27.2 — the authorize
> round trip at `4755`, and the termination reset by observing fans return to
> mode 0 AUTO on `SIGTERM`. The watchdog threshold, the deadline-bounded unlock,
> `SIGKILL` behaviour, and notarization remain unvalidated. See Round 3.

### Round 1 limitations: current status

Re-reading Round 1's "Known limitations and proposed follow-up" list against the
current tree:

| # | Round 1 limitation | Status now |
|---|---|---|
| 1 | Apple's SMC policy is private; do not claim a fan curve or CPU/GPU fan mapping | **Still stands.** Unchanged and still the right position. |
| 2 | Defaults need broader validation across ambient temperatures and workloads | **Still stands.** The values are unchanged; only the code that applies them moved into `FanControlLaw`. |
| 3 | No fan fault diagnosis (sustained target-vs-actual alarm) | **Still stands.** Not implemented. |
| 4 | Linked manual slider applies raw RPM and clamps | **Fixed in Round 2** — percentage projection, see above. |
| 5 | No exportable policy logger / CSV trace | **Still stands.** Not implemented. |
| 6 | Helper authenticates its caller | **Still stands, and now the accepted follow-up.** The helper does not authenticate its caller, and because it must be world-executable (`4755`, see Round 3) that exposure is live. Accepted fix: an XPC privileged helper via `SMJobBless`. Not implemented. |
| — | "The build copies `app_icon.png` in as `AppIcon.png` … avoids an unreliable `.icns` generation step" | **Superseded.** That workaround was the bug; the build now generates a real `.icns`. |
| — | "the plot area is now 320 points high" | **Stale in Round 1; corrected value is 240/160** (see above). Round 1's 320-point figure never matched the current `TempHistoryChartView`. |

Two further Round 1 statements are worth restating because they are the kind that
rot silently: the build "continues to build the helper and app for macOS 13 or
later" (still true, now configurable), and "The privileged helper's command surface
is not broadened" (still true — `get`, `set`, `reset` are unchanged in Round 2).

---

*Everything from here to the end of the file is the Round 1 record, preserved
unchanged from that submission. Where it disagrees with Round 2, Round 2 above
wins — the disagreements are listed in the status table. Round 1 is a snapshot of
a proposal written against upstream base commit `60a57f3`; it is kept rather than
rewritten so the evolution of the work stays auditable.*

This document records the changes made in the `feature/asymmetric-fan-response`
branch after the upstream base commit `60a57f3` (`Merge pull request #8 from
leornt/fix/autostart`). It is written for maintainers reviewing a future pull
request, not as a replacement for the main README.

## Submission

The integrated contribution is proposed upstream as
[pull request #13](https://github.com/ShahzaibAli02/Fanny-MacOs-FanControl/pull/13).
The accompanying reviewer-facing summary is kept in
[`docs/UPSTREAM_PULL_REQUEST.md`](UPSTREAM_PULL_REQUEST.md).

## Purpose and scope

This fork was tested on an Apple-silicon MacBook Pro with an M4 Pro. The work
addresses four practical areas:

1. safer and more stable automatic fan control;
2. reliable sensor presentation and history;
3. lower UI CPU use while retaining a live fan indicator; and
4. usability of the app bundle, Dock presence, menu-bar access, and resizing.
5. native macOS localization for the core interface.

It does **not** claim to reproduce Apple's private SMC fan curve. Apple does
not publish the M4 Pro's thresholds, sensor weights, or individual fan-to-zone
mapping. The app continues to use the SMC values that macOS exposes and always
offers a return to the system's automatic controller.

## Change inventory

| Area | Commits / status | Summary |
|---|---|---|
| Initial asymmetric rule response | `9821100` | Separate rise/fall time constants and an emergency bypass; superseded below by a slew-rate limiter. |
| Controlled test load | `92abb50` | Local, bounded CPU and Metal GPU stress-test utility. |
| Sensor reliability and app presence | `b2a2e5d` | Reject implausible sensor values; restore Dock icon and app activation. |
| Resizable layout | `b6bb6bc` | Let the window and cards use available width with a safe minimum size. |
| Monitoring/render CPU | `f365cdc`, `fc36392` | Removed continuous SwiftUI redraw paths and overlapping status reads. |
| Integration update | this contribution | Core Animation indicator, fixed one-second thermal polling, cooling hysteresis, target deadband, cooling confirmation, command-rate limiter, multi-series history, responsive UI, and native localization. |

The changes intentionally remain separable. A maintainer can review the
automatic-control work independently from the UI and packaging work.

## Native macOS localization (current working tree)

The app bundle now ships standard `Localizable.strings` resources for English,
French, German, Spanish, and Simplified Chinese. `build.sh` includes those
`.lproj` resource directories in the app bundle and declares the same locale
set in its `Info.plist`; macOS therefore selects the language using the user's
system language order or a per-app language choice in System Settings.

Static SwiftUI labels use normal framework localization. A small
`Core/Localization.swift` wrapper is used only for labels constructed at
runtime (for example, formatted menu-bar entries and dynamically selected
sensor names), so those strings receive the same native lookup and English
fallback. Translation maintenance instructions are in
[`docs/LOCALIZATION.md`](LOCALIZATION.md).

Only English and French have been manually verified in the running app.
German, Spanish, and Simplified Chinese are included but remain pending
in-app and native-speaker review; they must not be represented as validated
release translations.

## Automatic fan-control behaviour

### Existing rule resolution preserved

Rules select the highest requested speed across the enabled CPU, GPU, and
battery rules. Percentages are converted **per fan** from the current SMC range:

```text
target RPM = fan minimum RPM + percentage × (fan maximum RPM - fan minimum RPM)
```

`F<n>Mn` and `F<n>Mx` are refreshed from the SMC during status polling; no
one-time calibration database is introduced. When a rule no longer requests
speed, the controller ramps down before returning the fan(s) to macOS Auto.

### Replaced asymmetric response (`9821100`)

`9821100` initially added a first-order filter with separate rise/fall time
constants. It was useful for early tuning, but it made the actual change rate
depend on the size of a temperature step. It is retained in history for review,
but is replaced by the explicit command-rate limiter described below.

### Asymmetric bounded command rates (current working tree)

- **Rise command rate** defaults to **6% per second** and **fall command rate**
  defaults to **3% per second**; each is selectable from 0.5%/s to 10%/s.
- The first automatic demand is applied immediately as a conservative startup
  behaviour; subsequent increases and decreases obey their respective selected
  rate.
- A request of **90% or more** bypasses the rate limiter.

The values persist in `UserDefaults` under
`maximumCommandRiseRatePercentPerSecond` and
`maximumCommandFallRatePercentPerSecond`, and are exposed under **Fan
response**. Unlike a time-constant filter, the two slew-rate limits give an
explicit upper bound on normal command movement while allowing a faster safety
response to rising demand and a gentler acoustic release during cooling.

### Cooling-only temperature hysteresis (current working tree)

Small sensor changes around a threshold can otherwise cause repeated fan target
changes. The current working tree retains each sensor's most recently accepted
control temperature while it is cooling:

- a temperature rise is accepted immediately;
- a temperature fall is accepted only once it is at least the configured
  **Cooling hysteresis** below the retained value;
- the default hysteresis is **5.0 °C** and the selectable range is 0.0–5.0 °C.

This is a cooling-side deadband, not a delay on heating. It therefore reduces
audible hunting without withholding a response to a new thermal rise. The state
is cleared when the rule engine is disabled or returns all fans to Auto.

### Target deadband (current working tree)

The app accepts a new thermal demand only if it differs by at least **4%** from
the previously accepted demand. The selectable range is 1–5%; the value is
persisted as `minimumCommandChangePercent`. The accepted target is then moved
toward at the bounded command rate, allowing small, regular commands instead
of sporadic 4% or larger jumps. A demand of 90% or higher is accepted
immediately.

This reduces sensor-noise hunting without reducing the one-second sensing
cadence or defeating the acoustic rate limit.

### Cooling confirmation (current working tree)

Before accepting a normal downward target change, the lower thermal demand must
persist for **8 seconds** by default. The setting is adjustable from 0 seconds
(disabled) to 15 seconds. A renewed higher demand cancels and restarts the
confirmation period; temperature rises and requests at or above 90% remain
immediate. This prevents short power dips from rapidly unwinding fan speed,
while the existing fall-rate limiter shapes the later, confirmed reduction.

### Polling (current working tree)

The SMC is sampled every **1.0 second**, regardless of whether the window is
frontmost, covered, or hidden. Automatic thermal protection must not have a
different response time because of application visibility. A guard prevents
overlapping helper invocations if a read takes longer than one interval.

## Sensor validation and history (`b2a2e5d`)

Apple-silicon SMC keys can occasionally return low non-zero values that are not
physically credible. The helper now accepts candidate values only inside these
bounds:

| Sensor | Accepted range | Maximum accepted jump per sample |
|---|---:|---:|
| CPU / GPU | 10–115 °C | 25 °C |
| Battery | 5–70 °C | 8 °C |

The view model performs the same validation before using a new reading for
display, rules, or history, and cleans legacy history on loading. An invalid
sample keeps the previous live value; an invalid historical sample is omitted.

> **Correction (Round 4):** the rejection rule above had a flaw. A step larger
> than the cap was rejected on every sample, and the rejected value never became
> the reference. So a sustained change larger than the cap was never accepted,
> and the reading stayed frozen. `TemperatureConditioner` now accepts such a
> change after three agreeing samples. Out-of-range and missing samples are still
> ignored, as described above. See Round 4.

This is input validation, not thermal smoothing: valid increases remain
available to the automatic controller immediately. History is retained for the
most recent 24 hours (at one sample per 30 seconds). The graph itself is a
user-selectable rolling window ending at the current time: 30 minutes, 1 hour,
2 hours (the default), 12 hours, or 24 hours. The selected duration is stored
locally, so it does not revert to a midnight-based calendar-day view on the
next launch. CPU, GPU, and battery histories can be independently enabled as
overlaid curves; the graph supports any combination, including no selected
curve, and remembers those visibility choices locally.

The current CPU temperature is a conservative aggregate, not a confirmed
Apple-silicon die sensor: the helper takes the highest plausible reading from
its ordered CPU key list (`TC0P`, `TC0D`, `TC0F`, and additional legacy and
Apple-silicon candidates). The interface therefore labels it simply **CPU**.
The individual key that contributed the maximum is not yet reported by the
helper; identifying and exposing exact M4 Pro sensor identities remains a
separate, hardware-validated follow-up.

The same maximum CPU value is the one supplied to CPU automatic-control rules;
the controller therefore does not use an arbitrary lower-priority CPU key for
fan decisions.

The history graph can also show a cyan dashed **Fan target** trace. It records
the highest SMC fan-target percentage across installed fans, normalized against
each fan's own minimum and maximum RPM range. This makes the trace conservative
when fans differ and lets temperature in °C and target percentage share a
0–105 scale (which expands only if a higher valid value is recorded). The fan
value itself is clamped to 0–100%, rendered as a continuous cyan line, and the
additional 5 units are temperature headroom rather than an implied 105% fan
command. Hovering a timestamp marks and reports every displayed series. The
former top-row temperature cards were removed once this multi-series graph was
introduced; its plot area is now 320 points high to use that space for the
history rather than duplicate current-value panels.

The graph controls are intentionally separated from the values: the checkbox
legend only selects curves, while a single compact inspection strip reports the
latest values. While the pointer is over the plot, that same strip switches to
the values at the selected time. A second, always visible compact row reports
the minimum–maximum range for each selected series; it is therefore available
without a disclosure control, but does not change while the pointer moves.
The toggle row and both value rows use matching fixed columns, and the scale
caption sits immediately above the plot, to keep the scanning order stable.

## Fan display and UI performance

### Core Animation fan indicator (current working tree)

The original SwiftUI `Canvas` animation was profiled as a significant source of
CPU use while the window was visible. The current implementation creates the
ring, blades, gradient, and hub once as `CALayer`/`CAShapeLayer` objects and
animates only `transform.rotation.z` with `CABasicAnimation`.

Characteristics:

- the compositing system performs the per-frame rotation;
- the indicator pauses when the app resigns active and resumes at its existing
  angle when the app becomes active;
- its direction is monotonic, so an RPM update cannot make it appear to reverse;
- zero reported RPM removes the animation and leaves a static indicator;
- its visual rate is `2 × (currentRPM / maximumRPM)^0.55` revolutions/second.

The concave visual mapping makes low speeds legible while limiting the visual
rate to 2 revolutions/second at full scale. It is an indicator, not a literal
depiction of thousands of physical revolutions per minute.

The `NSViewRepresentable` is explicitly constrained to 80×80 points and does
not overwrite the AppKit root layer's frame. This fixes a resize defect in which
blades could render outside their ring.

### Earlier reduction work (`f365cdc`, `fc36392`)

The intermediate 15 FPS SwiftUI timeline and then the static Canvas avoided the
original display-rate redraw. They are superseded by the Core Animation version
above, but the status-read overlap guard and scene activity plumbing remain
useful.

## Window, Dock, and menu bar

### Foreground application behaviour (`b2a2e5d`)

The application uses the regular activation policy instead of the accessory
policy. This keeps it in the Dock and allows ordinary application switching.
Closing the window hides it rather than quitting; the menu-bar extra can reopen
the main window. The menu icon was changed to `fanblades`.

The build copies `app_icon.png` into the bundle as `AppIcon.png`, and the app
loads that PNG as a runtime fallback icon. This avoids an unreliable `.icns`
generation step in the local build environment.

### Resizing (`b6bb6bc`)

The main window has a 600×680 minimum. Content,
cards, rule engine, history view, and fan rows expand to available width instead
of retaining a fixed 580×680 content frame.

The current working tree raises the default window to 960×900 points (subject
to macOS's usable-display limit). It uses the actual available window height
as a responsive breakpoint: below 900 points, the heading margins and the
history plot contract modestly. The visual order remains history, manual fan
controls, then automatic rules. In that compact layout, each fan card retains
its Auto/Manual control, manual target slider, and all five speed presets; the
presets use reduced spacing and type size while the explanatory Auto text is
omitted. This keeps the automatic-rules card
discoverable on the first screen of a compact notebook display rather than
relying on a global scale factor that would make sliders and labels harder to
use. When no history series is selected, the empty graph area collapses to a
short icon-and-message row, reclaiming space immediately.

The populated history plot is 240 points high in the regular layout and 160
points in the compact layout. Fan cards use a horizontal composition: the
larger status indicator is on the left, while the RPM, Auto/Manual selector,
target slider, and (when space permits) preset buttons are grouped to its
right. This removes the previous full-width target-control stack from beneath
each fan and leaves more vertical room before the automatic-rules card.
The fan indicator is vertically centered in that control group and uses a
140×140 point regular visual column (88×88 in the compact layout), avoiding
the former top-aligned badge appearance.

## Controlled thermal-load utility (`92abb50`)

`tools/thermal-load` is a local, opt-in Swift command-line utility. It creates
a bounded CPU workload and, when Metal is available, a bounded GPU compute
workload. It is not shipped inside the application bundle.

- CPU load is limited to 80%; GPU load is limited to 70%.
- The default four-minute plan is warm-up, CPU, CPU+GPU, then cooling.
- A custom plan is expressed as `seconds:cpu:gpu` steps.
- Control-C stops the workload immediately.

Use it only while supervising the Mac. The intended comparison workflow is:

1. reset Fan Control to Auto and capture the system's native response;
2. repeat with a candidate rule configuration;
3. compare temperatures, target RPM, actual RPM, and the smoothness of the
   transitions; and
4. return to Auto after every test.

The tool does not identify which physical fan cools which die region. That
requires measured CPU-only and GPU-only trials; the physical fan-to-zone
mapping is not inferred by this fork.

## Build and local-install notes

`build.sh` continues to build the helper and app for macOS 13 or later. The
signing identity is now overridable:

```bash
ARCHS=arm64 SIGNING_IDENTITY=- ./build.sh
```

This supports local ad-hoc ARM64 builds when the upstream Developer ID
certificate is unavailable. A release for other users should be signed and
notarized by its publisher; an ad-hoc signature is not a distribution strategy.

The helper remains a privileged, setuid-root component, as in the upstream
design. This fork does not broaden its command surface. Any upstream security
review should nevertheless treat helper installation, ownership, and code
signing as a first-class release concern.

## Validation performed locally

- ARM64 compilation succeeds with macOS 13 deployment target.
- The app and helper pass `codesign --verify --deep --strict` after an ad-hoc
  local build.
- CPU/GPU temperature histories no longer accept the previously observed
  implausible ~2 °C CPU-die samples.
- Core Animation replaced the observed continuous SwiftUI drawing cost; manual
  interactive testing reported substantially lower idle/visible CPU use.

The build script now falls back automatically to `Fan Control.zip` if `hdiutil`
cannot create the optional DMG because no device service is available. The ZIP
contains the same built and signed `.app` bundle and can be unzipped then moved
to Applications. A successful DMG continues to be the preferred drag-and-drop
installer.

## Known limitations and proposed follow-up

1. **Apple SMC policy is private.** Do not describe this as Apple's fan curve or
   claim that the two fans map exclusively to CPU and GPU.
2. **Defaults require broader validation.** The 6%/s rise and 3%/s fall
   command-rate limits, 5 °C cooling hysteresis, and 4% target deadband are documented starting
   values, chosen for conservative cooling and reduced hunting. They should be
   tested across ambient temperatures and workloads.
3. **No fan fault diagnosis.** The app reads actual RPM but does not yet expose
   a sustained target-versus-actual fault alarm.
4. **Linked manual slider semantics need review.** The global percentage path is
   correctly per-fan, but the `linkedFans` path currently applies the initiating
   slider's raw RPM to each fan and clamps it. A future change should project the
   initiating fan's percentage into every other fan's own min/max range.
5. **No native policy logger yet.** The history graph is useful, but an exportable
   CSV trace of CPU/GPU temperatures, each fan's actual/target RPM, rule demand,
   and final filtered command would make native-vs-custom comparison easier.
6. **The setuid helper accepts commands from any caller — accepted follow-up.**
   Because the app launches the helper directly with `Process` rather than via
   `sudo`, the helper must be world-executable, so it must ship at `4755`
   (setuid root + executable). That means any local user, or any malware running
   as that user, can drive the fans, including to zero. The current design bounds
   this — minimal `get`/`set`/`reset` surface, hardened runtime with library
   validation blocking `DYLD_*` injection, and a `checkAuthorization()` that
   rejects a helper which is not root-owned, not setuid, or group/other-writable
   — but **it cannot remove it**. The accepted fix is an **XPC privileged helper
   (`SMJobBless`)** that moves the privileged code out of the bundle and
   authenticates the connecting process, so only the signed GUI app can obtain
   SMC writes. Not implemented. This is the one entry on this list that is a
   security item rather than a feature gap, and it should not be closed by
   changing the file mode: `4700` was tried in Round 2 and it broke thermal
   polling outright. See Round 3 and [`SECURITY.md`](../SECURITY.md).

## Suggested upstream PR structure

For reviewability, split a future submission into independent pull requests:

1. sensor validation and resizable/Dock UI fixes;
2. automatic control: command-rate limiter, hysteresis, target deadband, and
   settings UI;
3. Core Animation performance work;
4. optional `tools/thermal-load` developer utility; and
5. Round 4: single controller, serial helper writes, sensor conditioning, the
   monotonic clock, the state stores, history storage, the menu-bar readout, and
   `tests/unit`.

Each PR should include hardware/model information, a brief manual test matrix,
and an explicit statement that users can reset to macOS Auto at any time.
