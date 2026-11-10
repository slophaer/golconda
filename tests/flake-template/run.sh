#!/bin/sh
# templates.default (docs/reference/pinning.md, "A flake"): `nix flake init -t` writes a flake
# whose lock moves with `nix flake update golconda`. It makes a flake from this tree's template,
# in a temporary directory, with Golconda's input as a bare clone of this repository (so that
# it needs no network for Golconda), and checks that
#   - the lock holds the older commit (HEAD~1) while the input says no commit,
#   - `nix flake update golconda` moves the lock to HEAD, with HEAD's narHash,
#   - the flake evaluates the /usr tree at HEAD.
# With --build it also builds the signed image from the flake (`nix build .#image`, with a
# throwaway key set from scripts/make-keys, path value): it takes the time of an image build, so
# queue it (qbuild flake-template -- tests/flake-template/run.sh --build). Run from anywhere with
# flakes on the client's nix and a Nix daemon with the fork's features; scripts/lint runs it
# without --build.
set -eu
repo=$(dirname "$(dirname "$(dirname "$(realpath "$0")")")")
build=false
[ "${1:-}" != --build ] || build=true
git -C "$repo" rev-parse --verify -q HEAD~1 >/dev/null || {
  echo "flake-template test: needs a history of two commits" >&2
  exit 1
}
old=$(git -C "$repo" rev-parse HEAD~1)
new=$(git -C "$repo" rev-parse HEAD)

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail() {
  echo "FAIL flake-template: $1" >&2
  exit 1
}
# a bare clone: git+file takes its HEAD, and the checkout may have uncommitted changes. Its HEAD
# names a branch at HEAD: nix fetches a detached HEAD as a ref named by the commit and fails
# ("couldn't find remote ref"), and scripts/verify --each-commit checks out each commit detached
git clone -q --bare "$repo" "$tmp/golconda.git"
git -C "$tmp/golconda.git" update-ref refs/heads/flake-template-test "$new"
git -C "$tmp/golconda.git" symbolic-ref HEAD refs/heads/flake-template-test
# the template of the committed tree, as `nix flake init -t github:slophaer/golconda` gets it
mkdir "$tmp/sys"
cd "$tmp/sys"
nix flake init -t "git+file://$tmp/golconda.git" >/dev/null 2>"$tmp/err" \
  || { cat "$tmp/err" >&2; fail "nix flake init -t failed"; }
for f in flake.nix server.toml README.md; do
  [ -f "$f" ] || fail "nix flake init wrote no $f"
done
# the one line a user changes when the input is not on GitHub
grep -q 'inputs.golconda.url = "github:slophaer/golconda";' flake.nix \
  || fail "flake.nix: the golconda input is not github:slophaer/golconda"
sed -i "s|github:slophaer/golconda\";|git+file://$tmp/golconda.git\";|" flake.nix
if $build; then
  "$repo/scripts/make-keys" "$tmp/sys/keys" >/dev/null
  # the template's commented image, with the key directory as a path value (a string needs
  # the daemon's extra-sandbox-paths)
  sed -i -e 's|^\( *\)# image =|\1image =|' \
    -e '/^ *image =$/,/}).disk;/ s|^\( *\)# |\1|' \
    -e 's|keys = "/srv/golconda-keys";|keys = ./keys;|' flake.nix
fi

# lock at the older commit: the input stays unpinned, the lock has the rev
nix flake lock --override-input golconda "git+file://$tmp/golconda.git?rev=$old" >/dev/null 2>&1 \
  || fail "nix flake lock failed"
# lock EXPR: the Nix expression EXPR on the lock's golconda node `n`, printed raw
lock() { nix eval --raw --impure --expr "let n = (builtins.fromJSON (builtins.readFile ./flake.lock)).nodes.golconda; in $1"; }
[ "$(lock n.locked.rev)" = "$old" ] || fail "the lock is not at $old: $(lock n.locked.rev)"
[ "$(lock 'toString (n.original ? rev)')" = "" ] || fail "the lock's original input is pinned to a rev"
narHash=$(lock n.locked.narHash)

nix flake update golconda >/dev/null 2>&1 || fail "nix flake update golconda failed"
[ "$(lock n.locked.rev)" = "$new" ] || fail "the lock did not move to $new: $(lock n.locked.rev)"
[ "$(lock n.locked.narHash)" != "$narHash" ] || fail "the lock's narHash did not change"

nix eval --raw ".#packages.x86_64-linux.default.drvPath" >/dev/null 2>"$tmp/err" \
  || { cat "$tmp/err" >&2; fail "the flake does not evaluate its usr tree at $new"; }
if $build; then
  nix build ".#image" --no-link >/dev/null 2>"$tmp/err" \
    || { cat "$tmp/err" >&2; fail "nix build .#image failed"; }
fi
echo "flake-template: lock moved $old -> $new$($build && echo ", image built")"
