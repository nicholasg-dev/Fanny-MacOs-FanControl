# Localization

Fan Control uses the standard macOS bundle localization mechanism. At launch,
macOS selects the best matching language from the user's system language order
or the per-application language selected in **System Settings → General →
Language & Region**. No network service, account, or third-party runtime is
used.

## Included languages and coverage

All five languages ship the same **99 keys** — verified against the tables, not
estimated:

| Language | Locale directory | Keys |
|---|---|---:|
| English (development language) | `Localization/en.lproj` | 99 |
| French | `Localization/fr.lproj` | 99 |
| German | `Localization/de.lproj` | 99 |
| Spanish | `Localization/es.lproj` | 99 |
| Simplified Chinese | `Localization/zh-Hans.lproj` | 99 |

Every directory contains `Localizable.strings`. The build script copies these
directories into `Fan Control.app/Contents/Resources`, where macOS discovers
them through the bundle's standard `CFBundleLocalizations` metadata.

Parity is enforced by `.github/scripts/check-localization.sh`, which uses the
English file as the baseline and also reports duplicate keys:

```bash
bash .github/scripts/check-localization.sh
```

Last run (2026-10-13, M5 Max / macOS 27.2) → **PASS**, 99 keys, all five
languages in parity, exit 0. The script also runs in CI.

### What a passing check does *not* prove

The script compares languages **to each other**, never against the literals
actually used in source. A passing run therefore proves *parity*, not *coverage*:
it cannot detect a key that SwiftUI uses and no `.strings` file declares. Treat
it as a guard against languages drifting apart, not as proof that every visible
string is translated.

## Verification status

The English and French interfaces have been manually verified in the app.
German, Spanish, and Simplified Chinese are included for broader coverage, but
they have **not** been reviewed by native speakers and should not be presented as
release-ready translations. Key parity is mechanical and does not address this:
a table can be complete and still be wrong, and machine-reviewed translation
produces plausible text that a fluent reader will immediately distrust.

They also have not been exercised in the running app end to end. Reviewing them
is outstanding work, not a formality.

## Updating a translation

1. Use the English file as the complete key list.
2. Keep the text left of `=` exactly unchanged; it is the source key used by
   SwiftUI and the `L10n` helper.
3. Preserve format placeholders such as `%@`, `%d`, and `%.1f` in the same
   order and type as the English entry.
4. Do not translate SMC register identifiers, units, or product names unless a
   locale convention genuinely requires it.
5. Build the app and select that language in macOS to review labels, menus,
   help text, authorization errors, and chart controls.

SwiftUI text literals use the bundle automatically. `Core/Localization.swift`
is used only where a label is assembled dynamically at runtime, so it follows
the identical macOS lookup and fallback behaviour.

### Choosing the formatter: whole counts versus decimals

`Core/Localization.swift` has two formatters, and the choice matters:

- **`L10n.format`** passes the user's locale to `String(format:)`. Decimals then
  use the locale's decimal separator, so `"%.1f°C"` shows as `34,1°C` in French
  and German. The same locale also groups a `%d` with the locale's thousands
  separator, which shows a fan speed as `4,500 RPM`.
- **`L10n.formatCount`** passes no locale. It is for whole counts such as fan
  speeds, which show as `4500 RPM` with no separator in any locale.

Use `formatCount` for any integer count. Use `format` only when the value has a
decimal part that should follow the locale. The keys `%d RPM`, `%@ — %d RPM
(%@)` and `Fan at %d RPM` use `formatCount`. `tests/unit/main.swift` checks it
against the separator bug.
