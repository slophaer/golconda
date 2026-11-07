# run SET NAME TOOLS SCRIPT: a content-addressed derivation NAME whose builder is the repkgs seed's
# shell, as repkgs' own tests are. TOOLS' bin/ come before the seed's on PATH; SCRIPT must create
# $out. nix/checks.nix makes its checks with it, nix/dev its scripts and the treefmt config: a
# derivation that names a repkgs (content-addressed) output must be content-addressed itself on
# this daemon, so nixpkgs' writers cannot.
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
