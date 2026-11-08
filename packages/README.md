# packages/

repkgs packages that Golconda needs and upstream repkgs does not have. Each entry is a directory
with `package.nix` and `sources.toml`, written exactly like an in-tree repkgs package (see the
repkgs README, "Writing a package"). `default.nix` maps the name to the directory; a name there
replaces an in-tree package of the same name. A package's own test is
`tests/packages/<name>/test.nu` ([Packaging](../docs/design/packaging.md#where-a-package-lives)).

`uptrack` has no `sources.toml`: its source is the repkgs tree in `pins/repkgs`, so it is always the
uptrack that matches the pinned set, and there is no second pin to keep in step.
