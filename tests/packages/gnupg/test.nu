# gnupg as the signed update index uses it: make a key, sign SHA256SUMS, and check the signature
# with the argv systemd-pull uses (systemd v262 src/import/pull-common.c, pull_verify). The check
# must pass for the file and fail for the file with one byte changed. Making the key also starts
# gpg-agent, which gpg finds in the package it runs from: the test shows that process came from
# $pkg/bin. PATH holds only the seed, so every tool is called by its path in the package.
use checks.nu *
let bin = $"($env.pkg)/bin"
let t = $"($env.TMPDIR? | default /tmp)/gnupg-test"
rm -rf $t
mkdir $t
cd $t

assert "version is the pin" ((^$"($bin)/gpg" --version | lines | first) | str contains "2.4.9")

# 1. a signing key in a scratch home (short path: the agent socket lives in it), the public key in
# binary form, and the index with its detached binary signature
let home = $"($t)/h"
mkdir $home
^chmod 700 $home
with-env {GNUPGHOME: $home} {
  let gen = (^$"($bin)/gpg" --batch --passphrase '' --quick-gen-key index@golconda.invalid ed25519 sign never | complete)
  assert $"quick-gen-key succeeds: ($gen.stderr)" ($gen.exit_code == 0)

  # gpg started the agent from its own package, not from a compiled-in prefix
  let pid = (^$"($bin)/gpg-connect-agent" "getinfo pid" /bye | lines | first | str replace "D " "" | str trim)
  let exe = (^readlink $"/proc/($pid)/exe" | str trim)
  assert $"gpg-agent runs from the package: ($exe)" ($exe == $"($bin)/.gpg-agent")
  let dirs = (^$"($bin)/gpgconf" --list-dirs | lines)
  assert "gpgconf bindir is the package's bin" ($dirs | any {|l| $l == $"bindir:($bin)" })
  assert "gpgconf libexecdir is the package's libexec" ($dirs | any {|l| $l == $"libexecdir:($env.pkg)/libexec" })

  ^$"($bin)/gpg" --batch --export --output $"($t)/kr.pgp"
  assert "kr.pgp is a binary key, not armor" (not ((open --raw $"($t)/kr.pgp" | into binary | first 5 | decode utf-8) | str contains "-----"))

  # a stand-in release file; the line is what sha256sum prints
  "release payload\n" | save -f $"($t)/golconda_1.raw.xz"
  let sum = (open --raw $"($t)/golconda_1.raw.xz" | hash sha256)
  $"($sum)  golconda_1.raw.xz\n" | save -f $"($t)/SHA256SUMS"
  let sign = (^$"($bin)/gpg" --batch --yes --detach-sign --output $"($t)/SHA256SUMS.gpg" $"($t)/SHA256SUMS" | complete)
  assert $"detach-sign succeeds: ($sign.stderr)" ($sign.exit_code == 0)

  ^$"($bin)/gpgconf" --kill gpg-agent
}

# 2 and 3. the verification as systemd-pull runs it: an empty --homedir, a copy of the keyring, the
# signature as a file and the signed data on stdin. The caller's GNUPGHOME is not set
def verify [data: string]: nothing -> record {
  let home = $"($t)/verify-home"
  rm -rf $home
  mkdir $home
  ^chmod 700 $home
  ^cp $"($t)/kr.pgp" $"($t)/kr-copy.pgp"
  $data | ^$"($bin)/gpg" --no-options --no-default-keyring --no-auto-key-locate --no-auto-check-trustdb --batch --trust-model=always --auto-key-import --import-options=merge-only,import-clean $"--homedir=($home)" $"--keyring=($t)/kr-copy.pgp" --verify $"($t)/SHA256SUMS.gpg" - | complete
}
let sums = (open --raw $"($t)/SHA256SUMS")

let good = (verify $sums)
print $good.stderr
assert $"the signed index verifies: ($good.stderr)" ($good.exit_code == 0)
assert "gpg reports a good signature" ($good.stderr | str contains "Good signature")

# the first hex digit of the hash, changed to another
let first = ($sums | str substring 0..<1)
let tampered = $"(if $first == 'a' { 'b' } else { 'a' })($sums | str substring 1..)"
assert "the tampered index differs by one byte" (($tampered | str length) == ($sums | str length) and $tampered != $sums)
let bad = (verify $tampered)
print $bad.stderr
assert $"a tampered index is refused: ($bad.stderr)" ($bad.exit_code != 0)
assert "gpg reports a bad signature" ($bad.stderr | str contains "BAD signature")

cd /
rm -rf $t
done
