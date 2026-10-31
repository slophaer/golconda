# Modules

A Golconda system is a list of typed fragments composed by one function. A module returns a
fragment; the `/system` composer unions them. There is no global namespace to merge, so there are no
priorities, and a duplicate definition is an error instead of a silent override. The types,
renderers and their fields are in [reference/modules](../reference/modules/README.md); this page
says why they have the shape they have.

```mermaid
flowchart TD
  subgraph tree["/ (adios tree, modules/)"]
    pkgs["/pkgs: the repkgs set"]
    base["/base: what every image contains (implicit)"]
    net["/network: networkd (implicit)"]
    factory["/factory: the /etc seed"]
    vars["/vars: the var runner"]
    sshd["/services/sshd"]
    system["/system: the composer"]
  end
  pkgs -.->|input| base
  pkgs -.->|input| sshd
  base -->|fragment| system
  net -->|fragment| system
  factory -->|fragment| system
  vars -->|fragment| system
  sshd -->|fragment| system
  lib["modules/lib: fragment, app, service, var types"] -.->|checks| system
  system --> out["{ units; files; sysusers; tmpfiles; packages; links }"]
  out --> usr["/usr tree builder"]
```

That is the whole tree today: one service. A second service is a new directory under
`modules/services/`.

## A fragment

