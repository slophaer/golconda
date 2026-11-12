# Typed modules, duplicates are errors

Every part of a Golconda image comes from a typed module. Two modules cannot set the same thing: the
build stops and names both. There are no priorities and no override functions, so you never wonder
which module won. You read the answer in the error, or in `attribution.json`.

## How it works

- **adios** is the module system. Each module declares typed options and returns a result. The types
  come from **korora**, a type library, so a wrong value is an error that says what the module
  expected.

- **A module returns a fragment.** A fragment has `units`, `files`, `sysusers`, `tmpfiles`,
  `packages`, `links` and an optional `name`. Each field is optional and typed, and an unknown field
  is a type error. These are the things the `/usr` builder installs, and nothing is interpreted on
  the way.

- **The `/system` composer unions the fragments.** Maps are unioned, lists are joined, and each
  package appears once.

- **One duplicate check covers every path.** Units, files, links and the `/usr/bin` links of
  packages all claim a path in `/usr`. A path claimed twice throws, whatever the kinds:

  ```text
  golconda: /usr/lib/foo.conf defined twice: file from /services/a, file from /services/b
  ```

- **No global namespace.** A module changes another's output only by calling it and transforming the
  result. Nothing acts at a distance, so `mkForce` has no counterpart.

- **A module is on when its table is in the document.** There is no `enable` flag. A table
  `["/services/sshd"]` selects the component, and removing the table removes it.

The built-in components are in every system: `/base`, `/network`, `/security`, `/trust`, `/factory`
and `/vars`. `/pkgs` is a provider: it gives the package set to modules that declare it as an input,
and it adds no fragment. `/services/sshd` is the one optional component today.

## Using it

A module of your own follows the same rules ([Your own modules](extending.md)):

```nix
{ types, ... }:
{
  name = "motd";
  options.text = { type = types.string; default = "Welcome\n"; description = "The message of the day."; };
  impl = { options, ... }: { files."/usr/lib/motd" = { inherit (options) text; mode = "0644"; }; };
}
```

To see who emitted a path, read `/usr/lib/golconda/attribution.json` and
`/usr/lib/golconda/modules.json` ([Configuration as data](config-as-data.md)).

## Status

Eval tests cover the composer and its check. No boot marker does. `tests/eval/composer.nix` asserts
the exact message above, a unit that clashes with a file at one installed path, and a clash with a
path the builder writes itself (`/usr/lib/os-release`). Every boot-test image comes from this
composer. See [What is proven](../proven.md).

## Limits

- A unit is typed text: a stem, one of seven suffixes and a section header. The renderers produce
  the text; the types do not model systemd's directives.
- No generic escape into the unit text. A module that needs a directive the type lacks adds a typed
  field, or does without.
- korora does not expose the members of a struct or the elements of an enum. The JSON Schema marks
  those types `x-golconda-opaque`. Two one-line additions to the adios pin would fix it; they are
  not made.
- Only `/services/sshd` exists as a service. A second service is a new directory in
  `modules/services/`.

## More

- [Design: Modules](../design/modules.md), esp. [the composer](../design/modules.md#the-composer)
- [Reference: modules](../reference/modules/README.md#merge) and
  [the composer output](../reference/modules/README.md#the-composer-output)
- [Design: Architecture](../design/architecture.md)
- [One of each](one-of-each.md)
