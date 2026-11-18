# The image chain over one system: the code behind `lib.mkImage` and the test images of
# nix/default.nix. Nix builds every artifact unsigned; the signer (lib/image/sign.nu) signs and
# assembles the release outside the store (docs/design/signing.md).
#
# `import ./chain.nix { inherit sources mkSystem imageLib; }` is the function of
# { config; publicKeys; pcrPublicKeys ? publicKeys; system ? ...; }.
# It returns `unsigned` (what the signer takes), usrTree, initrd, signer, pkgs, imageId, version
# and signWithTestKeys and signWithTestToken (the release signed in the store with throwaway
# keys, for tests and examples only). It reads three public files of a key set, in
# scripts/make-keys' layout: secureboot/db.crt (the signer signs with its key; the kernel carries
# it, lib/system.nix verityCert), pcr/pcr.pub and release/index.pgp. `pcrPublicKeys` names another
# directory, so a db rotation keeps the PCR key. The release key cannot change yet.
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
      "system"
    ]
  );
  checked =
    if unknown != [ ] then
      throw "golconda: mkImage: unknown argument ${concatStringsSep ", " unknown}; it takes config, publicKeys, pcrPublicKeys and system (docs/reference/outputs.md)"
    else
      args;
  inherit (checked) config;
  system = args.system or builtins.currentSystem;
  publicKeys =
    args.publicKeys
      or (throw "golconda: mkImage needs publicKeys, the directory of the key set's public halves (docs/reference/outputs.md)");
  pcrPublicKeys = args.pcrPublicKeys or publicKeys;

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
  releaseKey = publicFile publicKeys "release/index.pgp";

  # the system's package set, with its kernel: the signer, the keyring and the initrd take it, so
  # the image evaluates one set and a downstream package replaces for all of them
  inherit (sysRaw) pkgs;
  indexKeyring = imageLib.indexKeyring {
    inherit pkgs sources;
    buildSystem = system;
    publicKey = releaseKey;
  };
  sysRaw = mkSystem {
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
    if sysRaw.inventory."/services/sshd".included or false then
      sysRaw
    else
      throw "golconda: mkImage: the document has no [\"/services/sshd\"] table, so the image has no login; add the table (docs/features/ssh-login.md)";
  stepArgs = {
    imageId = sys.name;
    inherit (sys) version platform pkgs;
    inherit sources;
    buildSystem = system;
  };
  # the initrd's own composition, from the system's (lib/image/initrd.nix)
  initrd = imageLib.initrd (
    stepArgs // { usrTree = imageLib.initrdTree (stepArgs // { inherit (sys) composed; }); }
  );
  signer = imageLib.signer {
    inherit pkgs sources;
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
        inherit dbCert pcrPublicKey releaseKey;
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
    }:
    imageLib.signedWithTestKeys {
      name = "${sys.name}_${sys.version}.test-signed";
      inherit
        unsigned
        keys
        pcrKeys
        ;
      buildSystem = system;
    };
  signWithTestToken =
    {
      keys,
      pcrKeys ? keys,
    }:
    imageLib.signedWithTestToken {
      name = "${sys.name}_${sys.version}.token-signed";
      inherit
        unsigned
        keys
        pcrKeys
        pkgs
        sources
        ;
      buildSystem = system;
    };
}
