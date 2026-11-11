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
# nix-build makes the out-link (-o): straight to a folder named after the attribute
# ($FAKE_IMAGES/ATTR), or, with FAKE_ROOT, into /nix/store as a chroot store's out-link does, with
# the image under FAKE_ROOT and its disk/ a further store link. FAKE_IMAGE=fail fails every build,
# FAKE_IMAGE=ATTR the build of ATTR.
cat >"$WORK/bin/nix-build" <<'EOF'
#!/bin/sh
echo "nix-build $*" >>"$CALLS"
while [ $# -gt 0 ]; do
  case "$1" in -o) link=$2; shift 2 ;; -A) attr=${2##*.}; shift 2 ;; *) shift ;; esac
done
case "${FAKE_IMAGE:-}" in fail | "$attr") exit 4 ;; esac
rm -f "$link"
if [ -n "${FAKE_ROOT:-}" ]; then
  mkdir -p "$FAKE_ROOT/nix/store/aaa-image/keys" "$FAKE_ROOT/nix/store/bbb-disk"
  : >"$FAKE_ROOT/nix/store/bbb-disk/disk.raw"
  ln -sfn /nix/store/bbb-disk "$FAKE_ROOT/nix/store/aaa-image/disk"
  ln -s /nix/store/aaa-image "$link"
else
  mkdir -p "$FAKE_IMAGES/$attr/disk" "$FAKE_IMAGES/$attr/keys"
  : >"$FAKE_IMAGES/$attr/disk/disk.raw"
  ln -s "$FAKE_IMAGES/$attr" "$link"
fi
exit 0
EOF
cat >"$WORK/bin/nix-instantiate" <<'EOF'
#!/bin/sh
echo '"245843bcafe"'
EOF
chmod +x "$WORK/bin/"*
export BOOT_TEST_CACHE="$WORK/cache" RV="$WORK" PATH="$WORK/bin:$PATH" CALLS="$WORK/calls" FAKE_IMAGES="$WORK/images"
unset BOOT_TEST_STORE_ROOT NIX_REMOTE || true

# A repository with scripts/verify, a fake boot-test, and two commits.
repo=$WORK/repo
mkdir -p "$repo/scripts" "$repo/pins/repkgs"
cp "$ROOT/scripts/verify" "$repo/scripts/verify"
cat >"$repo/scripts/boot-test" <<'EOF'
#!/bin/sh
echo "boot-test $*" >>"$CALLS"
echo "golconda=${BOOT_TEST_GOLCONDA:-unset} path=${PATH%%:*}" >>"$RV/boot-env"
# --rendezvous NAME: needs the other of rv-a and rv-b to start, so a serial run times out
case " $* " in
*" --rendezvous "*)
  : >"$RV/rv-$(echo "$*" | sed 's/.*--rendezvous //;s/ .*//')"
  n=0
  while [ ! -e "$RV/rv-a" ] || [ ! -e "$RV/rv-b" ]; do
    n=$((n + 1))
    [ $n -lt 50 ] || { echo "rendezvous timed out"; exit 5; }
    sleep 0.1
  done
  ;;
esac
echo "PASS: fake-a"
echo "PASS: 1, FAIL: 0"
case " $* " in *" --fail "*) echo "FAIL: fake-check"; echo "fake boot failed"; exit 6 ;; esac
echo "PASS: fake-b"
echo "fake boot ok"
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
PATH_HEAD=${PATH%%:*}
run() {
  : >"$CALLS"
  set +e
  out=$("$@" 2>&1)
  rc=$?
  set -e
}

# 1 a clean tree passes lint, image, the initrd's second build, the release's second signing and
#   boot, in that order, and says what it tested
run scripts/verify
[ $rc = 0 ] || fail "clean run exited $rc: $out"
echo "$out" | grep -q "verify $head, repkgs 245843b" || fail "no commit and pin line: $out"
for s in lint image initrd-reproducible disk-reproducible boot; do
  echo "$out" | grep -qE "^PASS $s [0-9]+s$" || fail "no PASS line for $s: $out"
