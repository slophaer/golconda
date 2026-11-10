# The inputs: pins/<name>/sources.toml, kept by uptrack (`scripts/pins`), read here purely.
# `import ./pins` gives { <name> = the unpacked tree; }. The reader is lib/pins.nix, a file of
# this repository with no input, so reading the pins fetches nothing first; default.nix exports
# the same reader as lib.readPins.
(import ../lib/pins.nix).read ./.
