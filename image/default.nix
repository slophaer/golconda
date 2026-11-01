# Golconda image definitions
#
# Tool-independent data for building Golconda disk images. These are rendered
# to INI files at build time by the image builder. No nixpkgs references.
#
# See docs/design/layout.md for the partition layout.
# See docs/design/updates.md for the sysupdate mechanism.
# See docs/reference/image.md for artifact naming.
{
  # Partitions and their repart.d definitions
  repart = import ./repart.nix;

  # Sysupdate transfer definitions
  sysupdate = import ./sysupdate.nix;

  # UKI configuration (for ukify)
  uki = import ./uki.nix;

  # systemd-boot: loader.conf and its place on the ESP
  loader = import ./loader.nix;

  # erofs configuration
  erofs = import ./erofs.nix;

  # os-release template
  osRelease = import ./os-release.nix;

  # Boot counting and blessing (one source: image/boot-counting.nix)
  bootCounting = import ./boot-counting.nix;
  # UKI naming: <imageId>_<version>+<triesLeft>-<triesDone>.efi
  # After blessing: <imageId>_<version>.efi (no counter suffix)

  # The key layout is in nix/default.nix, next to the chain that reads it (lib.mkImage).
}