A fragment is what a module returns: `units`, `files`, `sysusers`, `tmpfiles`, `packages`, `links`
and an optional `name` (the module's path, for the package origins), every field optional and typed
(korora, `modules/lib/fragment.nix`); an unknown field is a type error. The fields are exactly what
the `/usr` tree builder installs, nothing is interpreted on the way: a unit is text under
`/usr/lib/systemd/system/`, a file is text with a mode under `/usr`, a sysusers or tmpfiles line is
a line, a package is a closure root, a link is a symlink of `/usr`
([Layout: The symlink map](layout.md#the-symlink-map)).

A unit stays text with a typed name (a stem and one of the seven suffixes) and at least one section
header. A typed INI model would add a second place where systemd's semantics are spelled out; the
renderers produce the text and the tests read it.

## How packages enter the tree

The repkgs sets enter the tree once, as the options of `/pkgs`: `target`, the set of the platform
the image runs on (`nix/default.nix` passes it from `nix/packages.nix`), and `build`, the build
host's set for tools that run on the builder (default: the target's `buildPkgs`, the same packages
when not cross). `/pkgs` returns `{ target; build; pkgs; }`. A module that needs a package declares
`inputs.pkgs.path = "/pkgs"` and reads `results.pkgs.pkgs.openssh`; a package-valued option defaults
from there, so a configuration can still replace the package but never has to pass one. This is
adios' own mechanism (a module declares its inputs and receives their results), and it carries one
rule: a module never imports repkgs and never reads a set it did not declare; a second kind of set
is a second module path, never a second argument. No option takes a function, the schema stays
platform-independent, and `/pkgs.target` is the one option that is not configuration data: the TOML
loader refuses it.

The composer records which fragment brought each package (`packageOrigins`: `/base`, `/network`, a
fragment's own `name`, or its index), and the `/usr` tree writes it as
`/usr/lib/golconda/packages.json`, so "why is this here" has an answer without a second declaration.

## The base system

`/base` and `/network` are implicit: `/system` declares them as inputs and merges their fragments
before the configured ones, so a system with no fragments still boots with systemd, D-Bus, a shell,
coreutils, the kernel, DHCP on every wired link, time sync and a bounded journal
([Architecture: What every image contains](architecture.md#what-every-image-contains)). They have
options (`/base.ntp`, `/base.journalMaxUse`, `/network.networks`, `/network.dns`,
`/network.defaultDhcp`) but no switch: there is nothing to turn off.

## `app` and `service`

A `service` is a typed value: an `app` (package, program, argv, env, files: the part that has
nothing to do with systemd) plus what only a unit has (credentials, state directories, sandbox tier,
user, ordering). There is one renderer, `render service`, and one place for a service's
configuration:

- The app's files go to `/usr/lib/<name>/<file>`. The unit says
  `ExecStart=/usr/bin/<program> <argv…>`, and a config path in `argv` is that literal path.
- A secret is a typed reference in `argv`, `{ credential = "n"; }`, rendered as `%d/n` and checked
  against the service's `credentials`. The credential reaches the program from
  `LoadCredentialEncrypted=`, never from a file in the image.
- `systemctl cat <name>` therefore shows the whole command; nothing is baked into a binary and
  nothing is interpolated at run time.

Why not wrap the program into a launcher that carries its configuration? That was tried; it bought
nothing the plain `ExecStart=` does not, and it cost a second renderer, a `/wrap` module, an
exception to the duplicate rule and a unit that hid its arguments. repkgs keeps `wrap` for developer
shells and tools shipped to other hosts, not for services.

An `app` file must not carry a per-machine value: one image serves every machine, so a credential
path or a key marker in its text is a type error that names the file.

The `service` type grows a field when two services would need it and it has one meaning (`killMode`,
`runtimeDirectory`, `scope`); everything else a program needs is its own configuration, which the
module writes into the app's files (sshd's `Subsystem sftp internal-sftp` is `sshd_config` content,
not a unit field). There is no generic escape hatch into the unit text: a module that needs a
directive the type lacks adds the field, with its type, or does without.

### Sandbox tiers

A service names one of three tiers, `strict`, `default` or `trusted`, each a fixed set of
`systemd.exec` hardening directives ([reference](../reference/modules/README.md#sandbox-tiers)). A
new service takes `default` unless it has a reason; `strict` is for a daemon that needs no
capability and no device; `trusted` adds no directive and needs the reason in the module's doc
comment (sshd: it spawns user sessions that must see the real system). The tiers are not a free-form
`systemd.exec` surface on purpose: a hardening line that is right for one service and wrong for
another is a new tier, not an option.

### User services

`service.scope = "user"` renders the same unit for `systemd --user`, under `/usr/lib/systemd/user/`.
`user` and `credentials` are refused: the unit runs as whoever's manager starts it, and Golconda
seals credentials for the system manager only (a per-user credstore would need
`systemd-creds encrypt --user`).

### Vars

A var is a fragment too ([Trust: Secrets and vars](trust.md#secrets-and-vars)): `render var` returns
a oneshot unit that generates the secret on first boot and seals it to the TPM, and the manifest
that names the credential; `admin adminVar` returns the manifest only. A service that consumes a var
names its credential id in `credentials` and orders itself after the var's unit.

## The composer

`/system` takes `name`, `version`, `updateSource` and `fragments`. It merges `/base` and `/network`
first, then the configured fragments, then the sysupdate definitions it renders from `updateSource`.
Attribute-set fields are unioned and a key that appears twice throws with the key's name; list
fields are concatenated; `packages` is one list with each package once, and `packageOrigins` says
which fragments brought it; the symlinks of the packages' `bin` lists go into the same map as the
fragments' own links, and one duplicate check covers the whole map. A module that returns several
fragments unions them with the same `merge`, so a duplicate inside one module is the same error as
one between modules. The output is the only thing the `/usr` tree builder reads.

A service is on when its fragment is in `fragments`; there is no `enable` flag. How a TOML document
puts a fragment there is in [Configuration](config.md#from-document-to-image).

## `/factory`

`/factory` is the one module that may write under `/etc`, and it does so only as the seed in
`/usr/share/factory/etc` plus the tmpfiles `L` lines that link it
([Layout: State](layout.md#state)). It knows no service: a module that needs a file under `/etc`
(sshd's `pam.d/sshd`) has it in the factory because `/etc` content lives there, while the module's
own user and directories are in the module's fragment.

## Why not the NixOS module system

NixOS merges every module into one global configuration through a fixpoint, which is why `mkForce`
exists and why evaluation is heavy. adios modules declare their inputs, are checked lazily, and
compose by explicit function application. A module that wants to change another's output calls it
and transforms the result; nothing acts at a distance.
