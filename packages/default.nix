# Out-of-tree repkgs packages: name -> directory with package.nix and sources.toml.
# A name that exists in repkgs replaces the in-tree package. Golconda-specific ones
# live here; general packages go to the repkgs fork (mtools is here until it moves).
{
  # build-time: `ukify build` for the UKI (lib/image/uki.nix); off in the image's systemd
  ukify = ./ukify;
  # build-time: systemd-repart fills the ESP with mcopy/mmd (lib/image/disk.nix)
  mtools = ./mtools;
}
