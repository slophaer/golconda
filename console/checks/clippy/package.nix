# checks.console-clippy: clippy over the console, tests and examples included, in place of the
# build (checks/variant.nix). The levels are console/Cargo.toml's [workspace.lints] (pedantic);
# any warning fails. The output is empty: the check is that it builds.
import ../variant.nix {
  name = "golconda-console-clippy";
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
