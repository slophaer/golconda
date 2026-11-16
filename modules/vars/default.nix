#! Installs the var runner `/usr/lib/golconda/golconda-var-run` and hosts the documentation of vars: values the image names but never contains.
#! Local vars are generated on the machine, admin vars are pushed by the deploy host; both end as a sealed `/etc/credstore.encrypted/<name>.<file>`.
#! Every var unit runs this one runner, so one module installs it. `/vars` is a built-in component. Bootstrap credentials (hostname) are not vars.
#! The helpers are in `modules/lib/var.nix`; the types `var` and `adminVar` are on the [Types](types.md) page.
#! The model, the runner's modes (`--admin`, `--reseal`) and an example: docs/features/vars.md and docs/design/trust.md.
_: {
  name = "vars";

  impl = _: {
    files."/usr/lib/golconda/golconda-var-run" = {
      text = builtins.readFile ./golconda-var-run;
      mode = "0755";
    };
  };
}
