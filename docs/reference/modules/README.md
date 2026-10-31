# Modules

The adios module tree lives in `modules/`. Each module returns a typed fragment for the composer.
This page documents every module and the shared types in `modules/lib/`.

## Modules

| path             | role                                                                                            |
| ---------------- | ----------------------------------------------------------------------------------------------- |
| `/system`        | the composer: `name`, `version`, `fragments` → `{ units; files; sysusers; tmpfiles; packages }` |
| `/vars`          | installs `/usr/lib/golconda/golconda-var-run` (mode `0755`); add once when any var is used      |
| `/wrap`          | typed options for repkgs' `wrap`: `package`, `argv`, `env`, `files`; the caller uses `set.wrap` |
| `/services/sshd` | OpenSSH as a service with an ed25519 host key var; options `package`, `port`, `authorizedKeys`  |

## Shared types (`modules/lib/`)

Plain files that modules import. The directory has no `default.nix`, so adios does not load it.

| file               | exports                                                                                                                               |
| ------------------ | ------------------------------------------------------------------------------------------------------------------------------------- |
| `fragment.nix`     | `fragment`: `{ units; files; sysusers; tmpfiles; packages }`, every field optional; `file`, `mode`                                    |
| `merge.nix`        | `merge [ fragment… ] → fragment`: unions attrs, concatenates lists; a duplicate key throws; every file comes out as `{ text; mode; }` |
| `app.nix`          | `app`, `argv`, `envOp`, `credentialRef`, `isCredentialRef`, `file`, `filesPlaceholder`, `exe`                                         |
| `service.nix`      | `service`, `render`, `sandbox`, `sandboxLines`, `credential`, `credentialArg`                                                         |
| `var.nix`          | `var`, `render`, `unitName`, `credentialId`, `stateDir`                                                                               |
| `golconda-var-run` | POSIX sh runner for var units                                                                                                         |

### `fragment`

The return type of every module.

| field      | type               | installed to                         |
| ---------- | ------------------ | ------------------------------------ |
| `units`    | attrs name → text  | `/usr/lib/systemd/system/<name>`     |
| `files`    | attrs path → file  | the path (must start with `/usr`)    |
| `sysusers` | list of string     | `/usr/lib/sysusers.d/` lines         |
| `tmpfiles` | list of string     | `/usr/lib/tmpfiles.d/` lines         |
| `packages` | list of derivation | `/usr/nix/store` closure, `/usr/bin` |

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

A `{ credential = "n"; }` value in `argv` is a type error: an app runs outside systemd.

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

Arguments are escaped (`%` → `%%`, `$` → `$$`). The unit ends with `WantedBy=multi-user.target`.
`credential "n"` builds a plain ref; `credentialArg "RevokedKeys=" "n"` builds one with a prefix,
for programs that take a path as `-o Option=<path>`. A prefix is one word of letters, digits and
`_ = : / . , + -`.

### `merge`

`merge [ fragmentA fragmentB ]` unions `units` and `files` (a repeated key throws, whichever shape
the two values have), normalises every file to `{ text; mode; }`, concatenates `sysusers` and
`tmpfiles`, and checks `packages`: two packages with the same `/usr/bin` name throw.

Error message example: `golconda: /usr/bin name defined twice: jq (jq-1.7, jq-wrap-1.7)`.

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
