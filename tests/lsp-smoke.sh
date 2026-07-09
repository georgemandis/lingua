#!/bin/sh
# Smoke tests for lingua lsp. Usage: sh tests/lsp-smoke.sh (after `zig build`)
set -u
export LC_ALL=C
LINGUA="${LINGUA:-./zig-out/bin/lingua}"
fails=0

frame() {
  body="$1"
  printf 'Content-Length: %d\r\n\r\n%s' "${#body}" "$body"
}

check() {
  desc="$1"; want="$2"; out="$3"
  case "$out" in
    *"$want"*) echo "PASS: $desc" ;;
    *) echo "FAIL: $desc (missing '$want')"; fails=$((fails + 1)) ;;
  esac
}

OUT=$({
  frame '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}'
  frame '{"jsonrpc":"2.0","method":"initialized","params":{}}'
  frame '{"jsonrpc":"2.0","id":2,"method":"bogus/method","params":{}}'
  frame '{"jsonrpc":"2.0","id":3,"method":"shutdown"}'
  frame '{"jsonrpc":"2.0","method":"exit"}'
} | "$LINGUA" lsp 2>/dev/null)
code=$?

check "initialize advertises full sync" '"textDocumentSync":1' "$OUT"
check "initialize advertises code actions" '"codeActionProvider":true' "$OUT"
check "initialize advertises utf-16" '"positionEncoding":"utf-16"' "$OUT"
check "unknown request gets MethodNotFound" '"code":-32601' "$OUT"
if [ "$code" -eq 0 ]; then
  echo "PASS: clean exit after shutdown+exit"
else
  echo "FAIL: exit code $code after shutdown+exit"
  fails=$((fails + 1))
fi

OUT=$(frame '{"jsonrpc":"2.0","id":1,"method":"shutdown"}' | "$LINGUA" lsp 2>/dev/null)
check "request before initialize rejected" '"code":-32002' "$OUT"

OUT=$({
  frame '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}'
  frame '{"jsonrpc":"2.0","method":"textDocument/codeAction","params":{}}'
  frame '{"jsonrpc":"2.0","id":7,"method":"shutdown"}'
  frame '{"jsonrpc":"2.0","method":"exit"}'
} | "$LINGUA" lsp 2>/dev/null)
code=$?
check "codeAction without id is ignored, server keeps serving" '"id":7,"result":null' "$OUT"
if [ "$code" -eq 0 ]; then
  echo "PASS: clean exit after id-less codeAction"
else
  echo "FAIL: exit code $code after id-less codeAction"
  fails=$((fails + 1))
fi

OUT=$({
  frame '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}'
  frame '{"jsonrpc":"2.0","method":"initialized","params":{}}'
  frame '{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///tmp/t.md","languageId":"markdown","version":1,"text":"He go to the store yesterday."}}}'
  frame '{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///tmp/t.md","version":2},"contentChanges":[{"text":"All clear here."}]}}'
  frame '{"jsonrpc":"2.0","id":9,"method":"shutdown"}'
  frame '{"jsonrpc":"2.0","method":"exit"}'
} | "$LINGUA" lsp 2>/dev/null)

check "didOpen publishes grammar diagnostic" '"severity":2' "$OUT"
check "grammar diagnostic at line 0 char 3" '"start":{"line":0,"character":3}' "$OUT"
check "grammar diagnostic ends at char 5" '"end":{"line":0,"character":5}' "$OUT"
check "diagnostic carries source" '"source":"lingua"' "$OUT"
check "didChange to clean text clears diagnostics" '"diagnostics":[]' "$OUT"

OUT=$({
  frame '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}'
  frame '{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///tmp/s.md","languageId":"markdown","version":1,"text":"I recieve emails."}}}'
  frame '{"jsonrpc":"2.0","id":9,"method":"shutdown"}'
  frame '{"jsonrpc":"2.0","method":"exit"}'
} | "$LINGUA" lsp 2>/dev/null)

check "spelling diagnostic is severity 1" '"severity":1' "$OUT"
check "spelling message names the word" "Possibly misspelled: 'recieve'" "$OUT"
check "spelling corrections in data" '"corrections":["receive"' "$OUT"

OUT=$({
  frame '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}'
  frame '{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///tmp/s.md","languageId":"markdown","version":1,"text":"I recieve emails."}}}'
  frame '{"jsonrpc":"2.0","id":5,"method":"textDocument/codeAction","params":{"textDocument":{"uri":"file:///tmp/s.md"},"range":{"start":{"line":0,"character":4},"end":{"line":0,"character":4}},"context":{"diagnostics":[]}}}'
  frame '{"jsonrpc":"2.0","id":6,"method":"textDocument/codeAction","params":{"textDocument":{"uri":"file:///tmp/s.md"},"range":{"start":{"line":0,"character":12},"end":{"line":0,"character":14}},"context":{"diagnostics":[]}}}'
  frame '{"jsonrpc":"2.0","id":9,"method":"shutdown"}'
  frame '{"jsonrpc":"2.0","method":"exit"}'
} | "$LINGUA" lsp 2>/dev/null)

check "codeAction offers the correction" "Change to 'receive'" "$OUT"
check "codeAction is a quickfix" '"kind":"quickfix"' "$OUT"
check "codeAction edit replaces with correction" '"newText":"receive"' "$OUT"
check "codeAction outside any diagnostic returns empty" '"id":6,"result":[]' "$OUT"

if [ "$fails" -eq 0 ]; then
  echo "All lsp smoke tests passed"
else
  echo "$fails lsp smoke test(s) failed"
  exit 1
fi
