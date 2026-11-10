# A stand-in for repkgs' nix/platforms.nix in the eval tests: the fields Golconda reads, for the
# two targets it builds (tests/fixtures/repkgs/nix/set.nix adds `cross`).
{
  x86_64-linux = {
    name = "x86_64-linux";
    system = "x86_64-linux";
    cpu = "x86_64";
    os = "linux";
    libc = "glibc";
    names = {
      kernel = "x86";
      systemd = "x86-64";
      uefi = "x64";
    };
  };
  aarch64-linux = {
    name = "aarch64-linux";
    system = "aarch64-linux";
    cpu = "aarch64";
    os = "linux";
    libc = "glibc";
    names = {
      kernel = "arm64";
      systemd = "arm64";
      uefi = "aa64";
    };
  };
}
