#!/usr/bin/env bash
# content-guard.sh: fail if a tracked file carries something this repository must not hold (README, "What may be
# written here"): an email address, a secret or token, a public IP address, or an unreleased model name. Prints the
# file and line of each hit, never more of it than needed. Run from the repository root.
set -uo pipefail
files=$(git ls-files)
fail=0
hit() { echo "::error file=$1::$2"; fail=1; }

while IFS= read -r f; do
  [ -f "$f" ] || continue
  case "$f" in scripts/content-guard.sh|scripts/test-content-guard.sh) continue ;; esac
  # Email addresses, except the documentation domains.
  grep -noE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' "$f" | grep -vE '@(example\.(com|net|org)|users\.noreply\.github\.com)$' |
    while IFS=: read -r line _; do echo "::error file=$f,line=$line::an email address"; done | grep . && fail=1
  # Secrets and tokens by their well-known shapes.
  grep -noE '(ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-ant-[A-Za-z0-9_-]{10,}|AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}|cfat_[A-Za-z0-9_-]{10,}|xox[abpr]-[A-Za-z0-9-]{10,}|-----BEGIN [A-Z ]*PRIVATE KEY-----)' "$f" |
    while IFS=: read -r line _; do echo "::error file=$f,line=$line::a secret or token"; done | grep . && fail=1
  # Public IPv4 addresses (loopback, link-local, private and documentation ranges are fine).
  grep -noE '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' "$f" | while IFS=: read -r line ip; do
    case "$ip" in 127.*|169.254.*|10.*|192.168.*|0.0.0.0|192.0.2.*|198.51.100.*|203.0.113.*) continue ;; esac
    if [[ "$ip" =~ ^172\.(1[6-9]|2[0-9]|3[01])\. ]]; then continue; fi
    echo "::error file=$f,line=$line::a public IP address"
  done | grep . && fail=1
  # Unreleased model names by their suffix, and mentions of the program.
  grep -noiE '([a-z0-9]-eap\b|\beap\b|early[ -]access)' "$f" |
    while IFS=: read -r line _; do echo "::error file=$f,line=$line::an unreleased model name or mention"; done | grep . && fail=1
done <<<"$files"

[ "$fail" -eq 0 ] && echo "content guard: clean"
exit "$fail"
