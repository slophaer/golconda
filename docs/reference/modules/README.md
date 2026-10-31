# Modules

The adios module tree lives in `modules/`. Each module returns a typed fragment for the composer.

The [generated module pages](generated/index.md) cover each module's options and doc comments. The
[types page](generated/types.md) documents every type from the schema registry.

## Modules

| path             | role                                                                                                                       |
| ---------------- | -------------------------------------------------------------------------------------------------------------------------- |
| `/system`        | the composer: `name`, `version`, `fragments` → `{ units; files; sysusers; tmpfiles; packages; links }`                     |
| `/pkgs`          | the repkgs set, passed once as `set`; returns `{ set; pkgs }` to the modules that declare it as an input                   |
| `/factory`       | the `/etc` seed under `/usr/share/factory/etc`, its manifest and first-boot stamp, the sshd user (below)                   |
| `/vars`          | installs `/usr/lib/golconda/golconda-var-run` (mode `0755`); add once when any var is used                                 |
| `/services/sshd` | OpenSSH as a service with its configuration under `/usr/lib/sshd/` and an ed25519 host key var; keys and certificates only |

The option tables of each module are [generated from the schema](generated/index.md) and are not
committed; build the book with `scripts/docs`.

## Shared types (`modules/lib/`)

Plain files that modules import. The directory has no `default.nix`, so adios does not load it.

| file               | exports                                                                                                                                                                                                 |
| ------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `fragment.nix`     | `fragment`: `{ units; files; sysusers; tmpfiles; packages; links }`, every field optional, no other field; `units`, `unitName`, `unitText`, `unitSuffixes`, `file`, `mode`, `links`, `link`, `linkKind` |
| `merge.nix`        | `merge [ fragment… ] → { units; files; sysusers; tmpfiles; packages; links }`: unions attrs, concatenates lists; a duplicate key or path throws; `linkSources`, `duplicateLink` expose the link check   |
| `app.nix`          | `app`, `argv`, `files`, `perMachineMarkers`, `envOp`, `credentialRef`, `isCredentialRef`, `binName`, `exe`                                                                                              |
| `service.nix`      | `service`, `render`, `filesDir`, `sandbox`, `sandboxLines`, `killMode`, `scope`, `credential`, `credentialArg`                                                                                          |
| `var.nix`          | `var`, `render`, `adminVar`, `admin`, `unitName`, `credentialId`, `stateDir`                                                                                                                            |
| `golconda-var-run` | POSIX sh runner for var units                                                                                                                                                                           |

### `fragment`

The return type of every module.

| field      | type                                         | installed to                                                                  |
| ---------- | -------------------------------------------- | ----------------------------------------------------------------------------- |
| `units`    | attrs `unitName` → `unitText`                | `/usr/lib/systemd/system/<name>`                                              |
| `files`    | attrs path → file                            | the path (must start with `/usr`)                                             |
| `sysusers` | list of string                               | `/usr/lib/sysusers.d/` lines                                                  |
| `tmpfiles` | list of string                               | `/usr/lib/tmpfiles.d/` lines                                                  |
| `packages` | list of derivation                           | `/usr/nix/store` closure; every name in `bin` becomes `/usr/bin/<name>`       |
| `links`    | attrs path under `/usr` → `{ target; kind }` | the other symlinks of `/usr`: `.wants`, directories to expand, dlopen sonames |

A `link` is `{ target; kind; }`; its path is the key. `kind` is one of `package` (`/usr/bin/<name>`
from a `bin` list; the composer derives these, a fragment rarely writes one), `farm` (the target is
a directory the image builder links file by file: `lib/udev/rules.d` of a package built with
`prefix = "/usr"`), `dlopen` (a soname the builder checks resolves) or `explicit` (anything else; a
`.wants` link has a relative target). A path outside `/usr/`, a missing `target` or `kind`, or an
unknown kind is a type error that names the path. The fragment refuses any other field.

A `file` is either the text (installed with mode `0644`) or `{ text; mode ? "0644"; }`, where `mode`
is four octal digits (`"0755"` for an executable). The composer's output always has the record
shape: `files.<path> = { text; mode; }`. An `app`'s files are text only.

A `unitName` is a stem of letters, digits, `: _ . @ -` and one of `.service`, `.target`, `.socket`,
`.timer`, `.path`, `.mount`, `.slice` (`unitSuffixes`); a `unitText` is a string with at least one
section header line (`[Unit]`, `[Service]`, ...). An empty text, a text without a header, or a name
with another suffix is a type error that names the unit. A user unit is not in `units`: the renderer
writes it as a file under `/usr/lib/systemd/user/`.

### `app`

