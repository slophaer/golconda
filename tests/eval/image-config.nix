# Public image composition must keep configured fragments alongside image-owned links.
{ check, f, ... }:
let
  marker = "/usr/lib/custom-marker";
  config = {
    "/system" = {
      name = "fragment-test";
      version = "20261031.1";
      fragments = [
        {
          name = "custom-marker";
          files.${marker} = {
            text = "custom workload\n";
            mode = "0644";
          };
        }
      ];
    };
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
  replacement = f.lib.mkSystem {
    inherit config;
    system = "x86_64-linux";
    extra."/system".fragments = [
      { files."/usr/lib/replacement-marker".text = "replacement"; }
    ];
    extraFragments = [
      { files."/usr/lib/additive-marker".text = "additive"; }
    ];
  };
  duplicateConfig = config // {
    "/system" = config."/system" // {
      fragments = config."/system".fragments ++ [
        { files."/usr/lib/systemd/import-pubring.pgp".text = "collision"; }
      ];
    };
  };
in
[
  (check "mkImage: retains configured fragments and image links from an attrset" (keepsMarker config))
  (check "mkImage: retains configured fragments and image links from TOML" (
    keepsMarker ../fixtures/image-fragments.toml
  ))
  (check "mkSystem: replaces configured fragments before additive fragments" (
    !(replacement.composed.files ? ${marker})
    && replacement.composed.files."/usr/lib/replacement-marker".text == "replacement"
    && replacement.composed.files."/usr/lib/additive-marker".text == "additive"
  ))
  (check "mkImage: rejects a user claim on its keyring destination" (
    !(builtins.tryEval (builtins.deepSeq (image duplicateConfig).erofs.usrTree.links true)).success
  ))
]
