#!/bin/sh
# Configuration errors and their messages: a pure-Nix test sees only that an evaluation
# fails (tryEval drops the message), so each case here evaluates one broken input with iets
# and requires the message a user needs on stderr. Run from the repo root, inside the dev
# shell; scripts/lint runs it.
set -u
cd "$(dirname "$0")/../.."
failures=0
count=0

# expect <name> <message> <expression>: the expression must fail, and its error must
# contain the message.
expect() {
  count=$((count + 1))
  if out=$(iets eval --expr "$3" 2>&1); then
    echo "FAIL $1: evaluated, expected an error" >&2
    failures=$((failures + 1))
  elif ! printf '%s' "$out" | grep -qF -- "$2"; then
    echo "FAIL $1: wrong error, expected: $2" >&2
    printf '%s\n' "$out" | grep -v '^ *…' | head -n 5 >&2
    failures=$((failures + 1))
  fi
}

# mkSystem over a document, forced as far as the composed units
sys() {
  echo "builtins.deepSeq (import ./lib/system.nix { config = $1; system = \"x86_64-linux\"; }).composed.units true"
}

expect "unknown package name" \
  "golconda: /services/sshd.package names the package 'no-such-package', which the target set does not have" \
  "$(sys '{ "/system" = { name = "t"; version = "20261031.1"; }; "/services/sshd".package = "no-such-package"; }')"
expect "downstream package with a repkgs alias name" \
  "golconda: downstream package cpython has the name of a repkgs alias (cpython -> " \
  "$(sys ./tests/fixtures/downstream-alias/server.toml)"
expect "missing downstream directory" \
  "golconda: golconda.modules names 'nowhere', which does not exist" \
  "$(sys ./tests/fixtures/downstream-none/missing.toml)"
expect "unlisted replacement" \
  'golconda: downstream package openssh replaces Golconda'"'"'s package of that name; add "openssh" to [golconda] replaces to allow it' \
  "$(sys ./tests/fixtures/downstream-unlisted/server.toml)"
expect "stale replacement entry" \
  "golconda: [golconda] replaces lists jq, but no downstream package replaces a package of that name" \
  "$(sys ./tests/fixtures/downstream-stale/server.toml)"

echo "$count configuration errors, $failures failures"
[ "$failures" -eq 0 ]
