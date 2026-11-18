# Checks of the db certificate in the kernel's built-in keyring, with Secure Boot and without.
# A function of the harness (./harness.nix); it returns a list of checks.
{
  check,
  composeWith,
  hasInfix,
  imageLib,
  mkSystemFixture,
  platform,
  sources,
  ...
}:
# Every kernel of an image carries the db certificate in its built-in keyring, the one key
# dm-verity and IPE trust: the firmware's db (the platform keyring) holds Microsoft's UEFI CAs by
# default, and a host without Secure Boot (/system.secureBoot = false) has none. The kernel of the
# set changes, so /usr and the UKI carry the same one (docs/design/trust.md).
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
  (check "secureBoot: on by default, and the kernel carries the db certificate" (
    let
      sys = sysWith { } cert;
    in
    trusted sys == fixed
    && (extraOf sys.pkgs.linux-kernel.spec.env).SYSTEM_TRUSTED_KEYS == fixed
    && (filesOf (kernelOf sys).spec.env).${fixed} == cert
  ))
  (check "secureBoot: false puts the db certificate into the kernel's built-in keyring" (
    let
      sys = sysWith { secureBoot = false; } cert;
    in
    trusted sys == fixed
    && (extraOf sys.pkgs.linux-kernel.spec.env).SYSTEM_TRUSTED_KEYS == fixed
    && (filesOf (kernelOf sys).spec.env).${fixed} == cert
  ))
  # one kernel per key set, Secure Boot or not: the config is the same for both, the file differs
  (check "secureBoot: on and off give the same kernel config" (
    configOf (sysWith { } storeCert) == configOf (sysWith { secureBoot = false; } storeCert)
  ))
  (check "secureBoot: false with a store certificate keeps it an input of the kernel" (
    let
      env = (kernelOf (sysWith { secureBoot = false; } storeCert)).spec.env;
    in
    (filesOf env).${fixed} == storeCert && builtins.hasContext env.GOLCONDA_KERNEL_FILES
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
  # the kernel belongs in the UKI only: the initrd's tree has none
  (check "secureBoot: false keeps every kernel out of the initrd's tree" (
    let
      sys = sysWith { secureBoot = false; } storeCert;
      tree = (import ../../lib/image { }).initrdTree {
        inherit (sys) composed version;
        inherit sources;
        platform.name = platform;
        buildSystem = platform;
      };
    in
    !(builtins.any (p: (p.pname or "") == "linux-kernel") tree.drvAttrs.roots)
  ))
  # the vars' TPM2 policy (modules/vars/golconda-var-run reads vars.d/tpm2-pcrs): PCR 7 by value
  # besides the signed PCR 11 policy, so Secure Boot off or other Secure Boot keys unseal nothing
  (check "secureBoot: the vars are sealed to PCR 7 too" (
    (composeWith { }).files."/usr/lib/golconda/vars.d/tpm2-pcrs" == {
      text = "7\n";
      mode = "0644";
    }
  ))
  (check "secureBoot: false keeps the signed PCR 11 policy alone" (
    !(
      (composeWith {
        "/system" = {
          name = "t";
          version = "20261031.1";
          secureBoot = false;
        };
      }).files
        ? "/usr/lib/golconda/vars.d/tpm2-pcrs"
    )
  ))
  # the initrd of a Secure Boot image halts when the firmware does not enforce Secure Boot
  # (docs/design/boot.md, "Secure Boot off"); an image with secureBoot = false has no such unit
  (check "secureBoot: the initrd halts when Secure Boot is off" (
    let
      initrdOf = sys: imageLib.initrdComposition { inherit (sys) composed; };
      refuse = "golconda-secure-boot-required.service";
      on = initrdOf (sysWith { } storeCert);
      off = initrdOf (sysWith { secureBoot = false; } storeCert);
      unit = on.units.${refuse};
    in
    hasInfix "ConditionSecurity=!uefi-secureboot" unit
    && hasInfix "SuccessAction=halt-force\n" unit
    && hasInfix "FailureAction=halt-force\n" unit
    && hasInfix "Before=sysinit.target" unit
    && on.links."/usr/lib/systemd/system/sysinit.target.wants/${refuse}".target == "../${refuse}"
    && !(off.units ? ${refuse})
  ))
  (check "secureBoot: false without the image's keys is an error" (
    !(tryEval (deepSeq (kernelOf (sysWith { secureBoot = false; } null)).spec.env true)).success
  ))
  # a system that no image signs (lib.mkSystem alone: a /usr tree, the SBOM) has no db
  # certificate: its kernel trusts no key, so no /usr signature would verify
  (check "secureBoot: a system without the image's keys has a kernel with no built-in key" (
    trusted (sysWith { } null) == null
    && trusted mkSystemFixture == null
    && !(filesOf (kernelOf (sysWith { } null)).spec.env ? ${fixed})
  ))
]
