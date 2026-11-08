# The command line (`golconda`: vars and release), built from this directory with repkgs' Rust
# toolchain. Not part of an image: it runs where operators work (cli/README.md).
# The version is Cargo.toml's; the source is this directory without the build tree and packages.
{
  package,
  buildPkgs,
}:
package {
  name = "golconda-cli";
  inherit ((builtins.fromTOML (builtins.readFile ./Cargo.toml)).package) version;
  source = builtins.path {
    path = ./.;
    name = "golconda-cli-source";
    # checks/ holds packages of the command line's checks, not source
    filter =
      path: _:
      !builtins.elem (baseNameOf path) [
        "target"
        "package.nix"
        "checks"
      ];
  };
  uses = [ "cargo" ];
  bin = [ "golconda" ];
  # the tests run git on scratch repositories and publish with rclone; the release tests sign
  # and verify with gpg
  buildDependencies = [
    buildPkgs.git
    buildPkgs.gnupg
    buildPkgs.rclone
  ];
}
