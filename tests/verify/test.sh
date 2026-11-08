#!/bin/sh
# scripts/verify on a scratch repository with fake nix-shell, nix-build and boot-test: the steps
# run in order, stop at the first failure, and the summary names the commit, the pin and each
# step. No Nix build or VM starts.
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
fail() {
  echo "FAIL: $1" >&2
  exit 1
}

# The fakes log each call to $CALLS. nix-shell runs its --run script (treefmt and lint are
# fakes too); FAKE_LINT=fail fails lint, FAKE_TREEFMT=change edits a tracked file.
mkdir -p "$WORK/bin"
cat >"$WORK/bin/nix-shell" <<'EOF'
#!/bin/sh
echo "nix-shell remote=${NIX_REMOTE:-none} $*" >>"$CALLS"
while [ $# -gt 0 ]; do
  case "$1" in --run) script=$2; shift 2 ;; *) shift ;; esac
done
[ "$script" = true ] && exit 0
[ "${FAKE_TREEFMT:-}" = change ] && echo changed >>README.md
[ "${FAKE_LINT:-}" = fail ] && { echo "lint: finding"; exit 3; }
exit 0
EOF
# nix-build makes the out-link (-o): straight to an image folder, or, with FAKE_ROOT, into
# /nix/store as a chroot store's out-link does, with the image under FAKE_ROOT and its disk/
# a further store link.
cat >"$WORK/bin/nix-build" <<'EOF'
#!/bin/sh
echo "nix-build $*" >>"$CALLS"
[ "${FAKE_IMAGE:-}" = fail ] && exit 4
while [ $# -gt 0 ]; do
  case "$1" in -o) link=$2; shift 2 ;; *) shift ;; esac
done
rm -f "$link"
if [ -n "${FAKE_ROOT:-}" ]; then
  mkdir -p "$FAKE_ROOT/nix/store/aaa-image/keys" "$FAKE_ROOT/nix/store/bbb-disk"
  : >"$FAKE_ROOT/nix/store/bbb-disk/disk.raw"
  ln -sfn /nix/store/bbb-disk "$FAKE_ROOT/nix/store/aaa-image/disk"
  ln -s /nix/store/aaa-image "$link"
else
  mkdir -p "$FAKE_IMAGES/img/disk" "$FAKE_IMAGES/img/keys"
  : >"$FAKE_IMAGES/img/disk/disk.raw"
  ln -s "$FAKE_IMAGES/img" "$link"
fi
exit 0
EOF
cat >"$WORK/bin/nix-instantiate" <<'EOF'
#!/bin/sh
echo '"245843bcafe"'
EOF
chmod +x "$WORK/bin/"*
export PATH="$WORK/bin:$PATH" CALLS="$WORK/calls" FAKE_IMAGES="$WORK/images"
unset BOOT_TEST_STORE_ROOT NIX_REMOTE || true

# A repository with scripts/verify, a fake boot-test, and two commits.
repo=$WORK/repo
mkdir -p "$repo/scripts" "$repo/pins/repkgs"
cp "$ROOT/scripts/verify" "$repo/scripts/verify"
cat >"$repo/scripts/boot-test" <<'EOF'
#!/bin/sh
echo "boot-test $*" >>"$CALLS"
exit 0
EOF
chmod +x "$repo/scripts/verify" "$repo/scripts/boot-test"
printf '[pin]\nrev = "0123456789abcdef"\n' >"$repo/pins/repkgs/sources.toml"
echo readme >"$repo/README.md"
git -C "$repo" init -q
git -C "$repo" add -A
git -C "$repo" -c user.email=t@t -c user.name=t commit -qm first
echo more >>"$repo/README.md"
git -C "$repo" -c user.email=t@t -c user.name=t commit -qam second
head=$(git -C "$repo" rev-parse --short HEAD)
cd "$repo"
run() {
  : >"$CALLS"
  set +e
  out=$("$@" 2>&1)
  rc=$?
  set -e
}

# 1 a clean tree passes lint, image and boot, in that order, and says what it tested
run scripts/verify
[ $rc = 0 ] || fail "clean run exited $rc: $out"
echo "$out" | grep -q "verify $head, repkgs 245843b" || fail "no commit and pin line: $out"
for s in lint image boot; do
  echo "$out" | grep -qE "^PASS $s [0-9]+s$" || fail "no PASS line for $s: $out"
