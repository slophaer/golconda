# Modules

One page per adios module, generated from its `options` and types. Until the generator exists, the
tree is `modules/`:

| path             | role                                                                                            |
| ---------------- | ----------------------------------------------------------------------------------------------- |
| `/system`        | the composer: `name`, `version`, `fragments` → `{ units; files; sysusers; tmpfiles; packages }` |
| `/vars`          | installs the var runner `/usr/lib/golconda/golconda-var-run` once; add it when any var is used  |
| `/services/sshd` | OpenSSH as a service with an ed25519 host key var; options `package`, `port`, `authorizedKeys`  |

## Shared types and renderers (`modules/lib/`)

Plain files that modules import with `import ../../lib/<file>.nix { inherit types; }`; the directory
has no `default.nix`, so adios does not load it as a module.

| file               | exports                                                                                                               |
| ------------------ | --------------------------------------------------------------------------------------------------------------------- |
| `fragment.nix`     | `fragment`: `{ units; files; sysusers; tmpfiles; packages }`, every field optional                                    |
| `merge.nix`        | `merge [ fragment… ] → fragment`: the composer's union; a repeated `units` or `files` key throws                      |
| `app.nix`          | `app`: `{ package; argv; env; files }`; `credentialRef`; `file "name"` → `{files}/name`; `exe app` → `/usr/bin/<bin>` |
| `service.nix`      | `service`: `{ name; app; extraArgv; credentials; state; user; sandbox; after; wants }`; `render service → fragment`   |
| `var.nix`          | `var`: `{ name; secrets; publics; after; script; packages }`; `render var → fragment`; `unitName`; `credentialId`     |
| `golconda-var-run` | the POSIX sh runner of a var unit (installed by `/vars`)                                                              |

### `app`

| field     | type                                                                | rendered as                                                          |
| --------- | ------------------------------------------------------------------- | -------------------------------------------------------------------- |
| `package` | derivation                                                          | `packages`; the program is its first repkgs `bin` (`/usr/bin/<bin>`) |
| `argv`    | list of string, default `[ ]`                                       | after the program; `{files}` expands to the files directory          |
| `env`     | attrs of one-key `{ set \| default \| prepend \| append \| unset }` | `Environment=` / `UnsetEnvironment=`                                 |
| `files`   | attrs name → text, default `{ }`                                    | `files."/usr/lib/<service>/<name>"`                                  |

A `{ credential = "n"; }` value in `argv` is a type error: an app runs outside systemd.

### `service`

| field            | type                                                     | rendered as                                                                     |
| ---------------- | -------------------------------------------------------- | ------------------------------------------------------------------------------- |
| `name`           | unit name stem                                           | `units."<name>.service"`, `/usr/lib/<name>/` for files                          |
| `app`            | `app`                                                    | `ExecStart=`, `Environment=`, `files`, `packages`                               |
| `extraArgv`      | list of string or `{ credential = "n"; }`, default `[ ]` | after `app.argv`; a ref renders as `%d/n` and must be declared in `credentials` |
| `credentials`    | attrs name → credstore id, default `{ }`                 | `LoadCredentialEncrypted=name:id`                                               |
| `state`          | list of string, default `[ ]`                            | `StateDirectory=`                                                               |
| `user`           | `"dynamic"`, `"root"` or a sysusers `u` line             | `DynamicUser=yes`, `User=root`, or `User=` plus a sysusers entry                |
| `sandbox`        | `"strict"`, `"default"` or `"trusted"`                   | a fixed set of hardening directives (`sandboxLines`)                            |
| `after`, `wants` | list of unit names, default `[ ]`                        | `After=`, `Wants=`                                                              |

Every argument is escaped for systemd (`%` → `%%`, `$` → `$$`, quotes around whitespace) except
credential references. The unit ends with `[Install] WantedBy=multi-user.target`.

### `var`

`render var` returns `units."golconda-var-<name>.service"` (oneshot, `RemainAfterExit=`,
`ConditionPathExists=!/var/lib/golconda/vars/<name>/done`, `After=`/`Requires=` the vars in
`after`), `files."/usr/lib/golconda/vars.d/<name>.json"` (the manifest: name, secrets, publics,
after, credential ids) and `files."/usr/lib/golconda/vars.d/<name>.sh"` (the script). On the machine
the runner executes the script in `$RUNTIME_DIRECTORY`, seals each secret with
`systemd-creds encrypt --with-key=tpm2 --tpm2-public-key-pcrs=11 --name=<name>.<file>` into
`/etc/credstore.encrypted/<name>.<file>`, copies the publics to
`/var/lib/golconda/vars/<name>/pub/`, deletes the plaintext and touches `done`. A consumer names the
credential id `<name>.<file>` in `service.credentials` and orders itself after
`golconda-var-<name>.service`.
