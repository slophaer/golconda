# console

Golconda's console: the `golconda` command line now, the `golcondad` daemon and its web pages later
(design: the UI design note in the knowledge base). Rust, built with repkgs' toolchain like every
Golconda package (`console/package.nix`, `packages.<system>.golconda-console`).

- `core/`: the `golconda-core` library. It evaluates a system's document with Golconda's `mkSystem`
  through the `iets` binary, one process per evaluation, and reads its `config`, `schema` and
  `moduleDocs`; it finds options in the schema and in the TOML document.
- `core/src/vars.rs`: admin vars from the deploy host: the age-encrypted store, the machine's
  manifests over ssh, the push.
- `cli/`: the `golconda` binary.

## Use

```sh
golconda config show -f examples/server.toml          # every option, defaults marked
golconda config show --set -f examples/server.toml    # what the document sets
golconda config explain -f examples/server.toml /services/sshd port
golconda config explain --json -f server.toml /network networks.lan.network.DNS
```

Admin vars ([Trust: Secrets and vars](../docs/design/trust.md#secrets-and-vars)): the values a
machine's image names but never contains, such as its host certificate. They are kept in the
configuration repository, age-encrypted to the keys in `vars/recipients.txt`, and pushed over ssh;
the machine seals each one with its own `systemd-creds` and the units that read it restart.

```sh
golconda vars pub web1 sshd-hostkey key.pub > host.pub
ssh-keygen -s host_ca -h -I web1 -n web1 host.pub    # the host CA signs it: host-cert.pub
golconda vars set web1 sshd-host-cert cert < host-cert.pub
golconda vars set web1 sshd-revoked-keys krl < revoked.krl
golconda vars push -i ~/.config/age/key.txt web1     # every admin var web1 declares
golconda vars list web1                              # stored here? sealed there?
```

`push` reads the manifests from the machine itself, checks that every file is stored before it sends
any, and restarts each consumer once. Rotation is `set` and `push` again. `age` (or `rage`) and
`ssh` are programs on the deploy host: `GOLCONDA_AGE` and `GOLCONDA_SSH` replace them, with
arguments.

An option is a module path and an option path inside it, dotted below the first level. iets comes
from PATH, or `GOLCONDA_IETS`. The document must be inside a Golconda checkout (a directory above it
has `lib/system.nix`): evaluation is pure and reads files under the checkout only.

## Develop

cargo, rustc and the C linker come from repkgs (`pkgs.rust` and the set's `toolchain`), so they need
a build host for repkgs (docs/reference/build-host.md). With them and iets on PATH:

```sh
cd console
cargo test                          # unit tests, and the CLI's that need no evaluation
cargo test -- --include-ignored     # also the CLI against examples/server.toml, through iets
```

The ignored tests need iets and the checkout around this directory, which the package build does not
have. `treefmt` formats the Rust code.
