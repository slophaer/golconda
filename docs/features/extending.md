# Your own modules and packages

You extend Golconda from your own repository, beside the TOML document. Your modules and packages
follow the same layout and the same rules as Golconda's. They get types, a schema entry, an SBOM
entry and update tracking. A package that replaces one of Golconda's is a stated choice, never a
name collision.

## How it works

- **Modules.** A `modules/` directory beside the document mounts under `/local`. A module in
  `modules/motd/default.nix` is `/local/motd`. A table `["/local/motd"]` selects it, as it selects
  `/services/sshd`. The optional `[golconda] modules = "site"` names another directory.
- **Golconda's library.** A module that declares the input `/golconda-lib` gets the libraries of
  Golconda's own modules: `service`, `var`, `merge` and `fragment`. A service that `service.render`
  makes has a sandbox tier, checked credential references and app files with no per-machine value,
  as `/services/sshd` has.
- **Packages.** A `packages/` directory beside the document adds packages to the target set after
  Golconda's own. Each package is a directory with a `package.nix` and a `sources.toml`, the layout
  of Golconda's `packages/`. `[golconda] packages = "…"` names another directory.
- **Replacing is opt-in.** A downstream package that takes the name of a Golconda or repkgs package
  replaces it only when `[golconda] replaces` lists the name. Without the entry, evaluation fails
  and names the package. An entry that no package uses is also an error, so the list says exactly
  what you replace.
- **A replacement reaches everything.** It applies to the image, the initrd, the loader and the
  keyring, so a replaced kernel, systemd or signing tool is trusted code. Golconda does not check
  what it does. Whoever lists it owns the review.
- **The record.** `mkSystem` returns your module's role and why it is included (`inventory`). It
  also returns each downstream package (`packages`): `{ "openssh": { "replaces": "golconda" } }`
  (`"repkgs"` for one of the fork's, `null` for a new name). The SBOM marks the component
  `golconda:origin = downstream`. A replacement names the package it replaced in
  `pedigree.ancestors`.

## Using it

```text
my-servers/
├── server.toml
├── golconda.nix             # examples/golconda.nix: fetches Golconda, calls lib.mkSystem
├── pins/golconda/           # the Golconda pin, in uptrack's format
├── modules/
│   └── motd/default.nix     # /local/motd
└── packages/
    └── openssh/             # package.nix, sources.toml
```

How to pin Golconda (uptrack, a flake or `fetchTarball`) is in
[Pinning Golconda](../reference/pinning.md).

```toml
["/local/motd"]
text = "hello\n"

[golconda]
replaces = ["openssh"]
```

A module looks like the one on [Typed modules](typed-modules.md#using-it). The full example is in
[Reference: your own modules](../reference/config.md#your-own-modules).

### A service of your own

This module runs `myapp`, a package in `packages/` beside the document, as a service. It reads the
package from `/pkgs` and the renderer from `/golconda-lib`:

```nix
# modules/myapp/default.nix: /local/myapp
{ types, ... }:
{
  name = "myapp";
  inputs = {
    golconda.path = "/golconda-lib";
    pkgs.path = "/pkgs";
  };
  options.port = {
    type = types.int;
    default = 8080;
    description = "The port that myapp listens on.";
  };
  impl =
    { options, results, ... }:
    let
      inherit (results.golconda) service;
    in
    service.render {
      name = "myapp";
      app = {
        package = results.pkgs.pkgs.myapp;
        argv = [
          "--config"
          "${service.filesDir "myapp"}/myapp.toml"
        ];
        files."myapp.toml" = "port = ${toString options.port}\n";
      };
      user = "root";
      sandbox = "strict";
    };
}
```

The result is `myapp.service` with `ExecStart=/usr/bin/myapp --config /usr/lib/myapp/myapp.toml`,
the directives of the `strict` tier and a link from `multi-user.target`. A secret is a credential
reference in `argv` (`service.credential "key"`). The service declares it in `credentials`, and a
var seals it (`var.render`, `var.admin`). The fields of `service` are in
[Modules: `app` and `service`](../design/modules.md#app-and-service).

## Status

Proven: the rows of [What is proven](../proven.md) that name `tests/eval/components.nix` and
`tests/eval/provenance.nix`. The limits are below.

## Limits

- No boot test has a downstream package. The boot-test image carries one downstream service,
  `/local/test-workload` (`tests/fixtures/image-workload/modules`), which `service.render` makes.
- A module takes its packages from the target set. To use another build of one of them, such as
  OpenSSH, a downstream package replaces it (`[golconda] replaces`).
- repkgs refuses a package that takes the name of one of its aliases: it applies aliases last, so
  the alias would win.
- Golconda reviews no replacement. A replacement can drop the IPE policy, the verity key or the boot
  checks.
- A downstream module is not in the generated module pages. Those cover Golconda's own tree.
- Nix is still the language of a module and a package. The document stays data.

## More

- [Design: Configuration as data](../design/config.md#from-document-to-image)
- [Design: Trust: Downstream packages](../design/trust.md#downstream-packages)
- [Reference: configuration](../reference/config.md#your-own-modules) and
  [your own packages](../reference/config.md#your-own-packages)
- [Configuration as data](config-as-data.md), [Typed modules](typed-modules.md)
