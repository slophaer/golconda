# The repkgs set for one platform, with Golconda's out-of-tree packages
# (packages/) added as repkgs `packages`. This is the only place that imports repkgs.
{
  sources,
  platform,
  features ? { },
}:
import sources.repkgs {
  system = platform; # build machine = target for now; cross comes through `platform` later
  inherit platform;
  packages = import ../packages;
  # Set-wide choices: one TLS stack, one of each (docs/design/principles.md).
  features = {
    tls = "openssl";
  }
  // features;
}
