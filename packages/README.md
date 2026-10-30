# packages/

repkgs packages that Golconda needs and repkgs does not have. Each entry is a directory with
`package.nix` and `sources.toml`, written exactly like an in-tree repkgs package (see the repkgs
README, "Writing a package"). `default.nix` maps the name to the directory. Upstream what is
general; keep here what is Golconda-specific.
