#!/bin/bash
# Verify that every Localization/<lang>.lproj/Localizable.strings declares the
# exact same key set as the baseline language.
#
# A stale key in one language is invisible at runtime (nothing looks it up) but
# it silently rots, so we fail the build on any drift.
#
# Usage: .github/scripts/check-localization.sh [repo-root]
# Exit:  0 = parity holds
#        1 = drift detected
#        2 = bad usage / nothing to check

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${1:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
LOCALIZATION_DIR="$REPO_ROOT/Localization"
STRINGS_FILE="Localizable.strings"
PREFERRED_BASELINE="en"

fail_usage() {
    printf 'error: %s\n' "$*" >&2
    exit 2
}

# Tokenize a .strings file and print one key per line.
#
# This is a small scanner rather than a grep because .strings has real lexical
# rules: // and /* */ comments, escaped quotes inside a key, and string
# literals that wrap across lines. A line-oriented regex gets all three wrong.
extract_keys() {
    awk '
    function skip_space(s, i) {
        while (i <= length(s)) {
            c = substr(s, i, 1)
            if (c == " " || c == "\t") i++
            else break
        }
        return i
    }
    {
        s = $0
        i = 1
        while (i <= length(s)) {
            if (in_comment) {
                if (substr(s, i, 2) == "*/") { in_comment = 0; i += 2 }
                else i++
                continue
            }
            if (in_string) {
                if (substr(s, i, 1) == "\\") { buf = buf substr(s, i, 2); i += 2; continue }
                if (substr(s, i, 1) == "\"") {
                    in_string = 0
                    # A string immediately followed by "=" is a key.
                    j = skip_space(s, i + 1)
                    if (substr(s, j, 1) == "=") print buf
                    buf = ""
                    i = j + 1
                    continue
                }
                buf = buf substr(s, i, 1)
                i++
                continue
            }
            c = substr(s, i, 1)
            if (c == " " || c == "\t") { i++; continue }
            if (c == "/") {
                d = substr(s, i + 1, 1)
                if (d == "*") { in_comment = 1; i += 2; continue }
                if (d == "/") { i = length(s) + 1; continue }
                i++
                continue
            }
            if (c == "\"") { in_string = 1; buf = ""; i++; continue }
            i++
        }
    }
    ' "$1"
}

# Count lines from a file argument, or from stdin when called in a pipeline.
# wc pads its output with leading spaces on macOS, so strip them.
count_lines() {
    if [ "$#" -gt 0 ]; then
        wc -l < "$1" | tr -d ' \t'
    else
        wc -l | tr -d ' \t'
    fi
}

[ -d "$LOCALIZATION_DIR" ] || fail_usage "no Localization directory at $LOCALIZATION_DIR"

shopt -s nullglob
strings_files=("$LOCALIZATION_DIR"/*.lproj/"$STRINGS_FILE")
shopt -u nullglob
[ "${#strings_files[@]}" -gt 0 ] || fail_usage "no *.$STRINGS_FILE files under $LOCALIZATION_DIR"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

status=0

# --- structural checks -------------------------------------------------------
# A .lproj directory with no Localizable.strings compiles fine and ships an
# empty language, so catch it here rather than in the app bundle.
for lproj in "$LOCALIZATION_DIR"/*.lproj; do
    [ -d "$lproj" ] || continue
    if [ ! -f "$lproj/$STRINGS_FILE" ]; then
        printf 'FAIL  %s has no %s\n' "$(basename "$lproj")" "$STRINGS_FILE"
        status=1
    fi
done

languages=()
for file in "${strings_files[@]}"; do
    dir_name="$(basename "$(dirname "$file")")"
    lang="${dir_name%.lproj}"
    languages+=("$lang")
    extract_keys "$file" | LC_ALL=C sort > "$tmp/$lang.keys"

    # A repeated key resolves to the first occurrence; the later one is dead
    # weight that no reviewer will ever notice.
    duplicates="$(uniq -d < "$tmp/$lang.keys" || true)"
    if [ -n "$duplicates" ]; then
        printf 'FAIL  %s defines duplicate keys:\n' "$lang"
        printf '%s\n' "$duplicates" | sed 's/^/        - /'
        status=1
    fi
done

# --- baseline ----------------------------------------------------------------
baseline="$PREFERRED_BASELINE"
if [ ! -f "$tmp/$baseline.keys" ]; then
    baseline="$(printf '%s\n' "${languages[@]}" | LC_ALL=C sort | head -n 1)"
    printf 'note: %s.lproj not found, using %s.lproj as the baseline\n\n' \
        "$PREFERRED_BASELINE" "$baseline"
fi

baseline_count="$(count_lines "$tmp/$baseline.keys")"

printf 'Localization key parity (baseline: %s, %s keys)\n' "$baseline" "$baseline_count"
printf '  %-10s %7s\n' LANGUAGE KEYS
for lang in "${languages[@]}"; do
    printf '  %-10s %7s\n' "$lang" "$(count_lines "$tmp/$lang.keys")"
done
printf '\n'

# --- parity ------------------------------------------------------------------
for lang in "${languages[@]}"; do
    if [ "$lang" = "$baseline" ]; then
        continue
    fi

    missing="$(LC_ALL=C comm -23 "$tmp/$baseline.keys" "$tmp/$lang.keys" || true)"
    extra="$(LC_ALL=C comm -13 "$tmp/$baseline.keys" "$tmp/$lang.keys" || true)"

    if [ -z "$missing" ] && [ -z "$extra" ]; then
        printf '  PASS  %s matches %s\n' "$lang" "$baseline"
        continue
    fi

    status=1
    printf '  FAIL  %s vs %s\n' "$lang" "$baseline"
    if [ -n "$missing" ]; then
        printf '        %s key(s) missing from %s.lproj:\n' \
            "$(printf '%s\n' "$missing" | count_lines)" "$lang"
        printf '%s\n' "$missing" | sed 's/^/          - /'
    fi
    if [ -n "$extra" ]; then
        printf '        %s key(s) absent from %s.lproj (stale/orphan):\n' \
            "$(printf '%s\n' "$extra" | count_lines)" "$baseline"
        printf '%s\n' "$extra" | sed 's/^/          + /'
    fi
done

if [ "$status" -eq 0 ]; then
    printf '\nOK: all %s languages share the same %s key set.\n' \
        "${#languages[@]}" "$baseline_count"
else
    printf '\nLocalization drift detected; see the per-language report above.\n' >&2
fi

exit "$status"
