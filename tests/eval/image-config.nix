# Public image composition must keep configured modules alongside image-owned links.
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
  image =
    config:
    f.lib.mkImage {
      inherit config;
      keys = "/tmp/golconda-test-keys";
      system = "x86_64-linux";
    };
  keepsMarker =
    config:
    let
      i = image config;
      tree = i.erofs.usrTree;
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
        publicKey = "/tmp/golconda-test-keys/release/index.pgp";
      };
    in
    tree.files.${marker}.text == "custom workload\n"
    &&
      (linkAt "/usr/lib/systemd/boot/efi/systemd-bootx64.efi.signed").target
      == "${i.loader}/systemd-bootx64.efi.signed"
    && keyring.target == "${expectedKeyring}/import-pubring.pgp";
  additive = f.lib.mkSystem {
    inherit config;
    system = "x86_64-linux";
    extraFragments = [
      {
        name = "/image/additive";
        files."/usr/lib/additive-marker".text = "additive";
      }
    ];
  };
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
          tree = f.packages.x86_64-linux.${name}.erofs.usrTree;
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
  (check "mkSystem: extraFragments are named and added beside the configured modules" (
    additive.composed.files ? ${marker}
    && additive.composed.files."/usr/lib/additive-marker".text == "additive"
    && builtins.elem "/image/additive" additive.fragments
  ))
  (check "mkImage: the loader, keyring and initrd use the downstream packages too" (
    let
      i = f.lib.mkImage {
        config = ../fixtures/downstream/server.toml;
        keys = "/tmp/golconda-test-keys";
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
        keys = "/tmp/golconda-test-keys";
        system = "x86_64-linux";
      }).pkgs.openssh.version
    ).success
  ))
  (check "mkImage: rejects a user claim on its keyring destination" (
    !(builtins.tryEval (builtins.deepSeq (image duplicateConfig).erofs.usrTree.links true)).success
  ))
]
