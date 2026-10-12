#!/usr/bin/env bash
# test-content-guard.sh: each forbidden shape fails the guard, and the allowed ones pass.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
check() { # expect content
  local t; t=$(mktemp -d); (cd "$t" && git init -q && printf '%s\n' "$2" >f.md && git add f.md &&
    bash "$here/content-guard.sh" >/dev/null 2>&1); local rc=$?; rm -rf "$t"
  if [ "$1" = fail ] && [ "$rc" -eq 0 ]; then echo "MISSED: $2"; exit 1; fi
  if [ "$1" = pass ] && [ "$rc" -ne 0 ]; then echo "FALSE ALARM: $2"; exit 1; fi
}
check fail "mail someone at person.name@gmail.com"
check fail "token ghp_abcdefghijklmnopqrstuvwxyz0123"
check fail "key AKIAABCDEFGHIJKLMNOP"
check fail "ssh to 54.193.62.221"
check fail "run claude-test-model-eap here"
check fail "I test early-access models"
check pass "use someone@example.com"
check pass "loopback 127.0.0.1, metadata 169.254.169.254, VPC 10.0.1.50, 172.31.48.10"
check pass "Opus 5.5, Sonnet 5.5 and Haiku 5.5; ssh fcvm-arm; the heap is cheap"
echo "test-content-guard: all cases behave"
