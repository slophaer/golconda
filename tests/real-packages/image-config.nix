# Public image composition must keep configured modules alongside image-owned links: the image
# chain over the real package set (moved from tests/eval/image-config.nix, which keeps the
# mkSystem part).
{
  check,
  f,
  hasInfix,
  ...
}:
let
  marker = "/usr/lib/custom-marker";
  # the marker is a downstream module (tests/fixtures/image-workload/modules)
  modules = ../fixtures/image-workload/modules;
  config = {
    golconda = { inherit modules; };
    "/system" = {
      name = "fragment-test";
      version = "20261031.1";
    };
    "/local/marker" = { };
  };
  # the public halves of a key set, committed: the chain reads nothing else of a key set
  publicKeys = ../fixtures/public-keys;
  image =
    config:
    f.lib.mkImage {
      inherit config publicKeys;
      system = "x86_64-linux";
    };
  keepsMarker =
    config:
    let
      i = image config;
      tree = i.usrTree;
      linkAt = path: builtins.head (builtins.filter (link: link.path == path) tree.links);
      keyring = linkAt "/usr/lib/systemd/import-pubring.pgp";
      expectedKeyring = (import ../../lib/image { }).indexKeyring {
        buildSystem = "x86_64-linux";
        inherit
          (f.lib.mkSystem {
            inherit config;
            system = "x86_64-linux";
          })
          pkgs
          ;
        publicKey = builtins.path {
          path = publicKeys + "/release/index.pgp";
          name = "index.pgp";
        };
      };
    in
    tree.files.${marker}.text == "custom workload\n"
    # the signed loader is not in the tree Nix builds: the signer puts it there
    && !(builtins.any (l: l.path == "/usr/lib/systemd/boot/efi/systemd-bootx64.efi.signed") tree.links)
    && keyring.target == "${expectedKeyring}/import-pubring.pgp";
  duplicateConfig = config // {
    "/local/collision" = { };
  };
in
[
  (check "images: release fixtures require the configured workload on every boot" (
    builtins.all
      (
        name:
        let
          tree = f.packages.x86_64-linux.${name}.unsigned.manifest.usrTree;
        in
        tree.files."/usr/lib/golconda/test-workload".text == "configured-workload\n"
        && tree.units ? "custom-workload.service"
        && builtins.any (
          link:
          link.path == "/usr/lib/systemd/system/boot-complete.target.requires/custom-workload.service"
          && link.target == "../custom-workload.service"
        ) tree.links
        && builtins.any (
          link:
          link.path == "/usr/lib/systemd/system/multi-user.target.wants/custom-workload.service"
          && link.target == "../custom-workload.service"
        ) tree.links
        && hasInfix "\nBefore=boot-complete.target multi-user.target\n" tree.units."custom-workload.service"
      )
      [
        "image-smoke-test"
        "image-smoke-test-next"
        "image-smoke-test-rotated"
        "image-smoke-test-nosb"
        "image-smoke-test-nosb-next"
      ]
  ))
  (check "mkImage: retains configured modules and image links from an attrset" (keepsMarker config))
  (check "mkImage: retains configured modules and image links from TOML" (
    keepsMarker ../fixtures/image-workload/server.toml
  ))
  (check "mkImage: the signer, keyring and initrd use the downstream packages too" (
    let
      i = f.lib.mkImage {
        config = ../fixtures/downstream/server.toml;
        inherit publicKeys;
        system = "x86_64-linux";
      };
      initrdSys =
        packagesDir: replaces:
        (import ../../lib/image { }).initrdSystem {
          imageId = "t";
          version = "20261031.1";
          inherit (i) pkgs;
          platform = {
            name = "x86_64-linux";
          };
          buildSystem = "x86_64-linux";
          inherit packagesDir replaces;
        };
      allowed = [
        "openssh"
        "ripgrep"
      ];
    in
    # the fixture's openssh (version 0.0.3) replaces Golconda's for the chain's own set
    i.pkgs.openssh.version == "0.0.3"
    && (initrdSys ../fixtures/downstream/packages allowed).pkgs.openssh.version == "0.0.3"
    && (initrdSys null [ ]).pkgs.openssh.version != "0.0.3"
    # the initrd and the chain's own set need the same opt-in as the system
    && !(builtins.tryEval (initrdSys ../fixtures/downstream/packages [ ]).pkgs.openssh.version).success
    && !(builtins.tryEval
      (f.lib.mkImage {
        config = ../fixtures/downstream-unlisted/server.toml;
        inherit publicKeys;
        system = "x86_64-linux";
      }).pkgs.openssh.version
    ).success
  ))
  (check "mkImage: the chain builds its initrd from the downstream set" (
    let
      image =
        config:
        f.lib.mkImage {
          inherit config publicKeys;
          system = "x86_64-linux";
        };
      replaced = image ../fixtures/downstream-initrd/server.toml;
      plain = image {
        "/system" = {
          name = "downstream-initrd";
          version = "20261103.1";
        };
      };
      tree = i: builtins.unsafeDiscardStringContext (toString i.initrd.usrTree);
    in
    # the fixture's tzdata (0.0.4) is in the chain's set, and the initrd tree that the
    # chain builds differs from the one without the downstream packages
    replaced.pkgs.tzdata.version == "0.0.4" && tree replaced != tree plain
  ))
  (check "mkImage: rejects a user claim on its keyring destination" (
    !(builtins.tryEval (builtins.deepSeq (image duplicateConfig).usrTree.links true)).success
  ))
  (check "mkImage: takes no private key; the unsigned outputs name only the public halves" (
    let
      i = image config;
      m = i.unsigned.manifest;
      refused =
        args: !(builtins.tryEval (builtins.deepSeq (f.lib.mkImage args).unsigned.drvPath true)).success;
      inStore = p: builtins.match "/nix/store/[a-z0-9]{32}-(db.crt|pcr.pub|index.pgp)" p != null;
    in
    # the private-key forms of before are refused, whatever the type
    refused {
      inherit config;
      keys = "/srv/golconda-keys";
      system = "x86_64-linux";
    }
    && refused {
      inherit config publicKeys;
      pcrKeys = ./.;
      system = "x86_64-linux";
    }
    && refused {
      inherit config;
      publicKeys = "keys";
      system = "x86_64-linux";
    }
    # each public half is copied alone, by its own name
    && inStore m.publicKeys.dbCert
    && inStore m.publicKeys.pcrPublicKey
    && inStore m.publicKeys.indexKeyring
    # the signer of this image's set, and the parameters from the version
    && i.unsigned.signer == "${i.signer}"
    && m.release.uki == "fragment-test_20261031.1.efi"
  ))
]