What a program needs to run, with nothing systemd-specific. Embedded in `service`.

| field     | type                                                                  | meaning                                                                                         |
| --------- | --------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| `package` | derivation                                                            | the package; its `bin` list names its executables                                               |
| `program` | string, default the first `bin` entry                                 | the executable; must be in `bin` when the package declares it                                   |
| `argv`    | list of string or `{ credential = "n"; prefix ? ""; }`, default `[ ]` | arguments after the program; a ref renders as `<prefix>%d/n` and must be in `credentials`       |
| `env`     | attrs of one-key `{ set \| default \| prepend \| append \| unset }`   | environment operations, `Environment=` lines                                                    |
| `files`   | attrs name → text, default `{ }`                                      | files installed to `/usr/lib/<service>/<name>`; a name may hold a directory (`principals/root`) |

An argument with a newline is a type error (it would end the `ExecStart=` line). A file text that
contains `%d/`, `$CREDENTIALS_DIRECTORY`, `/etc/credstore`, `-----BEGIN` or `PRIVATE KEY` is a type
error that names the file: an app file holds no per-machine value (`perMachineMarkers` in
`app.nix`); a secret is a credential, referenced from `argv`. An unknown field is a type error.

### `service`

A service is an `app` plus what only a unit has. `render service` returns a fragment: the unit with
`ExecStart=/usr/bin/<program> <argv…>`, the app's files under `/usr/lib/<name>/` (`filesDir name`),
the package, and the `.wants` links. A module writes the same `/usr/lib/<name>/` paths into `argv`
that the renderer writes the files to; `systemctl cat` shows the whole command.

| field              | type                                                                                     | rendered as                                                                      |
| ------------------ | ---------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------- |
| `name`             | unit name stem                                                                           | `units."<name>.service"`, `/usr/lib/<name>/` for files                           |
| `scope`            | `"system"` or `"user"`, default `"system"`                                               | which manager: `units` or a file under `/usr/lib/systemd/user/`                  |
| `app`              | `app`                                                                                    | `ExecStart=`, `Environment=`, `files`, `packages`                                |
| `credentials`      | attrs name → credstore id, default `{ }`                                                 | `LoadCredentialEncrypted=name:id`; refused for scope `user`                      |
| `state`            | list of string, default `[ ]`                                                            | `StateDirectory=`                                                                |
| `runtimeDirectory` | word, optional                                                                           | `RuntimeDirectory=`                                                              |
| `killMode`         | `"control-group"`, `"process"` or `"mixed"`, optional                                    | `KillMode=`; absent means systemd's default (`control-group`)                    |
| `user`             | `"dynamic"`, `"root"` or a sysusers line; required for scope `system`                    | `DynamicUser=yes`, `User=root`, or `User=` plus sysusers; refused for `user`     |
| `sandbox`          | `"strict"`, `"default"` or `"trusted"`                                                   | hardening directives from `sandboxLines`                                         |
| `after`            | list of unit names, default `[ ]`                                                        | `After=`                                                                         |
| `wants`            | list of unit names, default `[ ]`                                                        | `Wants=`                                                                         |
| `wantedBy`         | list of target names, default `[ "multi-user.target" ]` (`user`: `[ "default.target" ]`) | `[Install] WantedBy=` and static `.wants` links under the scope's unit directory |

Arguments are escaped (`%` → `%%`, `$` → `$$`; a literal `%u` for sshd is `%%u` in the unit).
`credential "n"` builds a plain ref; `credentialArg "RevokedKeys=" "n"` builds one with a prefix,
for programs that take a path as `-o Option=<path>`. A prefix is one word of letters, digits and
`_ = : / . , + -`. A ref that names a credential the service does not declare throws. A user
service's unit is `files."/usr/lib/systemd/user/<name>.service"` with its `.wants` links beside it,
no `User=` or `DynamicUser=` line and no sysusers entry; its files still go to `/usr/lib/<name>/`.
An unknown field (`extraArgv`) is a type error.

### `merge`

`merge [ fragmentA fragmentB ]` unions `units`, `files` and `links` (a repeated key throws,
whichever shape the two values have), normalises every file to `{ text; mode; }`, concatenates
`sysusers` and `tmpfiles`, and returns `packages` with each package once. The output's `links` is
one map, path → `{ target; kind }`: the composer derives `/usr/bin/<name>` for every name in a
package's `bin` list (kind `package`) into the same map as the fragments' links, then runs one
duplicate check over the whole map. A path with two sources throws and names both, whatever their
kinds; a link path that collides with a file path is an error too. The one non-duplicate is a
`package` link that repeats a `package` link to the same target: a module that merges its own
fragments with `merge` returns a fragment whose `links` already hold its packages' `/usr/bin` links,
and the composer derives them again. `merge.linkSources fragments` lists every link with its source
and `merge.duplicateLink` returns the message or `null`, so a test can read what the error says.

