#!/bin/sh
# Smoke tests for lingua grammar and spell commands.
# Usage: sh tests/smoke.sh   (after `zig build`)
set -u
LINGUA="${LINGUA:-./zig-out/bin/lingua}"
fails=0

expect() {
  desc="$1"; want_exit="$2"; want_substr="$3"; got_output="$4"; got_exit="$5"
  if [ "$got_exit" -ne "$want_exit" ]; then
    echo "FAIL: $desc (exit $got_exit, wanted $want_exit)"
    fails=$((fails + 1))
    return
  fi
  case "$got_output" in
    *"$want_substr"*) echo "PASS: $desc" ;;
    *)
      echo "FAIL: $desc (output missing '$want_substr'): $got_output"
      fails=$((fails + 1))
      ;;
  esac
}

# --- spell ---
# Note: NSSpellChecker's two-arg checkSpellingOfString:startingAt: does not
# flag "Teh" as misspelled on all systems/dictionaries (it appears to treat
# it as an acceptable token, unlike the language-explicit 6-arg selector).
# "recieve" is a reliably-flagged misspelling, so smoke tests use it instead.

out=$(echo "I will recieve it." | "$LINGUA" spell); code=$?
expect "spell finds misspelling" 1 "spell: recieve" "$out" $code

out=$(echo "I will recieve it." | "$LINGUA" spell); code=$?
expect "spell shows guesses" 1 " -> " "$out" $code

out=$(echo "The cat sat." | "$LINGUA" spell); code=$?
expect "spell clean input exits 0" 0 "" "$out" $code

out=$(echo "I will recieve it." | "$LINGUA" spell --json); code=$?
expect "spell json shape" 1 '"type":"spelling","value":"recieve"' "$out" $code

out=$(echo "The cat sat." | "$LINGUA" spell --json); code=$?
expect "spell json clean is empty array" 0 "[]" "$out" $code

out=$(echo "I will recieve it." | "$LINGUA" spell --lang=en); code=$?
expect "spell --lang override" 1 "recieve" "$out" $code

out=$(printf "" | "$LINGUA" spell 2>&1); code=$?
expect "spell empty input exits 2" 2 "empty input" "$out" $code

# --- summary ---

if [ "$fails" -eq 0 ]; then
  echo "All smoke tests passed"
else
  echo "$fails smoke test(s) failed"
  exit 1
fi
