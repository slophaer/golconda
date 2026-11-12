# signer.nu: the program golconda-sign (lib/image/signer.nix): a shell script that runs
# sign-main.nu under the seed's nu, with the signing tools on PATH, pkcs11-provider in
# OPENSSL_MODULES and nothing else of the caller's environment but HOME and TMPDIR. So the
# signer sees the same tools on the release host as in the build sandbox, where the test images
# are signed.

use common.nu *

# the directory of the builder's .nu files, sign-main.nu among them
const builder_tree = (path self | path dirname)

export def build [] {
  let a = (attrs)
  let out = $a.outputs.out
  $env.PATH = $a.PATH
  let nu_exe = $nu.current-exe
  let tree = $builder_tree
  let sh = ($nu_exe | path dirname | path join sh)
  mkdir $"($out)/bin"
  let program = $"($out)/bin/golconda-sign"
  [
    $"#!($sh)"
    "# golconda-sign: the signer of Golconda's image chain (lib/image/sign.nu)"
    # SOFTHSM2_CONF: where the token of the test images is (lib/image/token.nu); a YubiKey's
    # module needs no variable
    $"exec ($nu_exe | path dirname | path join env) -i HOME=\"$HOME\" TMPDIR=\"${TMPDIR:-/tmp}\" OPENSSL_CONF=/dev/null ${SOFTHSM2_CONF:+\"SOFTHSM2_CONF=$SOFTHSM2_CONF\"} \\"
    $"  PATH='($a.PATH)' OPENSSL_MODULES='($a.opensslModules)' \\"
    $"  LD_LIBRARY_PATH='($a.LD_LIBRARY_PATH)' \\"
    $"  ($nu_exe) --no-config-file '--include-path=($tree)' '--experimental-options=[cell-path-types]' \\"
    $"  ($tree)/sign-main.nu \"$@\""
  ] | str join "\n" | $"($in)\n" | save -f $program
  ^chmod 0555 $program
  log $"bin/golconda-sign: nu ($nu_exe), ($tree)/sign-main.nu"
}
