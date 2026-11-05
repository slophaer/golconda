# console

Golconda's console: the `golconda` command line now, the `golcondad` daemon and its web pages later
(design: the UI design note in the knowledge base). Rust, built with repkgs' toolchain like every
Golconda package (`console/package.nix`, `packages.<system>.golconda-console`).

- `core/`: the `golconda-core` library. It evaluates a system's document with Golconda's `mkSystem`
  through the `iets` binary, one process per evaluation, and reads its `config`, `schema` and
  `moduleDocs`; it finds options in the schema and in the TOML document.
- `cli/`: the `golconda` binary.

## Use

```sh
golconda config show -f examples/server.toml          # every option, defaults marked
golconda config show --set -f examples/server.toml    # what the document sets
golconda config explain -f examples/server.toml /services/sshd port
golconda config explain --json -f server.toml /network networks.lan.network.DNS
```

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