done
order=$(cut -d' ' -f1 "$CALLS" | tr '\n' ' ')
[ "$order" = "nix-shell nix-build nix-build nix-build boot-test " ] || fail "steps out of order: $order"
grep -q 'nix-build -A packages\.[a-z0-9_]*-linux\.initrd-reproducible -o result-verify-initrd-reproducible$' "$CALLS" ||
  fail "the initrd's second build did not run: $(cat "$CALLS")"
grep -q 'nix-build -A packages\.[a-z0-9_]*-linux\.disk-reproducible -o result-verify-disk-reproducible$' "$CALLS" ||
  fail "the release's second signing did not run: $(cat "$CALLS")"
grep -q 'nix-build -A packages\.[a-z0-9_]*-linux\.image-smoke-test -o result-verify' "$CALLS" ||
  fail "image not built to result-verify: $(cat "$CALLS")"
grep -q "boot-test $WORK/images/image-smoke-test/disk/disk.raw --keys $WORK/images/image-smoke-test/keys --secure-boot --ssh-test --tpm --timeout 300" "$CALLS" ||
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

# 9 --boot-set runs the sets at the same time and prints a line for each; the log of a set that
#    passes is removed, the log of a failed set stays and its path is on the line
rm -f "$WORK/rv-a" "$WORK/rv-b"
run scripts/verify --boot-set '--rendezvous a --timeout 1' --boot-set '--rendezvous b'
[ $rc = 0 ] || fail "--boot-set run exited $rc: $out"
[ "$(grep -c '^boot-test' "$CALLS")" = 2 ] || fail "want 2 boots: $(cat "$CALLS")"
grep -q 'boot-test .* --keys .* --rendezvous b$' "$CALLS" || fail "set 2 not run: $(cat "$CALLS")"
echo "$out" | grep -qE '^PASS boot\[1\] [0-9]+s @image=image-smoke-test --rendezvous a --timeout 1$' || fail "no line for set 1: $out"
echo "$out" | grep -qE '^PASS boot\[2\] [0-9]+s @image=image-smoke-test --rendezvous b$' || fail "no line for set 2: $out"
[ "$(echo "$out" | grep -cxF '  passed boot[1] (2): fake-a fake-b')" = 2 ] ||
  fail "the passed checks of set 1 not listed under its line and in the summary: $out"
[ -z "$(find "$WORK/cache" -name 'boot-*.log')" ] || fail "the log of a passed set was kept"
[ -z "$(find "$WORK/cache" -maxdepth 1 -name 'verify.*' -newer "$CALLS")" ] || fail "an empty log directory was kept"
run scripts/verify --boot-set '--timeout 1' --boot-set '--fail'
[ $rc != 0 ] || fail "a failing set passed"
echo "$out" | grep -qE '^PASS boot\[1\] [0-9]+s @image=image-smoke-test --timeout 1$' || fail "passing set not reported: $out"
[ "$(echo "$out" | grep -c '^FAIL: fake-check')" = 2 ] || fail "failed checks not listed with the log tail: $out"
echo "$out" | grep -qE '^FAIL\(6\) boot\[2\] [0-9]+s @image=image-smoke-test --fail \(log .*boot-2\.log\)$' || fail "failing set not reported: $out"
echo "$out" | grep -qxF '  passed boot[2] (1): fake-a' || fail "the passed checks of a failed set not listed: $out"
log=$(echo "$out" | sed -n 's/^FAIL(6) boot\[2\] .*(log \(.*\))$/\1/p' | head -1)
grep -q 'fake boot failed' "$log" || fail "the failed set's log is missing: $log"
[ -e "$(dirname "$log")/boot-1.log" ] && fail "the passed set's log is next to it"
rm -rf "$(dirname "$log")"

# 10 --each-commit hands the sets to the last commit's run
run scripts/verify --each-commit "$(git rev-list --max-parents=0 HEAD)" --boot-set '--timeout 1' --boot-set '--timeout 2'
[ $rc = 0 ] || fail "--each-commit with sets exited $rc: $out"
[ "$(grep -c '^boot-test' "$CALLS")" = 2 ] || fail "want 2 boots of the last commit: $(cat "$CALLS")"
echo "$out" | grep -qE '^PASS boot\[2\] [0-9]+s @image=image-smoke-test --timeout 2$' || fail "set 2 not reported: $out"

