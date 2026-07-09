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

if [ "$fails" -eq 0 ]; then
  echo "All lsp smoke tests passed"
else
  echo "$fails lsp smoke test(s) failed"
  exit 1
fi
