# The console's validator as checks.schema-parity runs it: bin/schema-parity, the example
# core/examples/schema-parity.rs, built in place of the console (checks/variant.nix). The check
# gives it the schema and the fixtures with their Nix verdicts (tests/schema).
import ../variant.nix {
  name = "golconda-schema-parity";
  phases = {
    replace."cargo.build" = {
      name = "example";
      run = "x cargo build --release --offline -p golconda-core --example schema-parity";
    };
    replace."cargo.install" = {
      name = "example";
      run = ''
        mkdir $"($c.out)/bin"
        ^cp $"($env.CARGO_TARGET_DIR)/($env.CARGO_BUILD_TARGET)/release/examples/schema-parity" $"($c.out)/bin/"
      '';
    };
    remove = [ "cargo.test" ];
  };
  bin = [ "schema-parity" ];
}
