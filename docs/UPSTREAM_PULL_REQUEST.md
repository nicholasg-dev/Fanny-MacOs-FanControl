# Proposed upstream pull request

## Title

Improve Apple-silicon fan monitoring, automatic-control stability, and compact UI

## Summary

This contribution was developed and interactively tested on an Apple M4 Pro
MacBook Pro. It improves the reliability and usability of Fan Control without
claiming to reproduce Apple's private thermal policy.

The principal changes are:

- validate temperature samples and use the highest plausible CPU reading from
  the available CPU-oriented SMC keys;
- retain one-second SMC polling regardless of window visibility, with a guard
  against overlapping helper requests;
- add adjustable asymmetric command-rate limits, cooling hysteresis, target
  deadband, cooling confirmation, and an emergency high-demand bypass;
- add an overlaid, selectable temperature-and-fan-target history chart with
  a rolling time range, hover inspection, and grid;
- replace continuous SwiftUI fan drawing with Core Animation to reduce visible
  UI CPU usage while keeping the fan indicator proportional and monotonic;
- improve normal window behaviour, Dock presence, menu-bar reopening,
  responsive sizing, and compact notebook layouts; and
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
- store history as an append-only file off the main thread, instead of rewriting
  it into UserDefaults every 30 seconds;
- show the menu-bar readout rounded to 50 RPM, without a thousands separator, in
  a slot sized for the widest reading, so the menu-bar item does not resize; and
- replace the first-run threshold rules with gentle curves, which start disabled.

## Safety and scope

- English and French are the only localization variants manually verified in
  the running app. German, Spanish, and Simplified Chinese are included but
  require in-app and native-speaker review before release.

- The app always retains the existing **Reset All to Auto** path.
- Quitting runs the reset after any write already in flight, and waits at most
  12 seconds for it before the app quits.
- While a rule is in charge, a fan that the user sets to Auto is forced back to
  manual, at most once every 30 seconds. Disable the rules engine to stop this.
  Reviewers should weigh this as a change in how user choices are honoured.
- Temperature increases and high requests remain fast; cooling-side controls
  are used to reduce acoustic hunting rather than to delay a thermal rise.
- The CPU value is a conservative aggregate of plausible keys. It is labelled
  **CPU**, not as a confirmed physical die sensor.
- The code does not infer that a particular physical fan cools only the CPU or
  only the GPU.
- The privileged helper's command surface is not broadened.

## Manual validation

- ARM64 app and helper compile with macOS 13.0 as the deployment target.
- The local app bundle passes `codesign --verify --deep --strict` after an
  ad-hoc build.
- Interactive M4 Pro testing covered manual fan control, automatic rules,
  window resizing, background operation, history display, and CPU/Metal load
  transitions.
- If `hdiutil` cannot create a DMG in a sandboxed local environment, the build
  automatically emits a ZIP containing the usable, signed `.app` instead.
- Later validation, on an Apple M5 Max / macOS 27.2 (see `docs/FORK_CHANGELOG.md`,
  Rounds 3 and 4): 44 of 44 unit checks in `tests/run-tests.sh`; a universal
  build with no compiler warnings; `verify-build.sh` and `check-localization.sh`
  passing (99 keys in five languages); one live controller instead of two,
  checked with `heap`; and history recorded every 30 seconds from one writer.
- Not yet checked on hardware: the drift re-send under a live rule, the menu-bar
  width across the full fan range, the starter curves under load, and the Intel
  path. The unit checks are not yet run in CI.

## Review guidance

`docs/FORK_CHANGELOG.md` contains the detailed behavioural record, persisted
setting names, validation bounds, known limitations, and suggested follow-up
work. The changes are substantial and could be split for review into sensor
reliability, automatic-control policy, UI/performance, and test-tool commits.
Round 4 adds state-store, write-ordering, and history-storage changes, which fit
the same split.

Thank you for considering the contribution. I would be happy to split or
adjust it to match the project's preferred design and review boundaries.
