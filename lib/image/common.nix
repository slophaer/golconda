# lib/image/common.nix: what every image step shares.
#
# nuDerivation: a content-addressed derivation whose builder is nushell (the repkgs seed, as
# lib/usr-tree.nix uses it), with structured attrs and the step's tools on PATH. The nu modules
# live next to the .nix files; only *.nu enter the store (builderTree), so a .nix edit does not
# rebuild every step.
#
# versionToEpoch is lib/usr-tree.nix's: one function for the version timestamp.
_:
let
  inherit (builtins)
    concatStringsSep
    hashString
    match
    substring
    ;
  sources = import ../../pins;
  builderTree = builtins.path {
    path = ./.;
    name = "image-builder";
    filter = p: t: t == "regular" && match ".*\\.nu" p != null;
  };
  # only the named modules: a derivation whose output must not change with every builder edit
  builderTreeOf =
    names:
    builtins.path {
      path = ./.;
      name = "image-builder";
      filter = p: t: t == "regular" && builtins.elem (baseNameOf p) names;
    };
  usrTreeLib = import ../usr-tree.nix { };
in
{
  inherit (usrTreeLib) versionToEpoch;

  # nuDerivation { name; buildSystem; module; tools; libs; attrs; modules ? null; }: runs
  # `use <module>.nu; <module> build` with every package in `tools` on PATH (bin/, plus
  # lib/systemd for systemd's libexec tools) and every package in `libs` on LD_LIBRARY_PATH.
  # `libs` stands in for the farm: systemd's tools dlopen libcrypto, libcryptsetup, libtss2
  # and the compression libraries by soname (modules/base/parts/links.nix dlopenSonames), and the fork's
  # RUNPATH does not reach them; in the image /usr/lib does. `modules`, a list of file names, puts
  # only those .nu files in the builder's tree (default: all of them).
  nuDerivation =
    {
      name,
      buildSystem,
      module,
      tools ? [ ],
      libs ? [ ],
      attrs ? { },
      modules ? null,
    }:
    let
      tree = if modules == null then builderTree else builderTreeOf modules;
      bootstrap = import "${sources.repkgs}/bootstrap" {
        seed = null;
        system = buildSystem;
      };
      nu = bootstrap.seed;
      path = concatStringsSep ":" (
        map (t: "${t}/bin") (tools ++ [ bootstrap.seed ]) ++ map (t: "${t}/lib/systemd") tools
      );
      libraryPath = concatStringsSep ":" (map (l: "${l}/lib") libs);
    in
    derivation (
      {
        inherit name;
        system = buildSystem;
        __structuredAttrs = true;
        __contentAddressed = true;
        outputHashMode = "recursive";
        outputHashAlgo = "sha256";
        builder = "${nu}/bin/nu";
        args = [
          "--no-config-file"
          "--include-path=${tree}"
          "--experimental-options=[cell-path-types]"
          "-c"
          "use ${module}.nu; ${module} build"
        ];
        outputs = [ "out" ];
        PATH = path;
        LD_LIBRARY_PATH = libraryPath;
      }
      // attrs
    );

  # A UUID (8-4-4-4-12) from the first 32 hex digits of a string: how the version
  # seeds every identifier the tools would otherwise draw at random.
  uuidOfHex =
    hex:
    concatStringsSep "-" [
      (substring 0 8 hex)
      (substring 8 4 hex)
      (substring 12 4 hex)
      (substring 16 4 hex)
      (substring 20 12 hex)
    ];

  # The sha256 of a string, as the hex the tools take for salts and seeds.
  hexOf = s: hashString "sha256" s;
}
