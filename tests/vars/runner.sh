#!/bin/sh
# The var runner (modules/vars/golconda-var-run) without a machine: a stub systemd-creds on PATH
# records what it was asked to seal, and GOLCONDA_CREDSTORE and GOLCONDA_VARS_D point the runner
# at directories in a scratch tree. Both modes: a local var (generate, seal, publish, done) and
# an admin var (seal what the deploy host pushes on stdin, only if the manifest declares it).
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
RUNNER=$ROOT/modules/vars/golconda-var-run
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
ERRORS=0

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }

# systemd-creds encrypt [options] --name=ID SOURCE TARGET: the stub writes "ID:" and the source
mkdir -p "$WORK/bin"
cat > "$WORK/bin/systemd-creds" <<'EOF'
#!/bin/sh
[ "$1" = encrypt ] || exit 2
shift
name=
for a in "$@"; do case $a in --name=*) name=${a#--name=} ;; esac; done
eval "src=\${$(($# - 1))}"
eval "dst=\${$#}"
case $src in -) body=$(cat) ;; *) body=$(cat "$src") ;; esac
printf '%s:%s' "$name" "$body" > "$dst"
EOF
chmod +x "$WORK/bin/systemd-creds"
export PATH="$WORK/bin:$PATH"
export GOLCONDA_CREDSTORE="$WORK/credstore" GOLCONDA_VARS_D="$WORK/vars.d"
mkdir -p "$GOLCONDA_VARS_D"

# the manifests mkSystem writes (modules/lib/var.nix), as builtins.toJSON prints them
printf '%s' '{"class":"admin","consumers":["sshd.service"],"credentials":["sshd-host-cert.cert"],"files":["cert"],"name":"sshd-host-cert"}' \
  > "$GOLCONDA_VARS_D/sshd-host-cert.json"
printf '%s' '{"after":[],"class":"local","credentials":["foo.key"],"name":"foo","publics":["key.pub"],"secrets":["key"]}' \
  > "$GOLCONDA_VARS_D/foo.json"
printf '%s\n' 'echo secret > key' 'echo public > key.pub' > "$GOLCONDA_VARS_D/foo.sh"

# --- admin: seal the pushed value ---
st=0
printf 'CERT' | sh "$RUNNER" --admin sshd-host-cert cert > "$WORK/out" 2>&1 || st=$?
check "admin: seals a declared file from stdin" \
  '[ "$st" = 0 ] && [ "$(cat "$GOLCONDA_CREDSTORE/sshd-host-cert.cert")" = "sshd-host-cert.cert:CERT" ]'
check "admin: no temporary file is left" \
  '[ "$(ls -A "$GOLCONDA_CREDSTORE")" = "sshd-host-cert.cert" ]'
check "admin: the credential store is private" \
  '[ "$(stat -c %a "$GOLCONDA_CREDSTORE/sshd-host-cert.cert")" = 600 ]'

printf 'NEW' | sh "$RUNNER" --admin sshd-host-cert cert > /dev/null 2>&1
check "admin: a second push replaces the value (rotation)" \
  '[ "$(cat "$GOLCONDA_CREDSTORE/sshd-host-cert.cert")" = "sshd-host-cert.cert:NEW" ]'

refused() { # refused LABEL ARGS...: the runner exits non-zero and seals nothing new
  label=$1; shift
  before=$(ls -A "$GOLCONDA_CREDSTORE")
  st=0
  printf 'X' | sh "$RUNNER" "$@" > "$WORK/out" 2>&1 || st=$?
  if [ "$st" != 0 ] && [ "$(ls -A "$GOLCONDA_CREDSTORE")" = "$before" ]; then
    pass "$label"
  else
    fail "$label (exit $st)"; cat "$WORK/out"
  fi
}
refused "admin: refuses a file the manifest does not declare" --admin sshd-host-cert key
refused "admin: refuses a var with no manifest" --admin nope cert
refused "admin: refuses a local var" --admin foo key
refused "admin: refuses a path as a name" --admin ../sshd-host-cert cert
refused "admin: refuses a path as a file" --admin sshd-host-cert ../cert
refused "admin: needs a name and a file" --admin sshd-host-cert

# --- local: generate, seal, publish, done (unchanged behaviour) ---
mkdir -p "$WORK/run" "$WORK/state"
st=0
RUNTIME_DIRECTORY=$WORK/run STATE_DIRECTORY=$WORK/state sh "$RUNNER" foo key key.pub > "$WORK/out" 2>&1 || st=$?
check "local: seals the secret" \
  '[ "$st" = 0 ] && [ "$(cat "$GOLCONDA_CREDSTORE/foo.key")" = "foo.key:secret" ]'
check "local: publishes the public file and marks done" \
  '[ "$(cat "$WORK/state/pub/key.pub")" = public ] && [ -e "$WORK/state/done" ]'
check "local: removes the plaintext" '[ -z "$(ls -A "$WORK/run")" ]'

if [ "$ERRORS" -gt 0 ]; then
  echo "$ERRORS failed"
  exit 1
fi
echo "all passed"
