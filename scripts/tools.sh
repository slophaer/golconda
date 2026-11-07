# shellcheck shell=sh
# tools.sh: the bin/ directories of Golconda's own packages, for the scripts that run on the build
# host (scripts/provision-esp), instead of nixpkgs (docs: ~/kb dev-tools inventory).
#   PATH="$(tools_path "$REPO_DIR" systemd mtools):$PATH"
# Each name is an output packages.<system>.<name> of default.nix, built through the configured
# daemon (NIX_REMOTE). With a chroot store (nix --store 'local?root=DIR') the outputs live under
# DIR: GOLCONDA_STORE_ROOT (or BOOT_TEST_STORE_ROOT) names it. Repkgs outputs refer to each other
# relative to themselves, so they run from there.
tools_path() {
  tools_repo=$1
  shift
  tools_system=$(nix-instantiate --eval -E builtins.currentSystem | tr -d '"') || return 1
  tools_args=""
  for tools_n in "$@"; do
    tools_args="$tools_args -A packages.$tools_system.$tools_n"
  done
  # shellcheck disable=SC2086
  tools_outs=$(nix-build --no-out-link "$tools_repo" $tools_args) || return 1
  tools_root=${GOLCONDA_STORE_ROOT:-${BOOT_TEST_STORE_ROOT:-}}
  tools_p=""
  for tools_o in $tools_outs; do
    tools_p="$tools_p${tools_p:+:}$tools_root$tools_o/bin"
  done
  printf %s "$tools_p"
}
