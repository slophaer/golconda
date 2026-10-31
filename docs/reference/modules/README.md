# Modules

The adios module tree lives in `modules/`. Each module returns a typed fragment for the composer.
The [generated module pages](generated/index.md) cover each module's options and doc comment; the
[types page](generated/types.md) documents every type from the schema registry. Why the tree has
this shape: [design/modules](../../design/modules.md).

## Modules

| path             | role                                                                                                                                |
| ---------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| `/system`        | the composer: `name`, `version`, `updateSource`, `fragments` → the output below                                                     |
| `/pkgs`          | the repkgs sets, passed once as `target` (and `build`); returns `{ target; build; pkgs }` to the modules that declare the input     |
| `/base`          | implicit, merged first: systemd, dbus-broker, dash, uutils coreutils, the kernel, the base units, `C.UTF-8`, `ntp`, `journalMaxUse` |
| `/network`       | implicit: networkd `.network` files (DHCP on every wired link by default) and resolved's fallback `dns`                             |
| `/factory`       | the `/etc` seed under `/usr/share/factory/etc`, the tmpfiles `L` lines that link it, the sshd user (below)                          |
| `/vars`          | installs `/usr/lib/golconda/golconda-var-run` (mode `0755`); add once when any var is used                                          |
| `/services/sshd` | OpenSSH as a service with its configuration under `/usr/lib/sshd/` and an ed25519 host key var; keys and certificates only          |

## The composer output

`/system` returns
`{ name; version; updateSource; units; files; sysusers; tmpfiles; packages; packageOrigins; links }`:

| field            | shape                              | installed as                                                                                    |
| ---------------- | ---------------------------------- | ----------------------------------------------------------------------------------------------- |
| `units`          | `{ unitName = text; }`             | `/usr/lib/systemd/system/<name>`; user units are `files`                                        |
| `files`          | `{ path = { text; mode; }; }`      | the path, under `/usr`                                                                          |
| `sysusers`       | `[ line ]`                         | `/usr/lib/sysusers.d/golconda.conf`                                                             |
| `tmpfiles`       | `[ line ]`                         | `/usr/lib/tmpfiles.d/golconda.conf`                                                             |
| `packages`       | `[ drv ]`                          | the closure in `/usr/nix/store`, each package once                                              |
| `packageOrigins` | `{ "name-version" = [ origin ]; }` | `/usr/lib/golconda/packages.json`: `/base`, `/network`, a fragment's `name` or `fragments[<i>]` |
| `links`          | `{ path = { target; kind; }; }`    | every symlink of `/usr`: `/usr/bin`, expanded directories, dlopen sonames, `.wants`             |

## Shared types (`modules/lib/`)

Plain files that modules import. The directory has no `default.nix`, so adios does not load it.

| file               | exports                                                                                                                                                                                                       |
| ------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `fragment.nix`     | `fragment`: `{ name; units; files; sysusers; tmpfiles; packages; links }`, every field optional, no other field; `units`, `unitName`, `unitText`, `unitSuffixes`, `file`, `mode`, `links`, `link`, `linkKind` |
| `merge.nix`        | `merge [ fragment… ]` → the output above without `name`/`version`; `linkSources`, `duplicateLink` expose the link check; `pkgKey` the package key                                                             |
| `app.nix`          | `app`, `argv`, `files`, `perMachineMarkers`, `envOp`, `credentialRef`, `isCredentialRef`, `binName`, `exe`                                                                                                    |
| `service.nix`      | `service`, `render`, `filesDir`, `sandbox`, `sandboxLines`, `killMode`, `scope`, `credential`, `credentialArg`                                                                                                |
| `var.nix`          | `var`, `render`, `adminVar`, `admin`, `unitName`, `credentialId`, `stateDir`                                                                                                                                  |
| `ini.nix`          | `render`: an attribute set of sections to INI text (sysupdate definitions)                                                                                                                                    |
| `golconda-var-run` | POSIX sh runner for var units                                                                                                                                                                                 |

### `fragment`

The return type of every module.

| field      | type                                         | installed to                                                                  |
| ---------- | -------------------------------------------- | ----------------------------------------------------------------------------- |
| `name`     | string                                       | nowhere: the origin label in `packageOrigins` (a module sets its path)        |
| `units`    | attrs `unitName` → `unitText`                | `/usr/lib/systemd/system/<name>`                                              |
| `files`    | attrs path → file                            | the path (must start with `/usr`)                                             |
| `sysusers` | list of string                               | `/usr/lib/sysusers.d/` lines                                                  |
| `tmpfiles` | list of string                               | `/usr/lib/tmpfiles.d/` lines                                                  |
| `packages` | list of derivation                           | `/usr/nix/store` closure; every name in `bin` becomes `/usr/bin/<name>`       |
| `links`    | attrs path under `/usr` → `{ target; kind }` | the other symlinks of `/usr`: `.wants`, directories to expand, dlopen sonames |

