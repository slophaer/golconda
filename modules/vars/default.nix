# The runner every var unit executes (modules/lib/var.nix). One file for all
# vars, so one module installs it: a configuration with vars adds `/vars` to
# the fragments once; the composer refuses a second copy.
_: {
  name = "vars";

  impl = _: {
    files."/usr/lib/golconda/golconda-var-run" = builtins.readFile ../lib/golconda-var-run;
  };
}
