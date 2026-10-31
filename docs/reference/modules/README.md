# Modules

The adios module tree lives in `modules/`. Each module returns a typed fragment for the composer.
This page documents every module and the shared types in `modules/lib/`.

## Modules

| path             | role                                                                                                             |
| ---------------- | ---------------------------------------------------------------------------------------------------------------- |
| `/system`        | the composer: `name`, `version`, `fragments` → `{ units; files; sysusers; tmpfiles; packages; links; farmDirs }` |
| `/vars`          | installs `/usr/lib/golconda/golconda-var-run` (mode `0755`); add once when any var is used                       |
| `/wrap`          | typed options for repkgs' `wrap`: `package`, `argv`, `env`, `files`; the caller uses `set.wrap`                  |
| `/services/sshd` | OpenSSH as a service with an ed25519 host key var; keys and certificates only (options below)                    |

## Shared types (`modules/lib/`)

Plain files that modules import. The directory has no `default.nix`, so adios does not load it.

| file               | exports                                                                                                                                                       |
| ------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `fragment.nix`     | `fragment`: `{ units; files; sysusers; tmpfiles; packages; links; farm; dlopen }`, every field optional; `file`, `mode`, `link`                               |
| `merge.nix`        | `merge [ fragment… ] → { ...; links; farmDirs }`: unions attrs, concatenates lists; a duplicate key or path throws; every file comes out as `{ text; mode; }` |
| `app.nix`          | `app`, `argv`, `files`, `perMachineMarkers`, `envOp`, `credentialRef`, `isCredentialRef`, `file`, `filesPlaceholder`, `exe`                                   |
| `service.nix`      | `service`, `render`, `renderWrapped`, `wrapApp`, `sandbox`, `sandboxLines`, `credential`, `credentialArg`                                                     |
| `var.nix`          | `var`, `render`, `unitName`, `credentialId`, `stateDir`                                                                                                       |
| `golconda-var-run` | POSIX sh runner for var units                                                                                                                                 |

### `fragment`

The return type of every module.

| field      | type                       | installed to                                           |
| ---------- | -------------------------- | ------------------------------------------------------ |
| `units`    | attrs name → text          | `/usr/lib/systemd/system/<name>`                       |
| `files`    | attrs path → file          | the path (must start with `/usr`)                      |
| `sysusers` | list of string             | `/usr/lib/sysusers.d/` lines                           |
| `tmpfiles` | list of string             | `/usr/lib/tmpfiles.d/` lines                           |
| `packages` | list of derivation         | `/usr/nix/store` closure, `/usr/bin`                   |
| `links`    | list of `{ path; target }` | symlinks under `/usr` (including `.wants`)             |
| `farm`     | attrs pkgName → [ subdir ] | subdirs linked file by file (e.g., `lib/udev/rules.d`) |
| `dlopen`   | attrs pkgName → [ soname ] | sonames linked into `/usr/lib` for dlopen              |

A `file` is either the text (installed with mode `0644`) or `{ text; mode ? "0644"; }`, where `mode`
is four octal digits (`"0755"` for an executable). The composer's output always has the record
shape: `files.<path> = { text; mode; }`. An `app`'s files are text only.

### `app`

What a program needs to run, with nothing systemd-specific. Embedded in `service`.

| field     | type                                                                | meaning                                                          |
| --------- | ------------------------------------------------------------------- | ---------------------------------------------------------------- |
| `package` | derivation                                                          | the package; its first `bin` entry is the program                |
| `argv`    | list of string, default `[ ]`                                       | arguments after the program; `{files}` expands to the files path |
| `env`     | attrs of one-key `{ set \| default \| prepend \| append \| unset }` | environment operations                                           |
| `files`   | attrs name → text, default `{ }`                                    | files installed to `/usr/lib/<service>/<name>`                   |

A `{ credential = "n"; }` value in `argv` is a type error: an app runs outside systemd. A file text
that contains `%d/`, `$CREDENTIALS_DIRECTORY`, `-----BEGIN` or `PRIVATE KEY` is a type error that
names the file: an app file holds no per-machine value (`perMachineMarkers` in `app.nix`).

### `service`

A service is an `app` plus what only a unit has. `render service` returns a fragment.

| field         | type                                                                  | rendered as                                                                    |
| ------------- | --------------------------------------------------------------------- | ------------------------------------------------------------------------------ |
| `name`        | unit name stem                                                        | `units."<name>.service"`, `/usr/lib/<name>/` for files                         |
| `app`         | `app`                                                                 | `ExecStart=`, `Environment=`, `files`, `packages`                              |
| `extraArgv`   | list of string or `{ credential = "n"; prefix ? ""; }`, default `[ ]` | after `app.argv`; a ref renders as `<prefix>%d/n` and must be in `credentials` |
| `credentials` | attrs name → credstore id, default `{ }`                              | `LoadCredentialEncrypted=name:id`                                              |
| `state`       | list of string, default `[ ]`                                         | `StateDirectory=`                                                              |
| `user`        | `"dynamic"`, `"root"` or a sysusers line                              | `DynamicUser=yes`, `User=root`, or `User=` plus sysusers                       |
| `sandbox`     | `"strict"`, `"default"` or `"trusted"`                                | hardening directives from `sandboxLines`                                       |
| `after`       | list of unit names, default `[ ]`                                     | `After=`                                                                       |
| `wants`       | list of unit names, default `[ ]`                                     | `Wants=`                                                                       |
| `wantedBy`    | list of target names, default `[ "multi-user.target" ]`               | `[Install] WantedBy=` and static `.wants` links                                |

