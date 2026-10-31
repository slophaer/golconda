# The repkgs set for a target platform, built on the current machine.
#
# This is the only place that imports repkgs. It returns:
#   { pkgs; platform; platforms; set; }
#
# - `pkgs`: the packages for the target platform
# - `platform`: the elaborated platform record (cpu, os, name, march,
#   names.{kernel,systemd,uefi,...}; see repkgs nix/platforms.nix)
# - `platforms`: the full platforms table, for callers that build for several targets
# - `set`: the full repkgs set (with wrap, closure, etc.)
#
# Cross-compilation: `system` is the build host (builtins.currentSystem by default),
# `platform` is the target (defaults to the build host). When they differ, repkgs
# builds packages that run on the target, using the build host's toolchain.
# Example: `platform = "aarch64-linux"` on an x86_64 host builds aarch64 binaries.
{
  sources,
  system,
  platform ? system,
  features ? { },
}:
let
  platforms = import "${sources.repkgs}/nix/platforms.nix";
  set = import "${sources.repkgs}/nix/set.nix" {
    inherit system platform;
    packages = import ../packages;
    # Set-wide choices: one TLS stack, one of each (docs/design/principles.md).
    features = {
      tls = "openssl";
    }
    // features;
  };
in
{
  inherit (set) pkgs platform;
  inherit platforms set;
}
