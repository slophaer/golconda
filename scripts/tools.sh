# shellcheck shell=sh
# tools.sh: Golconda's own packages for the scripts that run on the build host (scripts/provision-esp,
# scripts/boot-test, scripts/make-keys), instead of nixpkgs.
#   PATH="$(tools_path "$REPO_DIR" systemd mtools):$PATH"
#   OVMF=$(tools_outs "$REPO_DIR" ovmf)
# Each name is an output packages.<system>.<name> of default.nix, built by the Nix daemon.

# tools_outs REPO NAME...: the packages' store paths, one per line, in the order of the names
tools_outs() {
  tools_repo=$1
  shift
  tools_system=$(nix-instantiate --eval -E builtins.currentSystem | tr -d '"') || return 1
  tools_args=""
  for tools_n in "$@"; do
    tools_args="$tools_args -A packages.$tools_system.$tools_n"
  done
  # shellcheck disable=SC2086
  nix-build --no-out-link "$tools_repo" $tools_args
}

# tools_path REPO NAME...: the packages' bin/ directories, joined with ':'
tools_path() {
  tools_outs=$(tools_outs "$@") || return 1
  tools_p=""
  for tools_o in $tools_outs; do
    tools_p="$tools_p${tools_p:+:}$tools_o/bin"
  done
  printf %s "$tools_p"
}