# 11 the logs of a failed set live under BOOT_TEST_CACHE, else
#    ${XDG_CACHE_HOME:-$HOME/.cache}/golconda-boot-test, not /tmp; directories older than 7 days
#    are removed, newer ones stay
run scripts/verify --boot-set '--fail'
log=$(echo "$out" | sed -n 's/^FAIL(6) boot\[1\] .*(log \(.*\))$/\1/p' | head -1)
case $log in "$WORK/cache/"*) ;; *) fail "log not under BOOT_TEST_CACHE: $log" ;; esac
mkdir -p "$WORK/cache/verify.old" "$WORK/cache/run.old"
touch -d '10 days ago' "$WORK/cache/verify.old" "$WORK/cache/run.old"
run env -u BOOT_TEST_CACHE XDG_CACHE_HOME="$WORK/xdg" scripts/verify --boot-set '--fail'
log=$(echo "$out" | sed -n 's/^FAIL(6) boot\[1\] .*(log \(.*\))$/\1/p' | head -1)
case $log in "$WORK/xdg/golconda-boot-test/"*) ;; *) fail "log not under XDG_CACHE_HOME: $log" ;; esac
run scripts/verify --boot-set '--timeout 1'
[ ! -e "$WORK/cache/verify.old" ] || fail "an old log directory was kept"
[ -e "$WORK/cache/run.old" ] || fail "a run directory (a failed run's) was removed"

# 12 @next in a boot set or in --boot-args stands for the next release's image: verify builds
#    <image>-next as well (result-verify-next), with its own PASS line, and puts its path where
#    @next stands. Without @next, and with --no-boot, there is no second build.
rm -f "$WORK/boot-env"
run scripts/verify --boot-set '--ssh-test --next @next --timeout 1' --boot-set '--timeout 2'
[ $rc = 0 ] || fail "@next run exited $rc: $out"
grep -q 'nix-build -A packages\.[a-z0-9_]*-linux\.image-smoke-test-next -o result-verify-next$' "$CALLS" ||
  fail "the next image was not built: $(cat "$CALLS")"
# --next pushes admin vars with golconda and age: verify builds them and puts them on boot-test's PATH
for a in golconda-cli age; do
  grep -q "nix-build -A packages\\.[a-z0-9_]*-linux\\.$a -o result-verify-$a\$" "$CALLS" || fail "$a not built: $(cat "$CALLS")"
  echo "$out" | grep -qE "^PASS $a [0-9]+s\$" || fail "no PASS line for $a: $out"
done
grep -qxF "golconda=$WORK/images/golconda-cli/bin/golconda path=$WORK/images/age/bin" "$WORK/boot-env" ||
  fail "BOOT_TEST_GOLCONDA or PATH not set for boot-test: $(cat "$WORK/boot-env")"
echo "$out" | grep -qE '^PASS image-next [0-9]+s$' || fail "no PASS line for the next image: $out"
grep -q "boot-test .* --ssh-test --next $WORK/images/image-smoke-test-next --timeout 1\$" "$CALLS" ||
  fail "@next not replaced by the next image's path: $(cat "$CALLS")"
grep -q '@next' "$CALLS" && fail "@next left in a boot-test call: $(cat "$CALLS")"
rm -f "$WORK/boot-env"
run scripts/verify --boot-set '--timeout 1' --boot-set '--timeout 2'
[ "$(sort -u "$WORK/boot-env")" = "golconda=unset path=$PATH_HEAD" ] || fail "BOOT_TEST_GOLCONDA set without @next: $(cat "$WORK/boot-env")"
[ "$(grep -c '^nix-build' "$CALLS")" = 3 ] || fail "built the next image without @next: $(cat "$CALLS")"
run scripts/verify --no-boot --boot-set '--next @next'
grep -q 'result-verify-next' "$CALLS" && fail "built the next image despite --no-boot"
run scripts/verify --image image-smoke-test-nosb --boot-args '--ssh-test --next @next --timeout 480'
[ $rc = 0 ] || fail "@next in --boot-args exited $rc: $out"
grep -q '\.image-smoke-test-nosb-next -o result-verify-next$' "$CALLS" || fail "nosb pair wrong: $(cat "$CALLS")"
grep -q "boot-test .* --ssh-test --next $WORK/images/image-smoke-test-nosb-next --timeout 480\$" "$CALLS" ||
  fail "@next in --boot-args not replaced: $(cat "$CALLS")"
