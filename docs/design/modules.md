# Modules

A Golconda configuration is a list of typed fragments composed by one function. There is no global
namespace to merge, so there are no priorities, and a duplicate definition is an error instead of a
silent override.

```mermaid
flowchart TD
  subgraph tree["/ (adios tree, modules/)"]
    system["/system: the composer"]
    svc1["/services/sshd"]
    svc2["/services/nginx"]
    net["/network"]
  end
  svc1 -->|fragment| system
  svc2 -->|fragment| system
  net -->|fragment| system
  lib["modules/lib: fragment, app, service, var types"] -.->|checks| system
  system --> out["{ units; files; sysusers; tmpfiles; packages }"]
  out --> image[image builder]
```

## A fragment

```nix
{
  units."sshd.service" = "...";          # /usr/lib/systemd/system
  files."/usr/lib/sysusers.d/sshd.conf" = "u sshd - ...";   # text: mode 0644
  files."/usr/lib/golconda/run" = { text = "#!/bin/sh ..."; mode = "0755"; };
  sysusers = [ "u sshd - \"SSH daemon\"" ];
  tmpfiles = [ "d /var/lib/sshd 0700 root root -" ];
  packages = [ pkgs.openssh ];
}
```

Every field is optional and typed by `fragment` in `modules/lib/fragment.nix` (korora). A module's
`impl` returns one.

## `app` and `service`

Above the fragment sits a typed `app`: package, argv, env and files. A `service` embeds an `app` and
adds `extraArgv` (which may hold credential refs), state directories, credentials, sandbox profile
and user. Credential refs are refused inside `app` because it has no credentials directory.

Renderers turn these values into fragments:

- **Wrapped relocatable binary.** The repkgs `launch` record bakes argv and env into the output; a
  future `wrap` package shape will add config files. *(planned)*
- **systemd unit.** `ExecStart=` points at the wrapped binary; `LoadCredentialEncrypted=` names
  credentials; `StateDirectory=` names state.
- **User unit.** The same, for `systemd --user`. *(planned)*

Config goes to `/usr/lib/<name>/` or into the wrapper, never to `/etc`. The image holds no
per-machine values. A program that insists on `/etc` gets a tmpfiles `L` symlink.

An `app` file must not carry a per-machine value: one image serves every machine, so a credential
path (`%d/`, `$CREDENTIALS_DIRECTORY`) or a key (`-----BEGIN`, `PRIVATE KEY`) in its text is a type
error that names the file. A secret is a credential, named in the unit's `extraArgv` and read from
the credentials directory at run time.

A service is on when its fragment is in `fragments`; there is no `enable` flag. A secret is a
`{ credential = "n"; }` reference, accepted only in the unit's `extraArgv` and rendered as `%d/n`
from `LoadCredentialEncrypted=`. A var is a fragment too: a oneshot unit that generates the secret
on the machine on first boot and seals it to the TPM. A module that returns several fragments unions
them with the composer's own `merge`, so a duplicate inside one module is the same error as one
between modules. Types and renderers: [reference/modules](../reference/modules/README.md).

## The composer

`/system` takes `name`, `version` and `fragments`. Attribute-set fields are unioned and a key that
appears twice throws with the key's name; list fields are concatenated. Every file comes out as
`{ text; mode; }`, so the image builder reads one shape. The result is the only thing the image
builder reads. The `packages` list is checked too: two packages that install the same `/usr/bin`
name throw, because the image builder links them into one directory.

## Why not the NixOS module system

NixOS merges every module into one global configuration through a fixpoint, which is why `mkForce`
exists and why evaluation is heavy. adios modules declare their inputs, are checked lazily, and
compose by explicit function application. A module that wants to change another's output calls it
and transforms the result; nothing acts at a distance.
