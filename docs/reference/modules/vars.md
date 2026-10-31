# vars

The `var` helper in `modules/lib/var.nix` declares values that are generated on the machine and
never enter the image. A var is a fragment: a oneshot unit that runs the generator script on first
boot, seals each secret file to the TPM as a credential, and keeps public files readable.

## Type: `var`

| field      | type                   | meaning                                                                 |
| ---------- | ---------------------- | ----------------------------------------------------------------------- |
| `name`     | word                   | unique name; becomes the unit and credential prefix                     |
| `secrets`  | list of word           | files the script writes that are sealed as credentials `<name>.<file>`  |
| `publics`  | list of word, optional | files kept readable in `/var/lib/golconda/vars/<name>/pub/`             |
| `after`    | list of word, optional | names of vars that must run first; their `pub/` directories are visible |
| `script`   | string                 | POSIX sh script; runs in an empty runtime directory                     |
| `packages` | list of derivation     | tools the script needs                                                  |

A `word` is a shell-safe path component: letters, digits, `_`, `.`, `-`.

## Helpers

| function                 | returns                                       |
| ------------------------ | --------------------------------------------- |
| `render var`             | a fragment with the unit, manifest and script |
| `unitName name`          | `"golconda-var-<name>.service"`               |
| `credentialId name file` | `"<name>.<file>"` (for `service.credentials`) |
| `stateDir name`          | `"/var/lib/golconda/vars/<name>"`             |

## Generated fragment

`render var` returns:

- `units."golconda-var-<name>.service"`: oneshot, `RemainAfterExit=yes`,
  `ConditionPathExists=!/var/lib/golconda/vars/<name>/done`. Runs after any vars in `after`.
- `files."/usr/lib/golconda/vars.d/<name>.json"`: manifest with name, secrets, publics, after, and
  credential ids.
- `files."/usr/lib/golconda/vars.d/<name>.sh"`: the script.
- `packages`: the packages the script needs.

## On the machine

The runner `/usr/lib/golconda/golconda-var-run` (installed executable by the `/vars` module and run
by `ExecStart=` directly):

1. Changes to `$RUNTIME_DIRECTORY` and runs the script.
1. Seals each secret file with `systemd-creds encrypt --with-key=tpm2 --tpm2-public-key-pcrs=11`.
1. Installs the sealed credential to `/etc/credstore.encrypted/<name>.<file>`.
1. Copies public files to `/var/lib/golconda/vars/<name>/pub/`.
1. Touches `done` so the unit does not run again.

## Example

```nix
let v = import ../../lib/var.nix { inherit types; }; in
v.render {
  name = "sshd-hostkey";
  secrets = [ "key" ];
  publics = [ "key.pub" ];
  script = "ssh-keygen -q -t ed25519 -N '' -f key";
  packages = [ pkgs.openssh ];
}
```

A consumer service references the credential:

```nix
credentials.hostkey = v.credentialId "sshd-hostkey" "key";
after = [ (v.unitName "sshd-hostkey") ];
wants = [ (v.unitName "sshd-hostkey") ];
```

See [design/trust](../../design/trust.md) for the secret delivery model.
