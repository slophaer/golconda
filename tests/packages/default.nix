# Package tests: each directory here holds a test.nu for the package of the same name in
# packages/. It runs as repkgs runs its tests/builder ones: the seed's nu, with repkgs' builder/
# and tests/builder/lib/ (checks.nu) on the include path and $env.pkg set to the package. Only
# test.nu is copied: a test that needs fixtures must add them to the copy. These moved here from the repkgs fork with their packages.
# A test that needs another package has an inputs.nix beside test.nu, `pkgs: { <var> = pkgs.<name>; }`:
# each one is an environment variable of the test ($env.<var>, its store path).
# Build one with `nix-build -A packages.x86_64-linux.tests-<name> --store <CA daemon>`.
{ sources, set }:
let
  seed = set.bootstrap.seed;
  dirs = builtins.attrNames (
    removeAttrs (builtins.readDir ./.) [
      "default.nix"
      "README.md"
    ]
  );
  check =
    name:
    let
      test = builtins.path {
        path = ./. + "/${name}/test.nu";
        name = "${name}-test.nu";
      };
      pkg = set.pkgs.${name};
      inputs = ./. + "/${name}/inputs.nix";
    in
    derivation (
      (if builtins.pathExists inputs then import inputs set.pkgs else { })
      // {
        name = "check-${name}";
        system = set.platform.system;
        __contentAddressed = true;
        outputHashMode = "recursive";
        outputHashAlgo = "sha256";
        PATH = "${seed}/bin";
        inherit pkg;
        inherit (pkg) debug;
        builder = "${seed}/bin/nu";
        # nu separates include dirs with \x1e
        args = [
          "--no-config-file"
          "--include-path=${sources.repkgs}/builder${builtins.fromJSON "\"\\u001e\""}${sources.repkgs}/tests/builder/lib"
          "${test}"
        ];
      }
    );
in
builtins.listToAttrs (
  map (name: {
    name = "tests-${name}";
    value = check name;
  }) dirs
)