FAKE_IMAGE=fail run scripts/verify --boot-set '--next @next'
grep -q boot-test "$CALLS" && fail "booted after an image failure with @next"
# each-commit hands the sets, @next included, to the last commit
run scripts/verify --each-commit "$(git rev-list --max-parents=0 HEAD)" --boot-set '--next @next'
[ $rc = 0 ] || fail "--each-commit with @next exited $rc: $out"
grep -q 'result-verify-next' "$CALLS" || fail "--each-commit did not build the next image"

# 13 a boot set can name its image with a leading @image=ATTR word (else --image's): verify builds
#    each image once (the --image one to result-verify, another to result-verify-ATTR, with a
#    PASS line "image:ATTR"), boots each set from its own image, puts the next image of the set's
#    image where @next stands (ATTR-next, result-verify-ATTR-next), and names the image on each
#    summary line
run scripts/verify --boot-set '@image=image-nosb --ssh-test --timeout 1' --boot-set '--timeout 2' \
  --boot-set '@image=image-nosb --ssh-test --next @next' --boot-set '@image=image-smoke-test --next @next'
[ $rc = 0 ] || fail "@image run exited $rc: $out"
for a in image-smoke-test:result-verify image-nosb:result-verify-image-nosb \
  image-smoke-test-next:result-verify-next image-nosb-next:result-verify-image-nosb-next \
  golconda-cli:result-verify-golconda-cli age:result-verify-age \
  initrd-reproducible:result-verify-initrd-reproducible \
  disk-reproducible:result-verify-disk-reproducible; do
  [ "$(grep -c "^nix-build -A packages\\.[a-z0-9_]*-linux\\.${a%%:*} -o ${a#*:}\$" "$CALLS")" = 1 ] ||
    fail "${a%%:*} not built once to ${a#*:}: $(cat "$CALLS")"
done
[ "$(grep -c '^nix-build' "$CALLS")" = 8 ] || fail "want 8 builds: $(cat "$CALLS")"
for s in image image:image-nosb image-next image-next:image-nosb; do
  echo "$out" | grep -qE "^PASS $s [0-9]+s\$" || fail "no PASS line for $s: $out"
done
I=$WORK/images
grep -qxF "boot-test $I/image-nosb/disk/disk.raw --keys $I/image-nosb/keys --ssh-test --timeout 1" "$CALLS" ||
  fail "set 1 not booted from image-nosb: $(grep boot-test "$CALLS")"
grep -qxF "boot-test $I/image-smoke-test/disk/disk.raw --keys $I/image-smoke-test/keys --timeout 2" "$CALLS" ||
  fail "set 2 not booted from the --image image: $(grep boot-test "$CALLS")"
grep -qxF "boot-test $I/image-nosb/disk/disk.raw --keys $I/image-nosb/keys --ssh-test --next $I/image-nosb-next" "$CALLS" ||
  fail "set 3: @next is not image-nosb's next image: $(grep boot-test "$CALLS")"
grep -qxF "boot-test $I/image-smoke-test/disk/disk.raw --keys $I/image-smoke-test/keys --next $I/image-smoke-test-next" "$CALLS" ||
  fail "set 4: @next is not image-smoke-test's next image: $(grep boot-test "$CALLS")"
grep -q '@image' "$CALLS" && fail "@image left in a boot-test call: $(cat "$CALLS")"
for l in '1 [0-9]+s @image=image-nosb --ssh-test --timeout 1' '2 [0-9]+s @image=image-smoke-test --timeout 2' \
  '3 [0-9]+s @image=image-nosb --ssh-test --next @next' '4 [0-9]+s @image=image-smoke-test --next @next'; do
  [ "$(echo "$out" | grep -cE "^PASS boot\\[${l%% *}\\] ${l#* }\$")" = 2 ] ||
    fail "no line naming the image for set ${l%% *} (under it and in the summary): $out"
done
# a run whose sets all name another image does not build the --image one; --no-boot builds the
# sets' images and no next image
run scripts/verify --boot-set '@image=image-nosb --timeout 1'
[ $rc = 0 ] || fail "@image-only run exited $rc: $out"
[ "$(grep '^nix-build' "$CALLS" | sed 's/.*\.\([^ .]*\) -o .*/\1/' | tr '\n' ' ')" = "image-nosb initrd-reproducible disk-reproducible " ] ||
  fail "want image-nosb built alone, then the initrd's second build and the release's second signing: $(cat "$CALLS")"
run scripts/verify --no-boot --boot-set '@image=image-nosb --next @next' --boot-set '--timeout 1'
[ $rc = 0 ] || fail "--no-boot with @image exited $rc: $out"
[ "$(grep '^nix-build' "$CALLS" | sed 's/.*\.\([^ .]*\) -o .*/\1/' | sort | tr '\n' ' ')" = "disk-reproducible image-nosb image-smoke-test initrd-reproducible " ] ||
  fail "--no-boot: want both images, the second builds and no next image: $(cat "$CALLS")"
grep -q boot-test "$CALLS" && fail "booted despite --no-boot"
# a failed build of one image stops the run before any boot
FAKE_IMAGE=image-nosb run scripts/verify --boot-set '--timeout 1' --boot-set '@image=image-nosb --timeout 1'
[ $rc != 0 ] || fail "a failed image-nosb build passed"
echo "$out" | grep -qE '^FAIL\(4\) image:image-nosb [0-9]+s$' || fail "no FAIL line for image:image-nosb: $out"
grep -q boot-test "$CALLS" && fail "booted after a failed image build"
# --each-commit hands @image sets to the last commit
run scripts/verify --each-commit "$(git rev-list --max-parents=0 HEAD)" --boot-set '@image=image-nosb --timeout 1'
[ $rc = 0 ] || fail "--each-commit with @image exited $rc: $out"
grep -q "boot-test $I/image-nosb/disk/disk.raw " "$CALLS" || fail "--each-commit lost @image: $(cat "$CALLS")"

# 14 @next=ATTR stands for the image packages.<system>.ATTR as the next release (out-link
#    result-verify-ATTR, step image-next:ATTR), for a next image that is no <image>-next, as
#    image-smoke-test-rotated is for --rotate. Built once, with golconda-cli and age.
run scripts/verify --boot-set '--secure-boot --next @next=image-smoke-test-rotated --rotate --timeout 1'
[ $rc = 0 ] || fail "@next=ATTR run exited $rc: $out"
grep -q 'nix-build -A packages\.[a-z0-9_]*-linux\.image-smoke-test-rotated -o result-verify-image-smoke-test-rotated$' "$CALLS" ||
  fail "the named next image was not built: $(cat "$CALLS")"
grep -q 'image-smoke-test-next' "$CALLS" && fail "built <image>-next despite @next=ATTR: $(cat "$CALLS")"
grep -qxF "boot-test $WORK/images/image-smoke-test/disk/disk.raw --keys $WORK/images/image-smoke-test/keys --secure-boot --next $WORK/images/image-smoke-test-rotated --rotate --timeout 1" "$CALLS" ||
  fail "@next=ATTR not replaced by the named image's path: $(grep boot-test "$CALLS")"
echo "$out" | grep -qE '^PASS image-next:image-smoke-test-rotated [0-9]+s$' || fail "no PASS line for the named next image: $out"
grep -q 'golconda-cli' "$CALLS" || fail "golconda-cli not built for @next=ATTR"

echo "verify tests passed"
