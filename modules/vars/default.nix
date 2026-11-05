#! Installs the var runner `/usr/lib/golconda/golconda-var-run` and hosts
#! the documentation of vars: values the image names but never contains.
#!
#! Two classes: local (generated on the machine) and admin (pushed by the
#! deploy host). Bootstrap credentials (hostname) are not vars; see
#! [boot.md](../../../design/boot.md#bootstrap-credentials).
#!
#! Every var unit executes this runner (`modules/lib/var.nix`). One file for
#! all vars, so one module installs it. `/vars` and `/factory` are built-in
#! components (`lib/components.nix`): every system has them, and the composer
#! refuses a second copy.
#!
#! ## Helpers (`modules/lib/var.nix`)
#!
#! | function                 | returns                                       |
#! | ------------------------ | --------------------------------------------- |
#! | `render var`             | a fragment with the unit, manifest and script |
#! | `admin adminVar`         | a fragment with the manifest entry only       |
#! | `unitName name`          | `"golconda-var-<name>.service"`               |
#! | `credentialId name file` | `"<name>.<file>"`, for both classes           |
#! | `stateDir name`          | `"/var/lib/golconda/vars/<name>"`             |
#!
#! The types `var` and `adminVar` are on the [Types](types.md) page.
#!
#! ## Generated fragment
#!
#! `render var` returns:
#!
#! - `units."golconda-var-<name>.service"`: oneshot, `RemainAfterExit=yes`,
#!   `ConditionPathExists=!/var/lib/golconda/vars/<name>/done`. Runs after any
#!   vars in `after`.
#! - `files."/usr/lib/golconda/vars.d/<name>.json"`: manifest with name,
#!   `class: "local"`, secrets, publics, after, and credential ids.
#! - `files."/usr/lib/golconda/vars.d/<name>.sh"`: the script.
#! - `packages`: the packages the script needs.
#!
#! `admin adminVar` returns a fragment with one file, `vars.d/<name>.json`
#! (`name`, `class: "admin"`, `files`, `credentials`, `consumers`), and no
#! unit: the consumer's unit waits for the push. The deploy host keeps the
#! value age-encrypted, pushes it over ssh, and the machine seals it with its
#! own `systemd-creds` into `/etc/credstore.encrypted/<name>.<file>`; the
#! deploy tool then restarts the `consumers`. The deploy tool *(planned)*
#! reads the manifest from the machine, never from evaluation.
#!
#! ## On the machine
#!
#! The runner, started by `ExecStart=` directly:
#!
#! 1. Changes to `$RUNTIME_DIRECTORY` and runs the script.
#! 1. Seals each secret file with
#!    `systemd-creds encrypt --with-key=auto --tpm2-public-key-pcrs=11 --name=<name>.<file>`
#!    (host+tpm2 with a TPM2, the host key without one).
#! 1. Installs the sealed credential to `/etc/credstore.encrypted/<name>.<file>`.
#! 1. Copies public files to `/var/lib/golconda/vars/<name>/pub/`.
#! 1. Touches `done` so the unit does not run again.
#!
#! For an admin var the deploy host runs
#! `golconda-var-run --admin <name> <file>` over ssh with the value on stdin.
#! It seals the value the same way, only when the image's manifest declares
#! that admin var and file; a second push replaces the value.
#!
#! ## Example
#!
#! ```nix
#! let v = import ../../lib/var.nix { inherit types; }; in
#! v.render {
#!   name = "sshd-hostkey";
#!   secrets = [ "key" ];
#!   publics = [ "key.pub" ];
#!   script = "ssh-keygen -q -t ed25519 -N '' -f key";
#!   packages = [ pkgs.openssh ];
#! }
#! ```
#!
#! An admin-supplied var, and a consumer that loads a credential of either class:
#!
#! ```nix
#! v.admin { name = "sshd-host-cert"; files = [ "cert" ]; }
#! credentials.hostcert = v.credentialId "sshd-host-cert" "cert";
#! credentials.hostkey = v.credentialId "sshd-hostkey" "key";
#! after = [ (v.unitName "sshd-hostkey") ];
#! wants = [ (v.unitName "sshd-hostkey") ];
#! ```
#!
#! See [design/trust](../../../design/trust.md) for the secret delivery model.
_: {
  name = "vars";

  impl = _: {
    files."/usr/lib/golconda/golconda-var-run" = {
      text = builtins.readFile ./golconda-var-run;
      mode = "0755";
    };
  };
}