A `link` is `{ target; kind; }`; its path is the key. `kind` is one of `package` (`/usr/bin/<name>`
from a `bin` list; the composer derives these, a fragment rarely writes one), `farm` (the target is
a directory the builder links file by file: `lib/udev/rules.d` of a prefixed package), `dlopen` (a
soname the builder checks resolves) or `explicit` (anything else; a `.wants` link has a relative
target). A path outside `/usr/`, a missing `target` or `kind`, or an unknown kind is a type error
that names the path. The fragment refuses any other field.

A `file` is either the text (installed with mode `0644`) or `{ text; mode ? "0644"; }`, where `mode`
is four octal digits (`"0755"` for an executable). The composer's output always has the record
shape. An `app`'s files are text only.

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
| `sandbox`          | `"strict"`, `"default"` or `"trusted"`, required                                         | the tier's directives (below)                                                    |
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

#### Sandbox tiers

| tier      | directives                                                                                                                                                                                                                                                                                                                                 | for                                                                                                    |
| --------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------ |
| `trusted` | none                                                                                                                                                                                                                                                                                                                                       | a program that must see the real system (sshd spawns user sessions); the module's doc comment says why |
| `default` | `NoNewPrivileges`, `PrivateTmp`, `ProtectSystem=strict`, `ProtectHome`, `ProtectControlGroups`, `ProtectKernelModules`, `ProtectKernelTunables`, `ProtectKernelLogs`, `RestrictRealtime`, `RestrictNamespaces`, `RestrictSUIDSGID`, `LockPersonality`, `RemoveIPC`                                                                         | a new service, unless it has a reason                                                                  |
| `strict`  | `default` plus `CapabilityBoundingSet=`, `PrivateDevices`, `PrivateUsers`, `ProtectClock`, `ProtectHostname`, `ProtectProc=invisible`, `ProcSubset=pid`, `RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6`, `MemoryDenyWriteExecute`, `SystemCallArchitectures=native`, `SystemCallFilter=@system-service` minus `@privileged @resources` | a daemon that needs no capability and no device                                                        |

The sets are `sandboxLines` in `service.nix`; which directives the user manager honours is verified
on a running system.

### `merge`

`merge [ fragmentA fragmentB ]` unions `units`, `files` and `links` (a repeated key throws,
whichever shape the two values have), normalises every file to `{ text; mode; }`, concatenates
`sysusers` and `tmpfiles`, returns `packages` with each package once, and records in
`packageOrigins` which fragments (by `name`, or `fragments[<i>]`) brought each. The output's `links`
is one map: the composer derives `/usr/bin/<name>` for every name in a package's `bin` list (kind
`package`) into the same map as the fragments' links, then runs one duplicate check over the whole
map. A path with two sources throws and names both, whatever their kinds; a link path that collides
with a file path is an error too. The one non-duplicate is a `package` link that repeats a `package`
link to the same target: a module that merges its own fragments with `merge` returns a fragment
whose `links` already hold its packages' `/usr/bin` links, and the composer derives them again.
`merge.linkSources fragments` lists every link with its source and `merge.duplicateLink` returns the
message or `null`, so a test can read what the error says.

Error message examples:
`golconda: /usr/bin/jq defined twice: package jq-1.7, explicit link to <store path>/bin/jq`;
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

### `/base` and `/network`

`/system` declares both as inputs and merges their fragments first; a configuration never lists
them. `/base` returns the packages systemd, dbus-broker, dash, uutils-coreutils and linux-kernel;
the `dbus.socket` unit and the `dbus.service` alias; the `.wants` links for `dbus.socket`,
`systemd-networkd` (service and socket), `systemd-resolved` and `systemd-timesyncd`; `/usr/bin/sh` →
dash; the `farm` links for systemd's unit, generator, preset, sysusers, tmpfiles and udev
directories; the `dlopen` link `libsystemd.so.0`; `timesyncd.conf.d/golconda.conf` from `ntp`,
`journald.conf.d/golconda.conf` from `journalMaxUse`, `/usr/lib/locale.conf` (`LANG=C.UTF-8`), and
the `messagebus` user. `/network` returns one `.network` file per entry of `networks` under
`/usr/lib/systemd/network/`, with `default-dhcp` (`Match Type=ether`, `DHCP=yes`,
`IPv6AcceptRA=yes`) unless `defaultDhcp = false`, and `resolved.conf.d/golconda-dns.conf` when `dns`
is set.

### `/factory`

