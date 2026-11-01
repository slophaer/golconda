# Checks of /system.secureBoot = false: the db certificate in the kernel's built-in keyring.
# A function of the harness (./harness.nix); it returns a list of checks.
{
  check,
  mkSystemFixture,
  platform,
  sources,
  ...
}:
# /system.secureBoot = false: a host without Secure Boot. The kernel carries the db
# certificate in its built-in keyring, so dm-verity checks the /usr signature without the
# firmware's db; the kernel of the set changes, so /usr and the UKI carry the same one
# (docs/design/trust.md).
let
  inherit (builtins) deepSeq filter tryEval;
  sysWith =
    extraSystem: verityCert:
    import ../../lib/system.nix {
      inherit sources platform verityCert;
      system = platform;
      config = {
        "/system" = {
          name = "test";
          version = "20261031.1";
        }
        // extraSystem;
      };
    };
  trusted =
    sys:
    let
      k = builtins.head (filter (p: (p.pname or "") == "linux-kernel") sys.composed.packages);
    in
    k.spec.kbuild.config.SYSTEM_TRUSTED_KEYS or null;
  cert = "/srv/keys/secureboot/db.crt";
in
[
  (check "secureBoot: on by default, and the kernel has no built-in key" (
    trusted (sysWith { } cert) == null && trusted mkSystemFixture == null
  ))
  (check "secureBoot: false puts the db certificate into the kernel's built-in keyring" (
    trusted (sysWith { secureBoot = false; } cert) == cert
    &&
      (sysWith { secureBoot = false; } cert).pkgs.linux-kernel.spec.kbuild.config.SYSTEM_TRUSTED_KEYS
      == cert
  ))
  (check "secureBoot: false without the image's keys is an error" (
    !(tryEval (deepSeq (trusted (sysWith { secureBoot = false; } null)) true)).success
  ))
]
