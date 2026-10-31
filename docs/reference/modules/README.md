# Modules

The adios module tree lives in `modules/`. Each module returns a typed fragment for the composer.
This page documents every module and the shared types in `modules/lib/`.

## Modules

| path             | role                                                                                                             |
| ---------------- | ---------------------------------------------------------------------------------------------------------------- |
| `/system`        | the composer: `name`, `version`, `fragments` → `{ units; files; sysusers; tmpfiles; packages; links; farmDirs }` |
| `/factory`       | the `/etc` seed under `/usr/share/factory/etc`, its manifest and first-boot stamp, the sshd user (below)         |
| `/vars`          | installs `/usr/lib/golconda/golconda-var-run` (mode `0755`); add once when any var is used                       |
| `/wrap`          | typed options for repkgs' `wrap`: `package`, `argv`, `env`, `files`; the caller uses `set.wrap`                  |
| `/services/sshd` | OpenSSH as a wrapped service with an ed25519 host key var; keys and certificates only (options below)            |

The option tables of each module are [generated from the schema](generated/index.md) and are not
committed; build the book with `scripts/docs`.

## Shared types (`modules/lib/`)

Plain files that modules import. The directory has no `default.nix`, so adios does not load it.

| file               | exports                                                                                                                                                       |
| ------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `fragment.nix`     | `fragment`: `{ units; files; sysusers; tmpfiles; packages; links; farm; dlopen }`, every field optional; `file`, `mode`, `link`                               |
| `merge.nix`        | `merge [ fragment… ] → { ...; links; farmDirs }`: unions attrs, concatenates lists; a duplicate key or path throws; every file comes out as `{ text; mode; }` |
| `app.nix`          | `app`, `argv`, `files`, `perMachineMarkers`, `envOp`, `credentialRef`, `isCredentialRef`, `file`, `filesPlaceholder`, `exe`                                   |
| `service.nix`      | `service`, `render`, `renderWrapped`, `wrapApp`, `sandbox`, `sandboxLines`, `credential`, `credentialArg`                                                     |
| `var.nix`          | `var`, `render`, `adminVar`, `admin`, `unitName`, `credentialId`, `stateDir`                                                                                  |
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
| `package` | derivation                                                          | the package; its `bin` list names its executables                |
| `program` | string, default the first `bin` entry                               | the executable; must be in `bin` when the package declares it    |
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
live in `share/wrap/<pkgname>/` and are referenced via the `{files}` placeholder. The result
declares `bin = [ program ]` and `wraps = package`, so the farm links `/usr/bin/<program>` to the
launcher and nothing else of the wrapped output (repkgs wraps every executable with the same argv).
A file's text cannot name the output it is in: a directive that names a sibling file goes on `argv`
with `{files}`, as sshd does for `AuthorizedKeysFile`.

`renderWrapped wrap svc` renders a service using the wrapped binary:

- `ExecStart=` is the wrapped binary plus `extraArgv` only; `argv`, `env` and `files` are in the
  launch record.
- No files are written to `/usr/lib/<name>/`; they are in the wrapped output.
- `packages` contains the wrapped derivation, not the original package.

Both renderers write the same unit apart from `ExecStart=` and `Environment=`, including the
`.wants` links. Use `render svc` when no `wrap` is at hand.

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
error naming both sources. One exception: a launcher from `wrapApp` stands in for the program of the
package it wraps (compared by store path), so the plain package's `/usr/bin/<program>` gives way to
it while its other executables stay. A launcher for another package's program, or two launchers for
one program, still clash.

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

### `/factory`

One fragment: the files under `/usr/share/factory/etc`, `/usr/lib/golconda/etc.manifest`, the
tmpfiles lines that seed `/etc`, and the sshd privilege-separation user with `/var/empty` (ambient,
like `/etc/pam.d`: a configuration with `/services/sshd` adds `/factory` once).

| option       | type                             | rendered as                                                                                |
| ------------ | -------------------------------- | ------------------------------------------------------------------------------------------ |
| `hostname`   | word, default `"golconda"`       | `hostname`                                                                                 |
| `timezone`   | zone name, default `"UTC"`       | `L /etc/localtime - - - - /usr/share/zoneinfo/<timezone>`                                  |
| `extraFiles` | attrs path under `/etc` → `file` | more seeds; a built-in path or `passwd`, `group`, `shadow`, `gshadow`, `machine-id` throws |

