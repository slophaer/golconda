# Golconda image definitions: tool-independent data that the image builder (lib/image/) renders at
# build time. No nixpkgs references. Layout: docs/design/layout.md; sysupdate: docs/design/updates.md;
# artifact naming: docs/reference/image.md.
{
  repart = import ./repart.nix;
  sysupdate = import ./sysupdate.nix;
  uki = import ./uki.nix;

  # systemd-boot: loader.conf and its place on the ESP
  loader = import ./loader.nix;

  # os-release.nix is imported directly (lib/usr-tree.nix).
  bootCounting = import ./boot-counting.nix;
}
