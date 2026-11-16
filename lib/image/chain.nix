# The image chain over one system: the code behind `lib.mkImage` and the test images of
# nix/default.nix. Nix builds every artifact unsigned; the signer (lib/image/sign.nu) signs and
# assembles the release outside the store (docs/design/trust.md, "Signing outside Nix").
#
# `import ./chain.nix { inherit sources mkSystem imageLib; }` is the function of
# { config; publicKeys; pcrPublicKeys ? publicKeys; indexPublicKeys ? publicKeys; system ? ...; }.
# It returns `unsigned` (what the signer takes), usrTree, initrd, signer, pkgs, imageId, version
# and signWithTestKeys and signWithTestToken (the release signed in the store with throwaway
# keys, for tests and examples only). It reads three public files of a key set, in
# scripts/make-keys' layout: secureboot/db.crt (the signer signs with its key; the kernel carries
# it, lib/system.nix verityCert), pcr/pcr.pub and release/index.pgp. `pcrPublicKeys` and
# `indexPublicKeys` name other directories, so a db rotation keeps the PCR key and the release key.
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
      throw "golconda: mkImage: unknown argument ${concatStringsSep ", " unknown}; it takes config, publicKeys, pcrPublicKeys, indexPublicKeys and system (docs/reference/outputs.md)"
    else
      args;
  inherit (checked) config;
  system = args.system or builtins.currentSystem;
  publicKeys =
    args.publicKeys
      or (throw "golconda: mkImage needs publicKeys, the directory of the key set's public halves (docs/reference/outputs.md)");
  pcrPublicKeys = args.pcrPublicKeys or publicKeys;
  indexPublicKeys = args.indexPublicKeys or publicKeys;

  # one public file of a key set: a path or an absolute string is copied alone; a derivation is named
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
  composed = mkSystem {
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
  # sshd is the only login, and the health checks pass without it: an image without it would
  # bless itself and stay unreachable
  sys =
    if composed.inventory."/services/sshd".included or false then
      composed
    else
      throw "golconda: mkImage: the document has no [\"/services/sshd\"] table, so the image has no login; add the table (docs/features/ssh-login.md)";
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
      # No cmdlineExtra: every image boots the production cmdline (image/uki.nix). To watch a boot,
      # pass cmdlineExtra = "systemd.log_level=debug systemd.log_target=console".
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
