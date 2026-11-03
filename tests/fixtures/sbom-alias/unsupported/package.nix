# The SBOM must not instantiate unused packages that cannot run on the target.
{ package }:
package {
  name = "unsupported";
  version = "0.0.0";
  source = builtins.toFile "unused-source" "";
  platforms.cpu = [ ];
}
