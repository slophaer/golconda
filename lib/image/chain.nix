# The image chain over one system, the code behind `lib.mkImage` and the smoke outputs of
# nix/default.nix: signed loader, system, erofs, verity, initrd, UKI, disk and smoke
# (the steps are lib/image/*.nix).
#
# `import ./chain.nix { inherit sources mkSystem imageLib; }` is the function of
# { config; keys; pcrKeys ? keys; indexKeys ? keys; system ? builtins.currentSystem; }
# below. mkImage in nix/default.nix drops its `smoke`.
#
# The signed loader comes first: the /usr tree carries it (lib/image/loader.nix
# loaderFragment), and the disk step checks that the ESP gets the same file.
#
# The key layout, the only one the chain reads, relative to `keys`:
#   secureboot/db.key, secureboot/db.crt  sign the loader, the UKI and the verity root hash
#                                         (the kernel checks that signature against the
#                                         firmware db, docs/design/trust.md)
#   pcr/pcr.key, pcr/pcr.pub              sign the PCR 11 policy; pcr.pub is the UKI's .pcrpkey
#   release/index.key, release/index.pgp  sign SHA256SUMS (OpenPGP, armored secret); the binary
#                                         public key is the image's keyring for Verify=yes
# `pcrKeys` (default `keys`) is a second directory in the same layout, read for pcr/ only: a
# db key rotation keeps the PCR key (image-smoke-test-rotated).
#
# How the private keys reach the sandboxed builder depends on the type of `keys`:
#   - a path (./keys, /srv/keys): Nix copies the whole directory into the store, so the
#     private keys sit in the build host's store, readable by every local user, until a
#     garbage collection removes them. A remote builder gets a copy too.
#   - a string ("/srv/golconda-keys"): nothing is copied; the builder reads the files where
#     they are, so the daemon must let the sandbox see them (extra-sandbox-paths in the
#     daemon's nix.conf, docs/reference/build-host.md). The derivations name only the path,
#     so new keys under the same path do not rebuild anything: give new keys a new path.
#   - a derivation (throwawayKeys): keys made in the store, for the smoke outputs only.
# `smoke` (lib/image/smoke.nix) links its `keys`; only the image-smoke outputs use it.
{
  sources,
  mkSystem,
  imageLib,
}:
{
  config,
  keys,
  pcrKeys ? keys,
  indexKeys ? keys,
  system ? builtins.currentSystem,
}:
let
  # a relative string would name a path inside the build sandbox
  absolute =
    k:
    if builtins.isString k && builtins.substring 0 1 k != "/" then
      throw "golconda: mkImage: a key directory must be an absolute path, not '${k}'"
    else
      k;
  checkedKeys = absolute keys;
  # the same set default.nix argsFun hands to `packages`: the loader is built before the system
  inherit
    (import ../../nix/packages.nix {
      inherit sources system;
      platform = system;
    })
    pkgs
    platform
    ;
  sbKey = "${checkedKeys}/secureboot/db.key";
  sbCert = "${checkedKeys}/secureboot/db.crt";
  loader = imageLib.loader {
    inherit
      pkgs
      platform
      sbKey
      sbCert
      ;
    buildSystem = system;
  };
  # the release key: its public half is the image's keyring, its secret half signs SHA256SUMS
  indexDir = absolute indexKeys;
  indexKeyring = imageLib.indexKeyring {
    inherit pkgs;
    buildSystem = system;
    publicKey = "${indexDir}/release/index.pgp";
  };
  sys = mkSystem {
    inherit system config;
    platform = system;
    verityCert = sbCert;
    extraFragments = [
      (imageLib.loaderFragment { inherit loader platform; })
      (imageLib.indexFragment {
        keyring = indexKeyring;
        inherit pkgs;
      })
    ];
  };
  args = {
    imageId = sys.name;
    inherit (sys) version platform pkgs;
    buildSystem = system;
  };
  erofs = imageLib.erofs (args // { inherit (sys) usrTree; });
  verity = imageLib.verity (
    args
    // {
      inherit erofs;
      key = sbKey;
      cert = sbCert;
    }
  );
  initrd = imageLib.initrd (args // { usrTree = imageLib.initrdTree args; }); # not sys.usrTree
  uki = imageLib.uki (
    args
    // {
      inherit
        initrd
        verity
        sbKey
        sbCert
        ;
      inherit (sys) usrTree;
      pcrKey = "${absolute pcrKeys}/pcr/pcr.key";
      pcrPublicKey = "${absolute pcrKeys}/pcr/pcr.pub";
      # No cmdlineExtra: every image boots the production cmdline (image/uki.nix carries
      # `rw`, so the root is writable before the ssh host key var runs). To watch a boot:
      # cmdlineExtra = "systemd.log_level=debug systemd.log_target=console
      # systemd.journald.forward_to_console=1";
    }
  );
  disk = imageLib.disk (
    args
    // {
      inherit
        erofs
        verity
        uki
        loader
        ;
      inherit (sys) usrTree;
      indexKey = "${indexDir}/release/index.key";
    }
  );
in
{
  inherit
    erofs
    verity
    initrd
    uki
    loader
    disk
    ;
  # what sysupdate fetches: the four files and SHA256SUMS (docs/design/releases.md)
  release = "${disk}/release";
  smoke = imageLib.smoke (
    args
    // {
      inherit
        erofs
        verity
        initrd
        uki
        disk
        ;
      keys = checkedKeys;
    }
  );
}