Arguments are escaped (`%` → `%%`, `$` → `$$`). `credential "n"` builds a plain ref;
`credentialArg "RevokedKeys=" "n"` builds one with a prefix, for programs that take a path as
`-o Option=<path>`. A prefix is one word of letters, digits and `_ = : / . , + -`.

### `wrapApp` and `renderWrapped`

`wrapApp wrap app` creates a wrapped derivation from an `app` record. `wrap` is repkgs' `set.wrap`
function, passed by the caller. The wrapped output is a relocatable package: its `bin/<exe>` is a
launcher that executes the original binary with the app's arguments and environment. Config files
live in `share/wrap/<pkgname>/` and are referenced via the `{files}` placeholder.

`renderWrapped wrap svc` renders a service using the wrapped binary:

- `ExecStart=` is the wrapped binary plus `extraArgv` only; `argv`, `env` and `files` are in the
  launch record.
- No files are written to `/usr/lib/<name>/`; they are in the wrapped output.
- `packages` contains the wrapped derivation, not the original package.

Use `render svc` for backwards compatibility when wrapping is not available.

### The `{files}` placeholder

`file "name"` expands to `{files}/name`. Each renderer expands `{files}` to where it puts the app's
files:

| renderer        | `{files}` expands to          |
| --------------- | ----------------------------- |
| `render`        | `/usr/lib/<service>`          |
| `renderWrapped` | `{root}/share/wrap/<pkgname>` |

`{root}` is a launch placeholder expanded by repkgs' `launch` at run time. Config files live in ONE
place: the wrapped output when using `renderWrapped`, or `/usr/lib/<name>/` when using `render`.

### `merge`

`merge [ fragmentA fragmentB ]` unions `units` and `files` (a repeated key throws, whichever shape
the two values have), normalises every file to `{ text; mode; }`, concatenates `sysusers` and
`tmpfiles`, and checks `packages`: two packages with the same `/usr/bin` name throw. The output
adds:

| field      | from                                                                             |
| ---------- | -------------------------------------------------------------------------------- |
| `links`    | `/usr/bin/<name>` from packages, `/usr/lib/<soname>` from dlopen, explicit links |
| `farmDirs` | `farm` declarations expanded to `{ path; target }` for the image builder         |

A link path that collides with a file path is an error. Two sources for the same link path is an
error naming both sources.

Error message example: `golconda: /usr/bin/jq defined twice: package jq-1.7, package jq-wrap-1.7`.

### `/wrap`

The module declares the arguments of repkgs' `wrap` and returns them unchanged. A caller passes them
to `set.wrap` in `nix/packages.nix`. `wrap` returns a package with launch records in
`bin/.<x>.launch`.

| option    | type                          | meaning                                                        |
| --------- | ----------------------------- | -------------------------------------------------------------- |
| `package` | derivation                    | the package to wrap                                            |
| `argv`    | list of string, default `[ ]` | prepended arguments; `{root}` and `{store}` expand at run time |
| `env`     | attrs, default `{ }`          | `{ VAR = { op = value; }; }`                                   |
| `files`   | attrs name → text             | installed to `{root}/share/wrap/<pkgname>/<name>`              |

`packages.<system>.wrap-smoke` wraps `jq` with `--version` as a build check.

### `/services/sshd`

One fragment: the host key var `sshd-hostkey` (credential `sshd-hostkey.key`, passed with `-h`),
`sshd.service`, the configuration under `/usr/lib/sshd/` and the privilege-separation user. The
generated `sshd_config` fixes `PasswordAuthentication no`, `KbdInteractiveAuthentication no`,
`ChallengeResponseAuthentication no`, `PermitRootLogin prohibit-password`, `UsePAM yes` and
`LogLevel VERBOSE`; no option changes them ([design/trust](../../design/trust.md#identity)).

| option              | type                                       | rendered as                                                                                  |
| ------------------- | ------------------------------------------ | -------------------------------------------------------------------------------------------- |
| `package`           | derivation                                 | the program (its first `bin`)                                                                |
| `port`              | int, default `22`                          | `Port`                                                                                       |
| `authorizedKeys`    | list of string, default `[ ]`              | `/usr/lib/sshd/authorized_keys.root`; bootstrap only                                         |
| `trustedUserCAKeys` | list of string, default `[ ]`              | `/usr/lib/sshd/trusted_user_ca_keys` and `TrustedUserCAKeys`                                 |
| `principals`        | attrs user → list of string, default `{ }` | `/usr/lib/sshd/principals.<user>` and `AuthorizedPrincipalsFile /usr/lib/sshd/principals.%u` |
| `revokedKeys`       | credential name or `null`, default `null`  | `LoadCredentialEncrypted=<name>:<name>` and `-o RevokedKeys=%d/<name>`                       |
| `hostCertificate`   | bool, default `false`                      | `LoadCredentialEncrypted=hostcert:sshd-host-cert` and `-o HostCertificate=%d/hostcert`       |

`revokedKeys` and `hostCertificate` name admin-supplied credentials (a KRL and the signed host
certificate); they reach sshd on the command line because `sshd_config` cannot refer to the
credentials directory, and an app file may not ([`app`](#app)).
