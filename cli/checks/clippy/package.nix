# checks.cli-clippy: clippy over the command line, tests included, in place of the
# build (checks/variant.nix). The levels are cli/Cargo.toml's [lints] (pedantic);
# any warning fails. The output is empty: the check is that it builds.
import ../variant.nix {
  name = "golconda-cli-clippy";
  phases = {
    replace."cargo.build" = {
      name = "clippy";
      run = "x cargo clippy --release --offline --all-targets -- -D warnings";
    };
    replace."cargo.install" = {
      name = "empty";
      run = "mkdir $c.out";
    };
    remove = [ "cargo.test" ];
  };
}
