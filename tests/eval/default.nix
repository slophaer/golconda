# Pure-Nix tests of the module model: types, renderers and the composer.
# scripts/lint evaluates this file with iets (through nix/tests.nix); it is `true`
# or throws once with the names of all failing checks. No derivation is instantiated: packages are read as
# data (harness.nix, tests/fixtures/repkgs), and scripts/lint evaluates the file again in
# restricted mode, where the real repkgs cannot be fetched. Checks that need the real package
# set are in tests/real-packages (checks.real-packages).
#   iets eval --expr 'import ./nix/tests.nix { }'
#
# harness.nix holds the shared fixtures, `check` and `checkEq`; each other file is one area:
# a function of the harness that returns a list of checks. Add an area by adding
# its file to `areas`.
{
  sources ? import ../../pins,
  platform ? "x86_64-linux",
}:
let
  harness = import ./harness.nix { inherit sources platform; };

  areas = map (area: import area harness) [
    ./sshd.nix
    ./var.nix
    ./app.nix
    ./service.nix
    ./unit.nix
    ./links.nix
    ./composer.nix
    ./schema.nix
    ./schema-patterns.nix
    ./schema-fixtures.nix
    ./system.nix
    ./module-docs.nix
    ./config.nix
    ./image.nix
    ./image-config.nix
    ./sysupdate.nix
    ./boot.nix
    ./factory.nix
    ./base.nix
    ./kernel.nix
    ./network.nix
    ./pkgs.nix
    ./provenance.nix
    ./grammar.nix
    ./console.nix
    ./secure-boot.nix
    ./index.nix
    ./hwdb.nix
    ./trust.nix
    ./imds.nix
    ./components.nix
    ./pins.nix
    ./check.nix
  ];
  tests = builtins.concatLists areas;
  # a check gives true or its name
  failed = builtins.filter builtins.isString tests;
in
if failed == [ ] then
  true
else
  throw "golconda tests: ${toString (builtins.length failed)} failed:\n${builtins.concatStringsSep "\n" failed}"
