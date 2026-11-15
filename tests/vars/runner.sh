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

# systemd-creds encrypt [options] --name=ID SOURCE TARGET: the stub writes "ID:" and the source,
# and logs the options to $CREDS_LOG. systemd-creds decrypt --name=ID SOURCE TARGET: the body of
# a credential the stub wrote, when ID is its name; the body BAD does not decrypt.
# systemd-creds has-tpm2: true when STUB_TPM2 is set. systemd-cat -p PRIORITY: the line and its
# priority in $JOURNAL
mkdir -p "$WORK/bin"
cat > "$WORK/bin/systemd-cat" <<'EOF'
#!/bin/sh
prio=info
while [ $# -gt 0 ]; do
  case $1 in -p) prio=$2; shift ;; esac
  shift
done
sed "s/^/$prio: /" >> "$JOURNAL"
EOF
cat > "$WORK/bin/systemd-creds" <<'EOF'
#!/bin/sh
cmd=$1
shift
[ "$cmd" = has-tpm2 ] && { [ -n "${STUB_TPM2:-}" ]; exit; }
name=
opts=
for a in "$@"; do
  case $a in
    --name=*) name=${a#--name=} ;;
    --*) opts="$opts $a" ;;
  esac
done
eval "src=\${$(($# - 1))}"
eval "dst=\${$#}"
case $cmd in
  encrypt)
    echo "encrypt $name$opts" >> "$CREDS_LOG"
    case $src in -) body=$(cat) ;; *) body=$(cat "$src") ;; esac
    printf '%s:%s' "$name" "$body" > "$dst"
    ;;
  decrypt)
    c=$(cat "$src")
    [ "${c%%:*}" = "$name" ] && [ "${c#*:}" != BAD ] || exit 1
    printf '%s' "${c#*:}" > "$dst"
    ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$WORK/bin/systemd-creds" "$WORK/bin/systemd-cat"
export PATH="$WORK/bin:$PATH"
export GOLCONDA_CREDSTORE="$WORK/credstore" GOLCONDA_VARS_D="$WORK/vars.d" CREDS_LOG="$WORK/creds.log"
export JOURNAL="$WORK/journal"
# the reseal's plaintext directory (/run on a machine)
export TMPDIR="$WORK"
mkdir -p "$GOLCONDA_VARS_D"

# the manifests mkSystem writes (modules/lib/var.nix), as builtins.toJSON prints them
printf '%s' '{"class":"admin","consumers":["sshd.service"],"credentials":["sshd-host-cert.cert"],"files":["cert"],"name":"sshd-host-cert"}' \
  > "$GOLCONDA_VARS_D/sshd-host-cert.json"
printf 'cert\n' > "$GOLCONDA_VARS_D/sshd-host-cert.admin"
# an admin var whose files are a prefix and a suffix of another name: a file must match a whole line
printf '%s' '{"class":"admin","consumers":[],"credentials":["pair.cert-chain"],"files":["cert-chain"],"name":"pair"}' \
  > "$GOLCONDA_VARS_D/pair.json"
printf 'cert-chain\n' > "$GOLCONDA_VARS_D/pair.admin"
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
refused "admin: a file matches a whole line of NAME.admin, not a part" --admin pair cert
refused "admin: a file matches a whole line of NAME.admin, not more" --admin pair cert-chain-2
mv "$GOLCONDA_VARS_D/sshd-host-cert.admin" "$WORK/sshd-host-cert.admin"
refused "admin: a var without NAME.admin is not an admin var" --admin sshd-host-cert cert
mv "$WORK/sshd-host-cert.admin" "$GOLCONDA_VARS_D/sshd-host-cert.admin"

# --- no TPM2: the seal goes on, to the host key alone, and the journal says so ---
check "no TPM2: every seal logs a warning" \
  'grep -qx "warning: golconda-var-run: no TPM2: sshd-host-cert.cert is sealed to the host key alone (docs/features/vars.md)" "$JOURNAL"'
: > "$JOURNAL"
printf 'CERT' | STUB_TPM2=1 sh "$RUNNER" --admin sshd-host-cert cert > /dev/null 2>&1
check "TPM2: no warning" '[ ! -s "$JOURNAL" ]'

# --- local: generate, seal, publish, done (unchanged behaviour) ---
mkdir -p "$WORK/run" "$WORK/state"
st=0
RUNTIME_DIRECTORY=$WORK/run STATE_DIRECTORY=$WORK/state sh "$RUNNER" foo key key.pub > "$WORK/out" 2>&1 || st=$?
check "local: seals the secret" \
  '[ "$st" = 0 ] && [ "$(cat "$GOLCONDA_CREDSTORE/foo.key")" = "foo.key:secret" ]'
check "local: publishes the public file and marks done" \
  '[ "$(cat "$WORK/state/pub/key.pub")" = public ] && [ -e "$WORK/state/done" ]'
check "local: removes the plaintext" '[ -z "$(ls -A "$WORK/run")" ]'

