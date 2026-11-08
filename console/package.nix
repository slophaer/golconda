# The console: the command line (`golconda`) and the daemon (`golcondad`), built from this directory with repkgs' Rust
# toolchain. Not part of an image: it runs where operators work (console/README.md).
# The version is the workspace's; the source is this directory without the build tree and packages.
{
  package,
  pkgs,
  buildPkgs,
}:
package {
  name = "golconda-console";
  inherit ((builtins.fromTOML (builtins.readFile ./Cargo.toml)).workspace.package) version;
  source = builtins.path {
    path = ./.;
    name = "golconda-console-source";
    # checks/ holds packages of the console's checks, not source
    filter =
      path: _:
      !builtins.elem (baseNameOf path) [
        "target"
        "package.nix"
        "checks"
      ];
  };
  uses = [ "cargo" ];
  bin = [
    "golconda"
    "golcondad"
  ];
  # the commit tests run git on scratch repositories and sign with ssh-keygen; the release
  # tests sign and verify with gpg and publish with rclone
  buildDependencies = [
    buildPkgs.git
    buildPkgs.openssh
    buildPkgs.gnupg
    buildPkgs.rclone
  ];
  # golcondad compiles its fonts in (console/daemon/build.rs)
  env.GOLCONDA_FONTS = "${pkgs.ibm-plex-web}/share/fonts/ibm-plex";
}
