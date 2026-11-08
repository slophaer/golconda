#!/bin/sh
# scripts/tools.sh with a fake nix and nix-build: tools_path builds the packages with
# `nix build --print-out-paths` (nix-build cannot name the output of a floating content-addressed
# derivation with a content-addressed input, NixOS/nix#16389) and gives their bin/ directories,
# in order, joined by ':'. No Nix build starts.
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
fail() {
  echo "FAIL: $1" >&2
  exit 1
}

mkdir -p "$WORK/bin"
CALLS=$WORK/calls
export CALLS
# nix: `nix build` prints one store path per installable; `nix eval` answers the system
cat >"$WORK/bin/nix" <<'EOF'
#!/bin/sh
echo "nix $*" >>"$CALLS"
case " $* " in
*" build "*)
  [ "${FAKE_BUILD:-}" = fail ] && { echo "error: build failed" >&2; exit 1; }
  for a in "$@"; do
    case "$a" in packages.*) echo "/nix/store/0000-${a##*.}" ;; esac
  done
  ;;
*" eval "*) echo '"x86_64-linux"' ;;
esac
EOF
# nix-build and nix-instantiate stand for the classic tools, which must not be needed
for t in nix-build nix-instantiate; do
  cat >"$WORK/bin/$t" <<EOF
#!/bin/sh
echo "$t \$*" >>"\$CALLS"
echo "Assertion 'maybeOutputPath' failed" >&2
exit 134
EOF
done
chmod +x "$WORK/bin/"*
PATH="$WORK/bin:$PATH"

. "$ROOT/scripts/tools.sh"

: >"$CALLS"
out=$(tools_path "$ROOT" systemd mtools) || fail "tools_path failed: $(cat "$CALLS")"
[ "$out" = "/nix/store/0000-systemd/bin:/nix/store/0000-mtools/bin" ] || fail "got '$out'"
grep -q '^nix .*build .*--print-out-paths' "$CALLS" || fail "no nix build: $(cat "$CALLS")"
grep -q -- "-f $ROOT" "$CALLS" || fail "not built from the checkout: $(cat "$CALLS")"
if grep -q '^nix-build\|^nix-instantiate' "$CALLS"; then fail "classic tool called: $(cat "$CALLS")"; fi

# a failed build is a failure, with nothing printed
: >"$CALLS"
if out=$(FAKE_BUILD=fail tools_path "$ROOT" systemd 2>/dev/null); then fail "a failed build passed"; fi
[ -z "$out" ] || fail "a failed build printed '$out'"

echo "tools.sh: ok"
