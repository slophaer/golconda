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
  kernelOf = sys: builtins.head (filter (p: (p.pname or "") == "linux-kernel") sys.composed.packages);
  trusted = sys: (extraOf (kernelOf sys).spec.env).SYSTEM_TRUSTED_KEYS or null;
  extraOf = env: builtins.fromJSON env.GOLCONDA_KERNEL_EXTRA_CONFIG;
  # the JSON keeps the certificate's store context (the build needs the file): drop it to read
  filesOf = env: builtins.fromJSON (builtins.unsafeDiscardStringContext env.GOLCONDA_KERNEL_FILES);
  # the fixed path, relative to the kernel tree, that the config names and the build fills
  fixed = "certs/golconda-verity.pem";
  cert = "/srv/keys/secureboot/db.crt";
  storeCert = "${builtins.toFile "db.crt" "test certificate"}";
  otherCert = "${builtins.toFile "db.crt" "another test certificate"}";
  # everything kconfig reads: a change here regenerates autoconf.h, which every object includes
  configOf =
    sys:
    let
      env = (kernelOf sys).spec.env;
    in
    {
      inherit (env) GOLCONDA_KERNEL_CONFIG GOLCONDA_KERNEL_EXTRA_CONFIG GOLCONDA_KERNEL_FRAGMENTS;
    };
in
[
  (check "secureBoot: on by default, and the kernel has no built-in key" (
    trusted (sysWith { } cert) == null
    && trusted mkSystemFixture == null
    && filesOf (kernelOf (sysWith { } cert)).spec.env == { }
  ))
  (check "secureBoot: false puts the db certificate into the kernel's built-in keyring" (
    let
      sys = sysWith { secureBoot = false; } cert;
    in
    trusted sys == fixed
    && (extraOf sys.pkgs.linux-kernel.spec.env).SYSTEM_TRUSTED_KEYS == fixed
    && filesOf (kernelOf sys).spec.env == { ${fixed} = cert; }
  ))
  (check "secureBoot: false with a store certificate keeps it an input of the kernel" (
    let
      env = (kernelOf (sysWith { secureBoot = false; } storeCert)).spec.env;
    in
    filesOf env == { ${fixed} = storeCert; } && builtins.hasContext env.GOLCONDA_KERNEL_FILES
  ))
  # the jig compile cache keys each object on its inputs: a config with the certificate's store
  # path made every object of the nosb kernel miss whenever the certificate changed
  (check "secureBoot: false keeps the kernel config free of the certificate's store path" (
    let
      c = configOf (sysWith { secureBoot = false; } storeCert);
    in
    !(builtins.hasContext c.GOLCONDA_KERNEL_EXTRA_CONFIG)
    && configOf (sysWith { secureBoot = false; } otherCert) == c
    && configOf (sysWith { secureBoot = false; } cert) == c
  ))
  (check "secureBoot: false without the image's keys is an error" (
    !(tryEval (deepSeq (trusted (sysWith { secureBoot = false; } null)) true)).success
  ))
]
