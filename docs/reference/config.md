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

| path             | options                                                                                                           |
| ---------------- | ----------------------------------------------------------------------------------------------------------------- |
| `/base`          | `ntp`, `journalMaxUse`                                                                                            |
| `/factory`       | `timezone`, `extraFiles`                                                                                          |
| `/network`       | `networks`, `dns`, `defaultDhcp`                                                                                  |
| `/system`        | `name`, `version`, `updateSource`                                                                                 |
| `/services/sshd` | `package` (a name), `port`, `authorizedKeys`, `trustedUserCAKeys`, `principals`, `revokedKeys`, `hostCertificate` |

The option types, defaults and descriptions are on the generated module pages
([Modules](modules/README.md)).

A `/network.networks` entry takes the required table `match`, plus the optional tables `network`,
`link`, `dhcpv4`, `address` and `route`, one for each section of a `.network` file. Any other key,
including a capitalised `Network`, is refused by name when the document is evaluated.

## Your own modules

Units, files or lines of your own are a module. Put it in `modules/` beside the document; it is
mounted under `/local` and selected by its table, as any optional module:

```
my-servers/
├── server.toml
└── modules/
    └── motd/default.nix      # → /local/motd
```

```nix
# modules/motd/default.nix
{ types, ... }:
{
  name = "motd";
  options.text = {
    type = types.string;
    default = "Welcome\n";
    description = "The message of the day.";
  };
  impl =
    { options, ... }:
    {
      files."/usr/lib/motd" = {
        inherit (options) text;
        mode = "0644";
      };
    };
}
```

```toml
["/local/motd"]
text = "hello\n"
```

The optional `[golconda]` table names another directory, relative to the document:

```toml
[golconda]
modules = "site"
```

The default `modules/` is used when it exists; a directory the table names must exist. The module
gets a schema entry with the file it is declared in, a row in `modules.json`, and the attribution of
what it emits. The generated module pages cover Golconda's own tree only.

## Your own packages

A package option takes a package name, looked up in the target set:

```toml
["/services/sshd"]
package = "openssh"
```

`config.json` keeps the name as written. A downstream repository adds packages in `packages/` beside
the document (or the directory `[golconda] packages = "…"` names), in the layout Golconda's own
`packages/` uses: one directory per package with a `package.nix` and a `sources.toml`, so the
package has a purl, an SBOM entry and update tracking. They join the target set after Golconda's
own. A package that takes an existing name replaces that package for everything that uses it, and
`modules.json` records it under `packages`: `{ "openssh": { "replaces": "golconda" } }` (`"repkgs"`
for one of the fork's, null for a new name). Only target packages can be named; build-host tools
cannot.

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
`mkSystem { config; platform?; system?; sources?; extraFragments?; }` (or `mkSystem ./server.toml`),
exposed as the output `lib.mkSystem`. `examples/golconda.nix` is the template: copy it next to your
`server.toml` and pin Golconda with npins in place of its `import ../default.nix` line. It evaluates
from inside the repository as it stands. `lib.mkImage` takes the same `config` and signs it into an
image ([Outputs](outputs.md#libmkimage)).

```nix
let
  golconda = import (import ./npins).golconda; # pinned with npins; in the repository: import ../default.nix
in
golconda.lib.mkSystem {
  config = ./server.toml;
  system = "x86_64-linux"; # the build host; left out, `iets eval` needs --impure
  # platform = "aarch64-linux";  # default: the build host's
}
```

| argument         | meaning                                                                                                                                 |
| ---------------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| `config`         | a path to a TOML file, or an attribute set of options already loaded                                                                    |
| `platform`       | the target platform, default `system`                                                                                                   |
| `system`         | the build host, default `builtins.currentSystem`, which `iets eval` refuses unless `--impure`: pass it explicitly                       |
| `sources`        | the pins, default `nix/sources.nix`                                                                                                     |
| `extraFragments` | the build's own fragments, each with a `name` (`lib/image`: the loader, the update index, the initrd's tools); listed in `modules.json` |

`extraFragments` adds the image's own fragments (`mkImage`'s loader and keyring) beside the
components; a duplicate claim still fails rather than overrides. It is not configuration: the
document is.

`mkSystem` binds `/pkgs.target` to the platform's set, selects the components (the built-ins, then
every optional component the document has a table for; an empty table selects one with its defaults;
[design/modules](../design/modules.md#which-modules-a-system-has)), composes, and returns:

| field             | content                                                                                               |
| ----------------- | ----------------------------------------------------------------------------------------------------- |
| `composed`        | the composer output ([Modules](modules/README.md#the-composer-output))                                |
| `usrTree`         | the `/usr` tree derivation with the artifacts in `/usr/lib/golconda/`                                 |
| `config`          | the normalized options of every included component and `/system`, derivations replaced by their names |
| `inventory`       | every module's role and inputs; for a component, `included` and `reason`                              |
| `fragments`       | the names of the build's own fragments (`/image/hwdb` and `extraFragments`)                           |
| `packages`        | the downstream packages: name → `{ replaces; }`, `"golconda"`, `"repkgs"` or null                     |
| `artifacts`       | the files `mkSystem` adds to `/usr/lib/golconda/`                                                     |
| `platform`        | the elaborated platform record                                                                        |
| `version`, `name` | from `/system`                                                                                        |
| `pkgs`            | the platform's packages                                                                               |

```sh
iets eval -E '(import ./examples/golconda.nix).usrTree.outPath'
nix-build -E '(import ./examples/golconda.nix).usrTree'    # through the patched daemon
```

`mkSystem` is the one entry point that applies a document. The loader alone is `configLib`
([Outputs](outputs.md#configlib)): it turns a document into checked options and applies nothing.
`mkSystem` runs the same option check over an attribute-set `config`, so every route into the tree
is checked.

## Nix escapes

The document is the whole configuration. Nix is code, and code lives in two places: a module (in
`modules/` beside the document, [Your own modules](#your-own-modules)), which holds logic too (a
value shared between options, a conditional), and a package (in `packages/`,
[Your own packages](#your-own-packages)). A document names a package by name; it cannot name a
derivation or a function.
