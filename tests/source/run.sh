#!/bin/sh
# The checks' source (nix/source.nix) on a scratch repository and on a worktree of it: a tracked
# file has its working-tree contents, a staged new file is in, an untracked file and an ignored
# one (.git/info/exclude, where the tokens were) are not. Run from anywhere with nix on PATH and a
# Nix daemon; scripts/lint runs it.
set -u
repo=$(dirname "$(dirname "$(dirname "$(realpath "$0")")")")
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
failures=0

g() { git -c user.email=t@t -c user.name=t -c init.defaultBranch=main "$@"; }
g init -q "$tmp/r"
echo one >"$tmp/r/tracked"
g -C "$tmp/r" add tracked
g -C "$tmp/r" commit -qm first
g -C "$tmp/r" worktree add -q "$tmp/w" 2>/dev/null
echo '/.hf-secrets/' >>"$tmp/r/.git/info/exclude"
for d in "$tmp/r" "$tmp/w"; do
  echo two >"$d/tracked"
  echo staged >"$d/staged"
  g -C "$d" add staged
  echo secret >"$d/untracked"
  mkdir -p "$d/.hf-secrets"
  echo token >"$d/.hf-secrets/gh-write"
  got=$(nix-instantiate --read-write-mode --eval --strict --json -E "
    let s = import $repo/nix/source.nix $d; in {
      tracked = builtins.readFile \"\${s}/tracked\";
      staged = builtins.pathExists \"\${s}/staged\";
      untracked = builtins.pathExists \"\${s}/untracked\";
      ignored = builtins.pathExists \"\${s}/.hf-secrets\";
    }" 2>"$tmp/err") || {
    cat "$tmp/err" >&2
    got=error
  }
  want='{"ignored":false,"staged":true,"tracked":"two\n","untracked":false}'
  if [ "$got" = "$want" ]; then
    echo "PASS source of ${d#"$tmp"/}"
  else
    echo "FAIL source of ${d#"$tmp"/}: $got (want $want)" >&2
    failures=$((failures + 1))
  fi
done
[ "$failures" = 0 ]
