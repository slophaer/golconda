# The image chain over one system, the code behind `lib.mkImage` and the test images of
# nix/default.nix: Nix builds every artifact unsigned, and the signer (lib/image/sign.nu) signs
# and assembles the release outside the store (docs/design/trust.md, "Signing outside Nix").
#
# `import ./chain.nix { inherit sources mkSystem imageLib; }` is the function of
# { config; publicKeys; pcrPublicKeys ? publicKeys; indexPublicKeys ? publicKeys;
#   system ? builtins.currentSystem; } below. It returns
#   unsigned            what the signer takes (lib/image/manifest.nix): manifest.json, the public
#                       halves, and `sign`, the signer of this image's package set
#   usrTree, initrd     the /usr tree (without the signed loader) and the initrd, as `unsigned`
#                       names them
#   signer              the signer program (lib/image/signer.nix)
#   pkgs                the image's package set
#   imageId, version    the system's /system name and version
#   signWithTestKeys    { keys; pcrKeys ? keys; indexKeys ? keys; } → the release signed in the
#                       store with throwaway keys, for tests and examples only
#   signWithTestToken   the same, with the db and PCR keys on a SoftHSM token (PKCS#11), for tests
#
# The public halves, in scripts/make-keys' layout, are all the chain reads of a key set:
#   secureboot/db.crt   the db certificate: the signer signs with its key; without Secure Boot
#                       the kernel carries it (lib/system.nix verityCert)
#   pcr/pcr.pub         the PCR policy key, the UKI's .pcrpkey
#   release/index.pgp   the release key (binary OpenPGP), the image's keyring for Verify=yes
# `publicKeys` names the directory: a path (./keys) or an absolute string ("/srv/keys"); each of
# the three files is copied into the store alone, so a directory that holds the private keys too
# copies none of them. Or a derivation of public halves (throwawayKeys …).public. `pcrPublicKeys`
# and `indexPublicKeys` name other directories, read for pcr/ and release/ only: a db rotation
# keeps the PCR key and the release key (image-smoke-test-rotated).
{
  sources,
  mkSystem,
  imageLib,
}:
args:
let
  inherit (builtins)
    attrNames
    baseNameOf
    concatStringsSep
    hasContext
    isAttrs
    isPath
    isString
    readFile
    removeAttrs
    replaceStrings
    substring
    ;
  unknown = attrNames (
    removeAttrs args [
      "config"
      "publicKeys"
      "pcrPublicKeys"
      "indexPublicKeys"
      "system"
    ]
  );
  checked =
    if unknown != [ ] then
      throw "golconda: mkImage: unknown argument ${concatStringsSep ", " unknown}; it takes config, publicKeys, pcrPublicKeys, indexPublicKeys and system, and no private key (docs/reference/outputs.md)"
    else
      args;
  inherit (checked) config;
  system = args.system or builtins.currentSystem;
  publicKeys =
    args.publicKeys
      or (throw "golconda: mkImage needs publicKeys, the directory of the key set's public halves (docs/reference/outputs.md)");
  pcrPublicKeys = args.pcrPublicKeys or publicKeys;
  indexPublicKeys = args.indexPublicKeys or publicKeys;

  # one public file of a key set: a path or an absolute string is copied alone; a derivation (of
  # public halves) is named
  publicFile =
    dir: rel:
    if isPath dir then
      copyPublic (dir + "/${rel}") rel
    else if isAttrs dir || (isString dir && hasContext dir) then
      "${dir}/${rel}"
    else if isString dir && substring 0 1 dir == "/" then
      copyPublic "${dir}/${rel}" rel
    else
      throw "golconda: mkImage: a key directory must be a path or an absolute string, not '${toString dir}'";
  # The PEM files are read before the copy, so a private key never reaches the store. The
  # keyring is binary, which readFile cannot read: lib/image/manifest.nu checks it in the build
  copyPublic =
    path: rel:
    if
      rel != "release/index.pgp"
      && replaceStrings [ "PRIVATE KEY" ] [ "" ] (readFile path) != readFile path
    then
      throw "golconda: mkImage: ${toString path} holds a private key; give only the public half (scripts/make-keys writes it)"
    else
      builtins.path {
        inherit path;
        name = baseNameOf rel;
      };
  dbCert = publicFile publicKeys "secureboot/db.crt";
  pcrPublicKey = publicFile pcrPublicKeys "pcr/pcr.pub";
  indexPublicKey = publicFile indexPublicKeys "release/index.pgp";

  # the configuration's downstream directories ([golconda]): its packages replace for the
  # signer, the keyring and the initrd as for the system
  project = (import ../config.nix { tree = null; }).readProject config;
  # the same set default.nix argsFun hands to `packages`
  inherit
    (import ../../nix/packages.nix {
      inherit sources system;
      platform = system;
      downstream = project.packages;
      inherit (project) replaces;
    })
    pkgs
    platform
    ;
  indexKeyring = imageLib.indexKeyring {
    inherit pkgs;
    buildSystem = system;
    publicKey = indexPublicKey;
  };
  sys = mkSystem {
    inherit system config;
    platform = system;
    verityCert = dbCert;
    extraFragments = [
      (imageLib.indexFragment {
        keyring = indexKeyring;
        inherit pkgs;
      })
    ];
  };
  stepArgs = {
    imageId = sys.name;
    inherit (sys) version platform pkgs;
    buildSystem = system;
  };
  initrd = imageLib.initrd (
    stepArgs
    // {
      # not sys.usrTree
      usrTree = imageLib.initrdTree (
        stepArgs
        // {
          packagesDir = project.packages;
          inherit (project) replaces;
          inherit sources;
          inherit (sys.composed) secureBoot;
        }
      );
    }
  );
  signer = imageLib.signer {
    inherit pkgs;
    buildSystem = system;
  };
  unsigned = imageLib.manifest (
    stepArgs
    // {
      inherit (sys) usrTree;
      inherit (sys.composed) secureBoot;
      microsoftKeys = sys.composed.secureBootMicrosoftKeys;
      inherit initrd signer;
      publicKeys = {
        inherit dbCert pcrPublicKey;
        indexKeyring = indexPublicKey;
      };
      # No cmdlineExtra: every image boots the production cmdline (image/uki.nix carries `rw`,
      # so the root is writable before the ssh host key var runs). To watch a boot:
      # cmdlineExtra = "systemd.log_level=debug systemd.log_target=console
      # systemd.journald.forward_to_console=1";
    }
  );
in
{
  inherit
    unsigned
    initrd
    signer
    pkgs
    ;
  inherit (sys) usrTree version;
  imageId = sys.name;
  signWithTestKeys =
    {
      keys,
      pcrKeys ? keys,
      indexKeys ? keys,
    }:
    imageLib.signedWithTestKeys {
      name = "${sys.name}_${sys.version}.test-signed";
      inherit
        unsigned
        keys
        pcrKeys
        indexKeys
        ;
      buildSystem = system;
    };
  signWithTestToken =
    {
      keys,
      pcrKeys ? keys,
      indexKeys ? keys,
    }:
    imageLib.signedWithTestToken {
      name = "${sys.name}_${sys.version}.token-signed";
      inherit
        unsigned
        keys
        pcrKeys
        indexKeys
        pkgs
        ;
      buildSystem = system;
    };
}
