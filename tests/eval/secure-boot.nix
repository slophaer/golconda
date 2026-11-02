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
    (extraOf k.spec.env).SYSTEM_TRUSTED_KEYS or null;
  # the JSON keeps the certificate's store context (the build needs the file): drop it to read
  extraOf =
    env: builtins.fromJSON (builtins.unsafeDiscardStringContext env.GOLCONDA_KERNEL_EXTRA_CONFIG);
  cert = "/srv/keys/secureboot/db.crt";
  storeCert = "${builtins.toFile "db.crt" "test certificate"}";
in
[
  (check "secureBoot: on by default, and the kernel has no built-in key" (
    trusted (sysWith { } cert) == null && trusted mkSystemFixture == null
  ))
  (check "secureBoot: false puts the db certificate into the kernel's built-in keyring" (
    trusted (sysWith { secureBoot = false; } cert) == cert
    &&
      (extraOf (sysWith { secureBoot = false; } cert).pkgs.linux-kernel.spec.env).SYSTEM_TRUSTED_KEYS
      == cert
  ))
  (check "secureBoot: false with a store certificate keeps its context in the kernel's env" (
    let
      env = (sysWith { secureBoot = false; } storeCert).pkgs.linux-kernel.spec.env;
    in
    trusted (sysWith { secureBoot = false; } storeCert) == storeCert
    && builtins.hasContext env.GOLCONDA_KERNEL_EXTRA_CONFIG
  ))
  (check "secureBoot: false without the image's keys is an error" (
    !(tryEval (deepSeq (trusted (sysWith { secureBoot = false; } null)) true)).success
  ))
]