Error message examples:
`golconda: /usr/bin/jq defined twice: package jq-1.7, explicit link to /nix/store/…/bin/jq`;
`golconda: /usr/lib/x defined twice: explicit link to a, explicit link to b`.

### `/pkgs`

Two options: `target`, the repkgs set of the platform (`nix/packages.nix`), which `nix/default.nix`
passes as `options."/pkgs".target`; and `build`, the build host's set (default
`{ pkgs = target.buildPkgs; }`, the same packages as `target` when not cross). The module returns
`{ target; build; pkgs; }`, `pkgs` being `target.pkgs`. A module that needs a package declares
`inputs.pkgs.path = "/pkgs"` and reads `results.pkgs.pkgs.<name>`; a package option defaults with
`defaultFunc = { results }: ...`. A tree without `target` throws when a module first needs a
package. A module never imports repkgs and never reads a set it did not declare; a second kind of
set is a second module path, never a second argument. `target` is the one option that is not
configuration data: the TOML loader refuses a `/pkgs` table, and `configLib.withPkgs set` binds the
set instead.

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

tmpfiles: one `L /etc/<path> - - - - /usr/share/factory/etc/<path>` line per factory file (`L`, not
`L+`: a regular file an admin put at that path wins and stays), `d /etc/ssh 0755`, `localtime` and
`os-release` → `../usr/lib/os-release` as `L` lines, and `d /var/empty 0755`. No manifest, no stamp:
`find /etc -type f` lists the admin's changes.

The manifest has one line per factory path, sorted: `f <mode> root:root <sha256> /etc/<path>` for a
file, `l - root:root <target> <path>` for a symlink, `d 0755 root:root - <path>` for a directory.
Two modules that write one factory path are a composer error, like any duplicate file.

### `/services/sshd`

One fragment: the host key var `sshd-hostkey` (credential `sshd-hostkey.key`, passed with `-h`),
`sshd.service` (`ExecStart=/usr/bin/sshd -D -e -f /usr/lib/sshd/sshd_config -h %d/hostkey …`;
`KillMode=process`: sessions outlive a restart; no `RuntimeDirectory=`, the privilege-separation
directory is `/var/empty` from `/factory`), the files under `/usr/lib/sshd/`, and, when their
options are on, the admin vars `sshd-host-cert` and `sshd-revoked-keys`. The generated `sshd_config`
fixes `PasswordAuthentication no`, `KbdInteractiveAuthentication no`,
`ChallengeResponseAuthentication no`, `PermitRootLogin prohibit-password`, `UsePAM yes`,
`LogLevel VERBOSE` and `Subsystem sftp internal-sftp`; no option changes them
([design/trust](../../design/trust.md#identity)). `/etc/pam.d/sshd` comes from `/factory`.

| option              | type                                       | rendered as                                                                                                          |
| ------------------- | ------------------------------------------ | -------------------------------------------------------------------------------------------------------------------- |
| `package`           | derivation, default `pkgs.openssh`         | from `/pkgs`; `program = "sshd"`                                                                                     |
| `port`              | int, default `22`                          | `Port`                                                                                                               |
| `authorizedKeys`    | list of string, default `[ ]`              | `/usr/lib/sshd/authorized_keys/root`; bootstrap only                                                                 |
| `trustedUserCAKeys` | list of string, default `[ ]`              | `/usr/lib/sshd/ca.pub` and `-o TrustedUserCAKeys=/usr/lib/sshd/ca.pub`                                               |
| `principals`        | attrs user → list of string, default `{ }` | `/usr/lib/sshd/principals/<user>` and `-o AuthorizedPrincipalsFile=/usr/lib/sshd/principals/%u`                      |
| `revokedKeys`       | bool, default `false`                      | admin var `sshd-revoked-keys`; `LoadCredentialEncrypted=krl:sshd-revoked-keys.krl`, `-o RevokedKeys=%d/krl`          |
| `hostCertificate`   | bool, default `false`                      | admin var `sshd-host-cert`; `LoadCredentialEncrypted=hostcert:sshd-host-cert.cert`, `-o HostCertificate=%d/hostcert` |

`sshd_config` holds `AuthorizedKeysFile .ssh/authorized_keys /usr/lib/sshd/authorized_keys/%u`.
`revokedKeys` and `hostCertificate` declare admin-supplied vars (a KRL and the signed host
certificate); they reach sshd on the command line because `sshd_config` cannot refer to the
credentials directory, and an app file may not ([`app`](#app)).