One fragment: the files under `/usr/share/factory/etc` and the tmpfiles lines that link them into
`/etc`. The factory knows no service: a service's user and directories are in its own fragment, and
only `/etc` content is here (`pam.d/sshd`, which sshd refuses to start without; a configuration with
`/services/sshd` adds `/factory` once).

| option       | type                             | rendered as                                                                                            |
| ------------ | -------------------------------- | ------------------------------------------------------------------------------------------------------ |
| `timezone`   | zone name, default `"UTC"`       | `L /etc/localtime - - - - /usr/share/zoneinfo/<timezone>`                                              |
| `extraFiles` | attrs path under `/etc` → `file` | more seeds; a built-in path or `passwd`, `group`, `shadow`, `gshadow`, `machine-id`, `hostname` throws |

Built-in seeds: `shells` (`/usr/bin/sh`, `/usr/bin/dash`), `pam.d/other` (every type `pam_deny`),
`pam.d/sshd` (`account pam_unix`; `session pam_systemd` optional, `session pam_unix`; no `auth`
line, so an auth request falls through to `other`), `ssl/anchors/.keep`, `ssl/blocklist/.keep`,
`pkcs11/.keep`. Never seeded: `passwd`, `group`, `shadow` (systemd-sysusers writes them on first
boot), `machine-id` (PID 1) and `hostname` (systemd-firstboot from the bootstrap credential).

tmpfiles: one `L /etc/<path> - - - - /usr/share/factory/etc/<path>` line per factory file (`L`, not
`L+`: a regular file an admin put at that path wins and stays), `localtime` and `os-release` →
`../usr/lib/os-release` as `L` lines, and `d /etc/ssh 0755`. Two modules that write one factory path
are a composer error, like any duplicate file.

### `/services/sshd`

One fragment: the host key var `sshd-hostkey` (credential `sshd-hostkey.key`, passed with `-h`),
`sshd.service` (`ExecStart=/usr/bin/sshd -D -e -f /usr/lib/sshd/sshd_config -h %d/hostkey …`;
`KillMode=process`: sessions outlive a restart; sandbox `trusted`, because the sessions it spawns
must see the real system), the files under `/usr/lib/sshd/`, the privilege-separation user
(`u sshd - "SSH privilege separation" /var/empty`) with its directory (`d /var/empty 0755`; no
`RuntimeDirectory=`, repkgs' openssh is built with `--with-privsep-path=/var/empty`), and, when
their options are on, the admin vars `sshd-host-cert` and `sshd-revoked-keys`. Only credentials go
on the command line; every fixed path is a line in `sshd_config`. The generated `sshd_config` fixes
`PasswordAuthentication no`, `KbdInteractiveAuthentication no`,
`ChallengeResponseAuthentication no`, `PermitRootLogin prohibit-password`, `UsePAM yes`,
`LogLevel VERBOSE`, `PidFile none` and `Subsystem sftp internal-sftp`; no option changes them
([design/trust](../../design/trust.md#identity)). `/etc/pam.d/sshd` comes from `/factory`.

| option              | type                                       | rendered as                                                                                                          |
| ------------------- | ------------------------------------------ | -------------------------------------------------------------------------------------------------------------------- |
| `package`           | derivation, default `pkgs.openssh`         | from `/pkgs`; `program = "sshd"`                                                                                     |
| `port`              | int, default `22`                          | `Port`                                                                                                               |
| `authorizedKeys`    | list of string, default `[ ]`              | `/usr/lib/sshd/authorized_keys/root`; bootstrap only                                                                 |
| `trustedUserCAKeys` | list of string, default `[ ]`              | `/usr/lib/sshd/ca.pub` and `TrustedUserCAKeys /usr/lib/sshd/ca.pub` in `sshd_config`                                 |
| `principals`        | attrs user → list of string, default `{ }` | `/usr/lib/sshd/principals/<user>` and `AuthorizedPrincipalsFile /usr/lib/sshd/principals/%u` in `sshd_config`        |
| `revokedKeys`       | bool, default `false`                      | admin var `sshd-revoked-keys`; `LoadCredentialEncrypted=krl:sshd-revoked-keys.krl`, `-o RevokedKeys=%d/krl`          |
| `hostCertificate`   | bool, default `false`                      | admin var `sshd-host-cert`; `LoadCredentialEncrypted=hostcert:sshd-host-cert.cert`, `-o HostCertificate=%d/hostcert` |

`sshd_config` holds `AuthorizedKeysFile .ssh/authorized_keys /usr/lib/sshd/authorized_keys/%u`.
`revokedKeys` and `hostCertificate` declare admin vars (a KRL and the signed host certificate); they
reach sshd on the command line because `sshd_config` cannot refer to the credentials directory, and
an app file may not ([`app`](#app)).