# --- the TPM2 policy: the signed PCR 11 policy, and PCR 7 by value on a Secure Boot image ---
check "policy: without vars.d/tpm2-pcrs, the signed PCR 11 policy only" \
  'grep -qx "encrypt foo.key --with-key=auto --tpm2-public-key-pcrs=11" "$CREDS_LOG"'
printf '7\n' > "$GOLCONDA_VARS_D/tpm2-pcrs"
: > "$CREDS_LOG"
printf 'CERT' | sh "$RUNNER" --admin sshd-host-cert cert > /dev/null 2>&1
check "policy: vars.d/tpm2-pcrs (a Secure Boot image) binds PCR 7 by value too" \
  'grep -qx "encrypt sshd-host-cert.cert --with-key=auto --tpm2-public-key-pcrs=11 --tpm2-pcrs=7" "$CREDS_LOG"'

# --- reseal: every credential of the store, decrypted and sealed again ---
: > "$CREDS_LOG"
st=0
sh "$RUNNER" --reseal > "$WORK/out" 2>&1 || st=$?
check "reseal: every credential, with the image's policy" \
  '[ "$st" = 0 ] && grep -qx "resealed foo.key" "$WORK/out" && grep -qx "resealed sshd-host-cert.cert" "$WORK/out" &&
   grep -qx "encrypt foo.key --with-key=auto --tpm2-public-key-pcrs=11 --tpm2-pcrs=7" "$CREDS_LOG" &&
   grep -qx "encrypt sshd-host-cert.cert --with-key=auto --tpm2-public-key-pcrs=11 --tpm2-pcrs=7" "$CREDS_LOG"'
check "reseal: the values stay, and no plaintext or temporary file is left" \
  '[ "$(cat "$GOLCONDA_CREDSTORE/foo.key")" = "foo.key:secret" ] &&
   [ "$(cat "$GOLCONDA_CREDSTORE/sshd-host-cert.cert")" = "sshd-host-cert.cert:CERT" ] &&
   [ "$(ls -A "$GOLCONDA_CREDSTORE" | tr "\n" " ")" = "foo.key sshd-host-cert.cert " ] &&
   [ -z "$(ls -d "$WORK"/golconda-reseal.* 2>/dev/null)" ]'
: > "$CREDS_LOG"
st=0
sh "$RUNNER" --reseal --without-pcr7 > "$WORK/out" 2>&1 || st=$?
check "reseal --without-pcr7: the signed PCR 11 policy only" \
  '[ "$st" = 0 ] && grep -qx "encrypt foo.key --with-key=auto --tpm2-public-key-pcrs=11" "$CREDS_LOG" &&
   ! grep -q -- "--tpm2-pcrs" "$CREDS_LOG"'
# until the next --reseal, a push seals without PCR 7 too: PCR 7 changes during a rotation
: > "$CREDS_LOG"
printf 'CERT' | sh "$RUNNER" --admin sshd-host-cert cert > /dev/null 2>&1
check "reseal --without-pcr7: later seals leave PCR 7 out too" \
  'grep -qx "encrypt sshd-host-cert.cert --with-key=auto --tpm2-public-key-pcrs=11" "$CREDS_LOG"'
: > "$CREDS_LOG"
sh "$RUNNER" --reseal > /dev/null 2>&1
printf 'CERT' | sh "$RUNNER" --admin sshd-host-cert cert > /dev/null 2>&1
check "reseal: binds PCR 7 again, for the reseal and for later seals" \
  '[ "$(grep -c -- "--tpm2-pcrs=7" "$CREDS_LOG")" = 3 ] && [ "$(wc -l < "$CREDS_LOG")" = 3 ] &&
   [ "$(ls -A "$GOLCONDA_CREDSTORE" | tr "\n" " ")" = "foo.key sshd-host-cert.cert " ]'
printf 'sshd-host-cert.cert:BAD' > "$GOLCONDA_CREDSTORE/sshd-host-cert.cert"
st=0
sh "$RUNNER" --reseal > "$WORK/out" 2>&1 || st=$?
check "reseal: a credential that does not decrypt fails the run and stays as it was" \
  '[ "$st" != 0 ] && [ "$(cat "$GOLCONDA_CREDSTORE/sshd-host-cert.cert")" = "sshd-host-cert.cert:BAD" ] &&
   [ -z "$(ls -d "$WORK"/golconda-reseal.* 2>/dev/null)" ]'
# a failed --reseal keeps .without-pcr7: some credentials are still sealed without PCR 7
touch "$GOLCONDA_CREDSTORE/.without-pcr7"
st=0
sh "$RUNNER" --reseal > "$WORK/out" 2>&1 || st=$?
check "reseal: a failed run keeps .without-pcr7" \
  '[ "$st" != 0 ] && [ -e "$GOLCONDA_CREDSTORE/.without-pcr7" ]'
st=0
sh "$RUNNER" --reseal --with-pcr8 > "$WORK/out" 2>&1 || st=$?
check "reseal: refuses an unknown option" '[ "$st" = 2 ]'

if [ "$ERRORS" -gt 0 ]; then
  echo "$ERRORS failed"
  exit 1
fi
echo "all passed"
