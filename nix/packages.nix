# The repkgs set for one platform, with Golconda's out-of-tree packages
# (packages/) added as repkgs `packages`. This is the only place that imports repkgs.
# Returns { pkgs; platform; }: the packages and the platform record they were built with
# (cpu, os, name, march, names.{kernel,systemd,uefi,...}; repkgs nix/platforms.nix).
{
  sources,
  platform,
  features ? { },
}:
import "${sources.repkgs}/nix/set.nix" {
  system = platform; # build machine = target for now; cross comes through `platform` later
  inherit platform;
  packages = import ../packages;
  # Set-wide choices: one TLS stack, one of each (docs/design/principles.md).
  features = {
    tls = "openssl";
  }
  // features;
}
