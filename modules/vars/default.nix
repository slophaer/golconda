#! Installs the var runner `/usr/lib/golconda/golconda-var-run`.
#!
#! Every var unit executes this runner (`modules/lib/var.nix`). One file for
#! all vars, so one module installs it: a configuration with vars adds `/vars`
#! to the fragments once; the composer refuses a second copy.
_: {
  name = "vars";

  impl = _: {
    files."/usr/lib/golconda/golconda-var-run" = {
      text = builtins.readFile ../lib/golconda-var-run;
      mode = "0755";
    };
  };
}
