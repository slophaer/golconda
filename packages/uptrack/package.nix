# uptrack, repkgs' update tool (docs/uptrack.md in the repkgs tree): nushell scripts that poll the
# upstreams named in sources.toml files and write new pins. The console runs `uptrack check NAMES
# --json` with UPTRACK_ROOT set to a tree, so it needs no repkgs checkout. Not part of an image:
# it goes on PATH beside golconda.
#
# The source is the repkgs tree Golconda pins (npins/sources.json), so the tool is always the one
# that matches the sources.toml format of the set the packages come from. There is no
# sources.toml here: a pin of its own would be a second one to keep in step.
{ package, pkgs }:
let
  inherit (import ../../nix/sources.nix) repkgs;
  rev = (builtins.fromJSON (builtins.readFile ../../npins/sources.json)).pins.repkgs.revision;
in
package {
  name = "uptrack";
  version = "0-git.${builtins.substring 0 9 rev}";
  source = repkgs;
  # bin/uptrack runs nu: the interpreter, found via the launcher
  dependencies = [ pkgs.nushell ];
  phases = [
    {
      name = "install";
      run = ''
        # the layout of the repkgs tree: pipeline.nu imports ../../../../builder/sys-libs.nu
        let lib = $"($c.out)/lib/uptrack"
        mkdir $"($lib)/pkgs/up/uptrack" $"($lib)/builder" $"($c.out)/bin"
        ^cp -r pkgs/up/uptrack/src $"($lib)/pkgs/up/uptrack/src"
        ^cp builder/sys-libs.nu builder/sys-libs.json $"($lib)/builder"
        [
          "#!/bin/sh"
          "# the launcher runs this by its path in the output: the modules are lib/ beside bin/"
          'lib=''${0%/*}/../lib/uptrack'
          'exec nu --no-config-file "$lib/pkgs/up/uptrack/src/uptrack" "$@"'
        ] | str join "\n" | save $"($c.out)/bin/uptrack"
        ^chmod +x $"($c.out)/bin/uptrack"
      '';
    }
  ];
  bin = [ "uptrack" ];
  # a nu script with subcommands: `uptrack --version` is no command
  tests.version = false;
}
