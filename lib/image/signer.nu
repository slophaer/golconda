# signer.nu: the programs golconda-sign and golconda-enrol-auth (lib/image/signer.nix): a shell
# script that runs sign-main.nu (or the attrs' `main`) under the seed's nu, with the tools on
# PATH, pkcs11-provider in OPENSSL_MODULES, the attrs' `programEnv` and nothing else of the
# caller's environment but HOME and TMPDIR. So the program sees the same tools on the release
# host as in the build sandbox, where the test images are signed.

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
  let name = ($a.program? | default "golconda-sign")
  let main = ($a.main? | default "sign-main.nu")
  let extra = ($a.programEnv? | default {} | transpose k v | each {|e| $"($e.k)='($e.v)' " } | str join "")
  mkdir $"($out)/bin"
  let program = $"($out)/bin/($name)"
  [
    $"#!($sh)"
    $"# ($name): ($a.description? | default "the signer of Golconda's image chain \(lib/image/sign.nu\)")"
    # SOFTHSM2_CONF: where the token of the test images is (lib/image/token.nu); a YubiKey's
    # module needs no variable
    $"exec ($nu_exe | path dirname | path join env) -i HOME=\"$HOME\" TMPDIR=\"${TMPDIR:-/tmp}\" OPENSSL_CONF=/dev/null ${SOFTHSM2_CONF:+\"SOFTHSM2_CONF=$SOFTHSM2_CONF\"} \\"
    $"  PATH='($a.PATH)' OPENSSL_MODULES='($a.opensslModules)' ($extra)\\"
    $"  LD_LIBRARY_PATH='($a.LD_LIBRARY_PATH)' \\"
    $"  ($nu_exe) --no-config-file '--include-path=($tree)' '--experimental-options=[cell-path-types]' \\"
    $"  ($tree)/($main) \"$@\""
  ] | str join "\n" | $"($in)\n" | save -f $program
  ^chmod 0555 $program
  log $"bin/($name): nu ($nu_exe), ($tree)/($main)"
}
