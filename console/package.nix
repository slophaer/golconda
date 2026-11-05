# The console's command line (`golconda`), built from this directory with repkgs' Rust
# toolchain. Not part of an image: it runs where operators work (console/README.md).
# The version is the workspace's; the source is this directory without the build tree.
{ package }:
package {
  name = "golconda-console";
  inherit ((builtins.fromTOML (builtins.readFile ./Cargo.toml)).workspace.package) version;
  source = builtins.path {
    path = ./.;
    name = "golconda-console-source";
    filter = path: _: baseNameOf path != "target" && baseNameOf path != "package.nix";
  };
  uses = [ "cargo" ];
  bin = [ "golconda" ];
}
