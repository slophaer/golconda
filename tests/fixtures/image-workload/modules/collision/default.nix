#! Claims the update index keyring's path, which the image owns (tests/real-packages/image-config.nix).
_: {
  name = "collision";
  impl = _: {
    files."/usr/lib/systemd/import-pubring.pgp".text = "collision";
  };
}
