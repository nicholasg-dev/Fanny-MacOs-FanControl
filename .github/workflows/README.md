`ci.yml` runs two jobs: `build`, a `macos-14`/`macos-15` matrix that builds the
universal bundle ad-hoc signed and then asserts signature, architectures,
deployment target, optimization, icon and bundled localizations; and
`localization`, a fast parity check over `Localization/*.lproj`.

Both are check-only and read-only. To reproduce locally, run
`.github/scripts/verify-build.sh` after `./build.sh` and
`.github/scripts/check-localization.sh` on its own.

The unit checks in `tests/unit/` are **not** run by CI yet. Run them locally
with `tests/run-tests.sh`. Adding them as a job is a separate change.
