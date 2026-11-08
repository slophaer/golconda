# shellcheck shell=sh
# tools.sh: the bin/ directories of Golconda's own packages, for the scripts that run on the build
# host (scripts/provision-esp), instead of nixpkgs.
#   PATH="$(tools_path "$REPO_DIR" systemd mtools):$PATH"
# Each name is an output packages.<system>.<name> of default.nix, built by the Nix daemon. They
# are built with `nix build --print-out-paths`, not nix-build: nix-build looks the output up by
# the derivation it was given, which a floating content-addressed derivation with such inputs does
# not name until it is resolved (NixOS/nix#16389), while nix build takes it from the build result.
tools_path() {
  tools_repo=$1
  shift
  tools_system=$(nix --extra-experimental-features nix-command eval --impure --raw \
    --expr builtins.currentSystem) || return 1
  tools_args=""
  for tools_n in "$@"; do
    tools_args="$tools_args packages.$tools_system.$tools_n"
  done
  # shellcheck disable=SC2086
  tools_outs=$(nix --extra-experimental-features 'nix-command ca-derivations' build --no-link \
    --print-out-paths -f "$tools_repo" $tools_args) || return 1
  tools_p=""
  for tools_o in $tools_outs; do
    tools_p="$tools_p${tools_p:+:}$tools_o/bin"
  done
  printf %s "$tools_p"
}