Built-in seeds: `hostname`, `shells` (`/usr/bin/sh`, `/usr/bin/dash`), `pam.d/other` (every type
`pam_deny`), `pam.d/sshd` (`account pam_unix`; `session pam_systemd` optional, `session pam_unix`;
no `auth` line, so an auth request falls through to `other`), `ssl/anchors/.keep`,
`ssl/blocklist/.keep`, `pkcs11/.keep`. Not seeded: `passwd`, `group`, `shadow` (systemd-sysusers
writes them on first boot from `/usr/lib/sysusers.d`) and `machine-id` (PID 1).

tmpfiles: `C+ /etc - - - - /usr/share/factory/etc` (a plain `C` skips `/etc`, which already holds
`machine-id` when tmpfiles runs; `C+` copies what is missing and replaces nothing),
`d /etc/ssh 0755`, the two `L` lines (`localtime`, `os-release` → `../usr/lib/os-release`),
`d /var/empty 0755`, and `f /etc/.golconda-factory-id 0644 root root - <sha256 of the manifest>`,
written only when the file does not exist: the stamp of the factory that seeded this `/etc`.

The manifest has one line per factory path, sorted: `f <mode> root:root <sha256> /etc/<path>` for a
file, `l - root:root <target> <path>` for a symlink, `d 0755 root:root - <path>` for a directory.
Two modules that write one factory path are a composer error, like any duplicate file.

### `/services/sshd`

One fragment: the host key var `sshd-hostkey` (credential `sshd-hostkey.key`, passed with `-h`),
`sshd.service`, the sshd launcher (`renderWrapped`: `/usr/bin/sshd` carries `-D -e -f` and the
configuration in its `share/wrap/openssh/`), and, when their options are on, the admin vars
`sshd-host-cert` and `sshd-revoked-keys`. The generated `sshd_config` fixes
`PasswordAuthentication no`, `KbdInteractiveAuthentication no`,
`ChallengeResponseAuthentication no`, `PermitRootLogin prohibit-password`, `UsePAM yes` and
`LogLevel VERBOSE`; no option changes them ([design/trust](../../design/trust.md#identity)).
`/etc/pam.d/sshd` comes from `/factory`.

| option              | type                                       | rendered as                                                                                                          |
| ------------------- | ------------------------------------------ | -------------------------------------------------------------------------------------------------------------------- |
| `package`           | derivation                                 | repkgs `openssh`; `program = "sshd"`                                                                                 |
| `wrap`              | function                                   | repkgs' `set.wrap`, from the configuration like `package`                                                            |
| `port`              | int, default `22`                          | `Port`                                                                                                               |
| `authorizedKeys`    | list of string, default `[ ]`              | `authorized_keys.root` in the launcher; bootstrap only                                                               |
| `trustedUserCAKeys` | list of string, default `[ ]`              | `trusted_user_ca_keys` and `-o TrustedUserCAKeys={files}/trusted_user_ca_keys`                                       |
| `principals`        | attrs user → list of string, default `{ }` | `principals.<user>` and `-o AuthorizedPrincipalsFile={files}/principals.%u`                                          |
| `revokedKeys`       | bool, default `false`                      | admin var `sshd-revoked-keys`; `LoadCredentialEncrypted=krl:sshd-revoked-keys.krl`, `-o RevokedKeys=%d/krl`          |
| `hostCertificate`   | bool, default `false`                      | admin var `sshd-host-cert`; `LoadCredentialEncrypted=hostcert:sshd-host-cert.cert`, `-o HostCertificate=%d/hostcert` |

`AuthorizedKeysFile .ssh/authorized_keys {files}/authorized_keys.%u` is always a `-o` argument.
`revokedKeys` and `hostCertificate` declare admin-supplied vars (a KRL and the signed host
certificate); they reach sshd on the command line because `sshd_config` cannot refer to the
credentials directory, and an app file may not ([`app`](#app)).
