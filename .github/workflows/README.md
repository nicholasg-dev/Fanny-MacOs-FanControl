# Continuous integration

`ci.yml` runs on every push (any branch), on every pull request, and on manual
dispatch via the **Actions** tab. Two jobs:

## `build` — macOS runner matrix

Runs on **`macos-14` and `macos-15`**, with `fail-fast: false` so both SDK
generations report rather than one masking the other, and a 45-minute timeout.
Each runner checks out, reports its toolchain, builds the universal bundle with an
**ad-hoc signature** (`SIGNING_IDENTITY="-"`), and then runs
`.github/scripts/verify-build.sh`, which asserts:

- `codesign --verify --deep --strict` passes;
- `FanControl` and `smc-helper` are both universal (`x86_64 arm64`);
- both carry `minos 13.0`;
- `build.sh` actually passed an optimization flag;
- the app binary is non-trivial in size;
- `AppIcon.icns` is present;
- all five localizations are in `Contents/Resources`;
- `Info.plist`'s `LSMinimumSystemVersion` is 13.0.

It then uploads whichever installer the build produced — `Fan Control.zip` or
`Fan Control.dmg` — as a 14-day artifact named `fan-control-<runner>`. Both
filenames are listed and the step is `if-no-files-found: warn`, because
`hdiutil` cannot always create a disk image on a hosted runner: `build.sh` falls
back to a ZIP, and the ZIP is the portable fallback that keeps the job useful
either way.

**These artifacts are ad-hoc signed.** They are for inspection, not distribution —
Gatekeeper will reject them on another Mac. To produce something distributable,
sign with a Developer ID and notarize locally via `NOTARY_PROFILE`.

## `localization` — Ubuntu runner

Runs `.github/scripts/check-localization.sh` on `ubuntu-latest`. Fast, no build
step required. It compares every `Localization/*.lproj` table against English and
also reports duplicate keys.

> This proves **parity**, not **coverage**. The check compares languages *to each
> other*, never against the literals actually used in source, so it cannot detect
> a key that SwiftUI uses and no `.strings` file declares. See
> [`docs/LOCALIZATION.md`](../../docs/LOCALIZATION.md).

## Reproducing locally

```bash
./build.sh                            # universal, ad-hoc signed
.github/scripts/verify-build.sh        # the same assertions the build job makes
.github/scripts/check-localization.sh # the same assertion the parity job makes
```

## What CI does *not* run

The 44 unit checks in `tests/unit/` are **not** part of this workflow. Run them
locally before changing the control law or the stores:

```bash
tests/run-tests.sh
```

They are plain executable assertions — no XCTest target, no window server, no
signing, no helper. Wiring them in as a third job is a separate, unstarted
change. They currently compile alongside `Core/Localization.swift` and
`ViewModels/FanStores.swift`, both of which use `Foundation`, so a Linux runner
*may* work — that has not been tried, and the honest starting position is to add
the job on `macos-latest` first and only then consider moving it.