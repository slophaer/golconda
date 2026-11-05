# The console: the command line (`golconda`) and the daemon (`golcondad`), built from this directory with repkgs' Rust
# toolchain. Not part of an image: it runs where operators work (console/README.md).
# The version is the workspace's; the source is this directory without the build tree.
{ package, pkgs }:
package {
  name = "golconda-console";
  inherit ((builtins.fromTOML (builtins.readFile ./Cargo.toml)).workspace.package) version;
  source = builtins.path {
    path = ./.;
    name = "golconda-console-source";
    filter = path: _: baseNameOf path != "target" && baseNameOf path != "package.nix";
  };
  uses = [ "cargo" ];
  bin = [
    "golconda"
    "golcondad"
  ];
  # golcondad compiles its fonts in (console/daemon/build.rs)
  env.GOLCONDA_FONTS = "${pkgs.ibm-plex-web}/share/fonts/ibm-plex";
}