done
order=$(cut -d' ' -f1 "$CALLS" | tr '\n' ' ')
[ "$order" = "nix-shell nix-build boot-test " ] || fail "steps out of order: $order"
grep -q 'nix-build -A packages\.[a-z0-9_]*-linux\.image-smoke-test -o result-verify' "$CALLS" ||
  fail "image not built to result-verify: $(cat "$CALLS")"
grep -q "boot-test $WORK/images/img/disk/disk.raw --keys $WORK/images/img/keys --secure-boot --ssh-test --tpm --timeout 300" "$CALLS" ||
  fail "boot-test not given the image's disk, keys and the smoke flags: $(cat "$CALLS")"
grep -qE -- '--run ./scripts/lint$' "$CALLS" || fail "lint is not scripts/lint in the dev shell"

# 2 an unclean tree is refused before any build
echo dirty >>README.md
run scripts/verify
[ $rc != 0 ] || fail "unclean tree accepted"
[ -s "$CALLS" ] && fail "built despite an unclean tree"
git checkout -q README.md

# 3 a lint failure stops the run: no image, no boot
FAKE_LINT=fail run scripts/verify
[ $rc != 0 ] || fail "lint failure passed"
echo "$out" | grep -q '^FAIL(3) lint' || fail "no FAIL line for lint: $out"
grep -q nix-build "$CALLS" && fail "image built after a lint failure"

# 4 files the lint step changed fail the run
FAKE_TREEFMT=change run scripts/verify
[ $rc != 0 ] || fail "treefmt changes passed"
echo "$out" | grep -q 'changed files' || fail "changed files not named: $out"
git checkout -q README.md

# 5 --no-boot skips the boot; --image picks the attribute
run scripts/verify --no-boot --image image-nosb
[ $rc = 0 ] || fail "--no-boot run exited $rc: $out"
grep -q boot-test "$CALLS" && fail "booted despite --no-boot"
grep -q '\.image-nosb -o result-verify' "$CALLS" || fail "--image ignored: $(cat "$CALLS")"

# 6 on a chroot store the dev shell is realised in the host store first
BOOT_TEST_STORE_ROOT=/srv/store NIX_REMOTE=unix:///x run scripts/verify --no-boot
[ $rc = 0 ] || fail "chroot-store run exited $rc: $out"
first=$(head -1 "$CALLS")
case "$first" in "nix-shell remote=none "*"--run true") ;; *) fail "dev shell not realised on the host first: $first" ;; esac
sed -n 2p "$CALLS" | grep -q 'remote=unix:///x' || fail "lint left the chroot store"

# 6b on a chroot store the out-link is followed under the store root, link by link, and
#    --boot-args replaces the smoke flags
FAKE_ROOT=$WORK/root BOOT_TEST_STORE_ROOT=$WORK/root run scripts/verify --boot-args '--timeout 480'
[ $rc = 0 ] || fail "chroot-store boot exited $rc: $out"
grep -q "boot-test $WORK/root/nix/store/bbb-disk/disk.raw --keys $WORK/root/nix/store/aaa-image/keys --timeout 480\$" "$CALLS" ||
  fail "chroot-store paths or --boot-args wrong: $(grep boot-test "$CALLS")"

# 7 --each-commit lints every commit since BASE and builds and boots only the last
run scripts/verify --each-commit "$(git rev-list --max-parents=0 HEAD)"
[ $rc = 0 ] || fail "--each-commit exited $rc: $out"
[ "$(grep -c '^nix-shell' "$CALLS")" = 1 ] || fail "want lint of 1 commit after the root: $(cat "$CALLS")"
echo "$out" | grep -qE "^PASS $head second" || fail "no per-commit line: $out"
grep -q boot-test "$CALLS" || fail "last commit not booted"
git worktree list | grep -q verify-each && fail "scratch worktree left behind"

# 8 a failing image stops before the boot
FAKE_IMAGE=fail run scripts/verify
[ $rc != 0 ] || fail "image failure passed"
grep -q boot-test "$CALLS" && fail "booted after an image failure"

echo "verify tests passed"
