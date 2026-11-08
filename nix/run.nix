# run SET NAME TOOLS SCRIPT: a content-addressed derivation NAME whose builder is the repkgs seed's
# shell, as repkgs' own tests are. TOOLS' bin/ come before the seed's on PATH; SCRIPT must create
# $out. nix/checks.nix makes its checks with it, nix/dev its scripts and the treefmt config, so
# that they need no nixpkgs. (The retired chroot-store daemon also refused an input-addressed
# derivation that names a repkgs, content-addressed, output; the system daemon takes one.)
set: name: tools: script:
derivation {
  inherit name;
  system = set.platform.system;
  __contentAddressed = true;
  outputHashMode = "recursive";
  outputHashAlgo = "sha256";
  builder = "${set.bootstrap.seed}/bin/sh";
  args = [
    "-eu"
    "-c"
    script
  ];
  PATH = builtins.concatStringsSep ":" (map (t: "${t}/bin") tools ++ [ "${set.bootstrap.seed}/bin" ]);
}
