# Configuration format

A Golconda configuration is a TOML document where each table sets options for one module. The loader
is `lib/config.nix`; the schema that validates a document is `lib/schema.nix`
([Outputs](outputs.md#schema)). Why it has this shape: [design/config](../design/config.md).

## Document format

Table names are adios absolute paths, starting with `/`:

```toml
["/system"]
name = "server"
version = "20261031.1"
updateSource = "https://updates.example.com/server/"

["/services/sshd"]
port = 22
authorizedKeys = [
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExample admin@example.com",
]
trustedUserCAKeys = ["ssh-ed25519 AAAA... user-ca"]
["/services/sshd".principals]
root = ["alice@example.com"]

["/network"]
dns = ["192.0.2.53"]
```

An unknown table name throws with the list of valid paths, and an option name the module does not
declare throws with the valid names: a misspelt `prot = 2222` is an error, not a silent port 22. A
`/pkgs` table throws: the package set is not data.

## Valid paths

```sh
iets eval --json -E '(import ./default.nix).configLib.validPaths'
```

| path             | options                                                                                                             |
| ---------------- | ------------------------------------------------------------------------------------------------------------------- |
| `/base`          | `ntp`, `journalMaxUse`                                                                                              |
| `/factory`       | `timezone`, `extraFiles`                                                                                            |
| `/network`       | `networks`, `dns`, `defaultDhcp`                                                                                    |
| `/system`        | `name`, `version`, `updateSource`, `fragments` (a list of tables; `packages` in a fragment is Nix only)             |
| `/services/sshd` | `package` (Nix only), `port`, `authorizedKeys`, `trustedUserCAKeys`, `principals`, `revokedKeys`, `hostCertificate` |

The option types, defaults and descriptions are on the generated module pages
([Modules](modules/README.md)).

A `/network.networks` entry takes the required table `match`, plus the optional tables `network`,
`link`, `dhcpv4`, `address` and `route`, one for each section of a `.network` file. Any other key,
including a capitalised `Network`, is refused by name when the document is evaluated.

A fragment of `units`, `files`, `sysusers`, `tmpfiles` and `links` is plain data and loads from
TOML, as an array of tables:

```toml
[["/system".fragments]]
name = "motd"
files = { "/usr/lib/motd" = "hello\n" }
tmpfiles = ["d /var/lib/motd 0755 root root -"]
```

Only `packages` needs Nix, because a package is a derivation.

## Validation

Export the schema and use any JSON Schema validator:

```sh
iets eval --json -E '(import ./default.nix).schema' > schema.json
yj -tj < examples/server.toml > config.json      # TOML → JSON
ajv validate -s schema.json -d config.json
```

Golconda ships no validator; type errors from adios say what a module expected, and the schema is
for editors and external tools.

## The entry point

`lib/system.nix` turns a document into a system:
`mkSystem { config; platform?; system?; sources?; extra?; }`, exposed as the output `lib.mkSystem`.
`golconda.nix` at the repository root is the template a user copies next to `server.toml`;
`examples/golconda.nix` does the same from inside the repository:

```nix
let
  golconda = import (import ./npins).golconda; # pinned with npins
in
golconda.lib.mkSystem {
  config = ./server.toml;
  system = "x86_64-linux"; # the build host; left out, `iets eval` needs --impure
  # platform = "aarch64-linux";  # default: the build host's
  # extra = {                   # Nix-only options, merged into the TOML
  #   "/services/sshd".package = myOpenSSH;
  # };
}
```

| argument   | meaning                                                                                                            |
| ---------- | ------------------------------------------------------------------------------------------------------------------ |
| `config`   | a path to a TOML file, or an attribute set of options already loaded                                               |
| `platform` | the target platform, default `system`                                                                              |
| `system`   | the build host, default `builtins.currentSystem`, which `iets eval` refuses unless `--impure`: pass it explicitly  |
| `sources`  | the pins, default `nix/sources.nix`                                                                                |
| `extra`    | Nix-only options merged into the TOML's, one module path at a time (a package override, a fragment written in Nix) |

`mkSystem` binds `/pkgs.target` to the platform's set, turns every `/services/*` table into that
module's fragment, adds `/vars` and `/factory`, composes, and returns:

| field             | content                                                                    |
| ----------------- | -------------------------------------------------------------------------- |
| `composed`        | the composer output ([Modules](modules/README.md#the-composer-output))     |
| `usrTree`         | the `/usr` tree derivation with the artifacts in `/usr/lib/golconda/`      |
| `config`          | the normalized options by module path, derivations replaced by their names |
| `platform`        | the elaborated platform record                                             |
| `version`, `name` | from `/system`                                                             |
| `pkgs`            | the platform's packages                                                    |

```sh
iets eval -E '(import ./examples/golconda.nix).usrTree.outPath'
nix-build -E '(import ./examples/golconda.nix).usrTree'    # through the patched daemon
```

`mkSystem` is the one entry point that applies a document. The loader alone is `configLib`
([Outputs](outputs.md#configlib)): it turns a document into checked options and applies nothing.
`mkSystem` runs the same option check over an attribute-set `config` and over `extra`, so every
route into the tree is checked.

## Nix escapes

TOML covers the common path. Nix stays necessary for a custom module (a service not in the tree), a
package not in repkgs, and logic (a value shared between options, a conditional). A document cannot
name a derivation or a function.
