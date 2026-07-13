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

# --- grammar ---

out=$(echo "He go to the store yesterday." | "$LINGUA" grammar); code=$?
expect "grammar finds agreement issue" 1 "go" "$out" $code

out=$(echo "Their are many problem with with this sentence." | "$LINGUA" grammar); code=$?
expect "grammar finds doubled word" 1 "doubled" "$out" $code

out=$(echo "Their are many problem with with this sentence." | "$LINGUA" grammar); code=$?
expect "grammar doubled word has correction" 1 " -> with" "$out" $code

out=$(echo "The cat sat on the mat." | "$LINGUA" grammar); code=$?
expect "grammar clean input exits 0" 0 "" "$out" $code

out=$(echo "He go to the store yesterday." | "$LINGUA" grammar --json); code=$?
expect "grammar json shape" 1 '"type":"grammar"' "$out" $code

out=$(printf "" | "$LINGUA" grammar 2>&1); code=$?
expect "grammar empty input exits 2" 2 "empty input" "$out" $code

# --- style ---

out=$(echo "Mistakes were made by the team." | "$LINGUA" style); code=$?
expect "style flags passive voice" 1 "passive voice: 'were made' [9,9]" "$out" $code

out=$(echo "She quickly and quietly definitely ran extremely fast." | "$LINGUA" style); code=$?
expect "style flags adverb pile-up" 1 "5 adverbs in one sentence" "$out" $code

out=$(echo "The committee decided that the proposal needs another full review next quarter because several members raised concerns about the budget, the timeline, the staffing plan, and the overall scope of the entire project." | "$LINGUA" style); code=$?
expect "style flags long sentence" 1 "sentence has 33 words (max 30)" "$out" $code

out=$(echo "The cat sat on the mat." | "$LINGUA" style); code=$?
expect "style clean input exits 0" 0 "" "$out" $code

out=$(echo "Mistakes were made by the team." | "$LINGUA" style --json); code=$?
expect "style json shape" 1 '"type":"style","rule":"passive","value":"were made"' "$out" $code

out=$(echo "He ran quickly and quietly." | "$LINGUA" style --max-adverbs=2); code=$?
expect "style threshold override" 1 "2 adverbs in one sentence" "$out" $code

out=$(echo "He ran quickly and quietly." | "$LINGUA" style); code=$?
expect "style default threshold not tripped by 2 adverbs" 0 "" "$out" $code

out=$(printf "" | "$LINGUA" style 2>&1); code=$?
expect "style empty input exits 2" 2 "empty input" "$out" $code

# --- define ---

out=$(echo "serendipity" | "$LINGUA" define); code=$?
expect "define finds a word via stdin" 0 "noun" "$out" $code

out=$("$LINGUA" define serendipity); code=$?
expect "define takes an argument" 0 "serendipity" "$out" $code

out=$("$LINGUA" define "lingua franca"); code=$?
expect "define handles phrases" 0 "language" "$out" $code

out=$("$LINGUA" define asdfqwerty 2>&1); code=$?
expect "define unknown term exits 1" 1 "No definition found for 'asdfqwerty'" "$out" $code

out=$("$LINGUA" define serendipity --json); code=$?
expect "define json shape" 0 '"term":"serendipity","definition":"' "$out" $code

out=$(printf "" | "$LINGUA" define 2>&1); code=$?
expect "define empty input exits 2" 2 "empty input" "$out" $code

# --- summary ---

if [ "$fails" -eq 0 ]; then
  echo "All smoke tests passed"
else
  echo "$fails smoke test(s) failed"
  exit 1
fi
