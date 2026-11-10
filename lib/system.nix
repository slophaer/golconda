# lib/system.nix: the entry point for one Golconda system.
#
# mkSystem { config; platform?; sources?; extraFragments?; } → {
#   composed;   # the composer output (units, files, links, packages, …)
#   usrTree;    # the /usr derivation
#   sbom;       # the SBOM derivation (its output has sbom.json); .bom is the CycloneDX document
#   config;     # config.json: module path -> option -> { value?; explicit; }, for every
#               # included component and /system
#   inventory;  # module path -> { role; inputs; included?; reason?; } (lib/components.nix)
#   moduleDocs; # module path -> its #! doc text or null, downstream modules included
#   schema;     # the JSON Schema of this tree, downstream modules included (/usr/lib/golconda/schema.json)
#   catalogue;  # every target package: name -> { version; purl?; cpe?; origin; replaces?; } (nix/packages.nix)
#   fragments;  # the names of the build's own fragments (extraFragments)
#   packages;   # the downstream packages: name -> { replaces; } ("golconda", "repkgs" or null)
#               # modules.json is { modules = inventory; fragments; packages; }
#   artifacts;  # the files mkSystem adds to /usr/lib/golconda/
#   platform;   # the elaborated platform record
#   version;    # YYYYMMDD.N from /system
#   name;       # image id from /system
#   pkgs;       # the packages for this platform
# }
#
# `config` is a path to a TOML file or an attrset already loaded.
# `platform` defaults to the build host's (builtins.currentSystem).
# `sources` defaults to ../pins (pins/default.nix).
# `verityCert` is the certificate that signs /usr (lib.mkImage passes the db certificate of
# its keys). With `/system.secureBoot = false` the kernel carries it in its built-in keyring;
# without Secure Boot nothing else would put it in a keyring (docs/design/trust.md).
#
# Usage:
#   let sys = import ./lib/system.nix { config = ./server.toml; };
#   in sys.usrTree
#
# The document is the whole configuration: no Nix hook. A package option takes a package
# name, resolved in the target set. A downstream repository adds modules and packages: the
# document's optional `[golconda]` table names their directories (default `modules/` and
# `packages/` beside the document; lib/config.nix readProject). Its modules are mounted
# under /local; its packages join the target set after Golconda's own. One that takes a
# Golconda or repkgs name replaces that package only when [golconda] replaces lists the name;
# modules.json records each replacement.
#
# `extraFragments` are the build's own fragments (lib/image: the loader, the update
# index, the initrd's tools), each with a `name`; they are not configuration, and
# modules.json lists them beside the modules.
{
  config,
  platform ? system,
  system ? builtins.currentSystem,
  sources ? import ../pins,
  extraFragments ? [ ],
  verityCert ? null,
}:
let
  inherit (builtins)
    attrNames
    isAttrs
    isPath
    isString
    mapAttrs
    ;

  adios = import sources.adios;
  # The downstream repository's parts, from the document's [golconda] table.
  project = (import ./config.nix { tree = null; }).readProject config;
  tree = import ../modules {
    inherit (adios) adios;
    local = project.modules;
  };
  unloaded = tree { };
  treeLib = import ./tree.nix { };

  # Load the repkgs set for this platform. The kernel config depends on /system.secureBoot,
  # read from the options before the tree checks them: the tree needs the set, and the
  # option's type still checks the value when /system is evaluated.
  secureBoot = (loadedOptions."/system" or { }).secureBoot or true;
  setFull = import ../nix/packages.nix {
    inherit sources system platform;
    downstream = project.packages;
    inherit (project) replaces;
    inherit kernelConfig kernelFiles;
  };
  # Without Secure Boot the kernel's built-in keyring holds the verity certificate. The config
  # names a fixed path in the kernel tree, and the build copies the certificate there
  # (packages/kernel/kbuild.nu): a store path in the config would change autoconf.h, which every
  # object includes, so each certificate would recompile the whole kernel past jig's cache.
  # The certificate stays an input of the kernel through GOLCONDA_KERNEL_FILES.
  trustedKeysFile = "certs/golconda-verity.pem";
  kernelConfig = if secureBoot != false then { } else { SYSTEM_TRUSTED_KEYS = trustedKeysFile; };
  kernelFiles =
    if secureBoot != false then
      { }
    else
      {
        ${trustedKeysFile} =
          if verityCert == null then
            throw "golconda: /system.secureBoot = false needs the image's keys: the kernel carries the db certificate, so build it with lib.mkImage"
          else
            "${verityCert}";
      };

  # The TOML loader: a document in, checked options out (lib/config.nix).
  configLib = import ./config.nix { tree = unloaded; };

  # Load configuration: a path is TOML, an attrset is already loaded options.
  loadedOptions =
    if isPath config then
      (configLib.loadConfig config).options
    else if isAttrs config then
      removeAttrs config [ "golconda" ]
    else
      throw "golconda: config must be a path to a TOML file or an attrset of options";

  # A table names a module, and an option name must be one the module declares
  # (configLib.checkOptions). The loader checked the TOML; this checks an attrset config too,
  # so every route into the tree is checked.
  documentOptions = configLib.checkOptions loadedOptions;

  # A package option (type derivation) takes a package name, looked up in the target set
  # (Golconda's packages and the downstream ones). An attrset config may pass a derivation.
  resolvePackages = mapAttrs (
    path: given:
    let
      declared = (treeLib.moduleAt unloaded path).options or { };
    in
    mapAttrs (
      n: v:
      if isString v && (declared.${n}.type.name or null) == "derivation" then
        setFull.pkgs.${v}
          or (throw "golconda: ${path}.${n} names the package '${v}', which the target set does not have")
      else
        v
    ) given
  );

  # mkSystem is the one place that binds /pkgs.target: it is always the platform's set,
  # never from the document.
  mergedOptions = resolvePackages documentOptions // {
    "/pkgs".target = setFull.set;
  };

  # Which modules enter the system, and why: the built-in components, then each optional
  # component the configuration has a table for (lib/components.nix).
  componentsLib = import ./components.nix { };
  inventory = componentsLib.inventory (tree { }) mergedOptions;
  # The image's own fragments, each named: modules.json lists them beside the modules, so
  # the image is the selected components plus these, nothing else.
  fragments = map (
    fr:
    fr.name or (throw "golconda: mkSystem extraFragments: every fragment needs a `name`, its origin")
  ) extraFragments;

  # The system options from the config (name, version, fragments, updateSource).

  # The composed system: /system with the selected components and the listed fragments.
  composedRaw = componentsLib.compose {
    modules = tree;
    options = mergedOptions;
    inherit extraFragments;
  };

  # Reading the name forces the option types, including the image-id and transfer-path rules.
  composed = builtins.seq composedRaw.name composedRaw;

  # The schema for this tree.
  schemaLib = import ./schema.nix { };
  # Golconda's module files, and the downstream repository's under /local, each relative to
  # its own repository (declaredIn)
  moduleFiles =
    treeLib.modulePaths ../modules
    ++ (
      if project.modules == null then
        [ ]
      else
        map (m: m // { root = toString (dirOf project.modules); }) (
          treeLib.modulePathsAt "/local" project.modules
        )
    );
  # Each module's #! doc text (lib/doc-comments.nix), or null: what the module pages show beside a
  # module's options, downstream modules included.
  moduleDocs = builtins.listToAttrs (
    map (m: {
      name = m.path;
      value = (import ./doc-comments.nix { }).moduleDoc m.filePath;
    }) moduleFiles
  );
  schema = schemaLib.toJsonSchemaWith {
    files = moduleFiles;
    root = toString ../.;
  } unloaded;

  # The normalized configuration: one row per option of every included component and /system,
  # { value?; explicit; }, for config.json. `explicit` is true when the document set the
  # option, false when the default applies; an option with a computed default (defaultFunc)
  # has no `value` then. A package is the name the document gave; a derivation from an
  # attrset config renders as its name, so the JSON is data.
  normalizedConfig =
    let
      stripDerivations =
        v:
        if isAttrs v then
          if v ? outPath then
            # A derivation: record its name only
            v.name or v.pname or "<derivation>"
          else
            mapAttrs (_: stripDerivations) v
        else if builtins.isList v then
          map stripDerivations v
        else
          v;

      rows =
        path: given:
        let
          declared = (treeLib.moduleAt unloaded path).options or { };
        in
        mapAttrs (
          n: _:
          if given ? ${n} then
            {
              value = stripDerivations given.${n};
              explicit = true;
            }
          else if declared.${n} ? default && schemaLib.isPlainData declared.${n}.default then
            {
              value = declared.${n}.default;
              explicit = false;
            }
          else
            { explicit = false; }
        ) (removeAttrs (declared // given) (componentsLib.internalOptions.${path} or [ ]));
    in
    builtins.listToAttrs (
      map
        (path: {
          name = path;
          value = rows path (documentOptions.${path} or { });
        })
        (
          # every included component and /system; /pkgs: its set is not configuration data
          builtins.filter (p: p == "/system" || (inventory.${p}.included or false)) (attrNames inventory)
        )
    );

  # usr-tree library for building the tree.
  usrTreeLib = import ./usr-tree.nix { };

  # These paths identify packages; the SBOM does not build those packages.
  drvKey = pkg: builtins.unsafeDiscardStringContext (pkg.drvPath or "");
  # A plain package keeps its directory; a variant keeps its attribute name.
  # A mere alias of an upstream package must not relabel that package.
  downstreamNames = builtins.filter (
    n:
    let
      pkg = setFull.pkgs.${n};
    in
    (pkg.supported or true)
    && pkg ? drvPath
    && (
      (pkg.pname or null) == n || (pkg ? dir && toString pkg.dir == toString (project.packages + "/${n}"))
    )
  ) (attrNames setFull.downstream);
  downstreamByDrv = builtins.foldl' (
    index: n:
    let
      key = drvKey setFull.pkgs.${n};
      info = setFull.downstream.${n} // {
        name = n;
      };
    in
    index
    // {
      ${key} =
        if index ? ${key} && index.${key}.replaces != info.replaces then
          throw "golconda: downstream SBOM package ${n} has conflicting replacement metadata for the same derivation"
        else
          index.${key} or info;
    }
  ) { } downstreamNames;

  # The set without the downstream packages: where a replaced package comes from. Evaluated
  # only for a replacement's ancestor.
  baseSet = import ../nix/packages.nix {
    inherit sources system platform;
    inherit kernelConfig kernelFiles;
  };

  # Where a package comes from: a downstream package, one of Golconda's packages/ (by its
  # directory), or repkgs (everything else, the libc stand-in and the toolchain included).
  golcondaPackagesDir = toString ../packages + "/";
  originOf =
    pkg:
    if downstreamByDrv ? ${drvKey pkg} then
      "downstream"
    else if
      pkg ? dir
      &&
        builtins.substring 0 (builtins.stringLength golcondaPackagesDir) (toString pkg.dir)
        == golcondaPackagesDir
    then
      "golconda"
    else
      "repkgs";

  # The replaced package as an ancestor names it: its own SBOM component's name, version, purl
  # and cpe, from the set without the downstream packages.
  ancestorOf =
    type: n:
    let
      root = builtins.head (
        builtins.filter (c: c.type == "application")
          (baseSet.set.sbom {
            roots = [ baseSet.pkgs.${n} ];
            name = "ancestor";
          }).bom.components
      );
    in
    {
      inherit type;
    }
    // builtins.intersectAttrs {
      name = null;
      version = null;
      purl = null;
      cpe = null;
    } root;

  # The SBOM (CycloneDX JSON), matched by derivation, not by name: every component says where it
  # comes from (golconda:origin), a downstream replacement names what it replaced
  # (pedigree.ancestors), and a patched package lists its patches (pedigree.patches,
  # lib/sbom-patches.nix). The generator reads purl and cpe from each sources.toml.
  sbomPatches = import ./sbom-patches.nix { };
  sbom = setFull.set.sbom {
    roots = composed.packages;
    name = "${composed.name}-${composed.version}";
    extraProperties = pkg: [
      {
        name = "golconda:origin";
        value = originOf pkg;
      }
    ];
    extraFields =
      pkg:
      let
        downstream = downstreamByDrv.${drvKey pkg} or null;
        type = if builtins.elem pkg composed.packages then "application" else "library";
        patches = sbomPatches.of pkg;
        pedigree =
          (
            if downstream == null || downstream.replaces == null then
              { }
            else
              {
                ancestors = [ (ancestorOf type downstream.name) ];
                notes = "replaced by the downstream package ${downstream.name}; the original comes from ${downstream.replaces}";
              }
          )
          // (if patches == [ ] then { } else { inherit patches; });
      in
      if pedigree == { } then { } else { inherit pedigree; };
  };
  # The files mkSystem adds to /usr/lib/golconda/ (modules/lib/merge.nix reserves the paths).
  artifacts = {
    "/usr/lib/golconda/config.json" = {
      text = builtins.toJSON normalizedConfig;
      mode = "0644";
    };
    "/usr/lib/golconda/schema.json" = {
      text = builtins.toJSON schema;
      mode = "0644";
    };
    "/usr/lib/golconda/modules.json" = {
      text = builtins.toJSON {
        modules = inventory;
        inherit fragments;
        packages = setFull.downstream;
      };
      mode = "0644";
    };
  };

  # The usr tree with the image artifacts.
  usrTreeDrv = usrTreeLib.usrTree {
    composerOutput = composed // {
      files = composed.files // artifacts;
    };
    inherit (setFull) platform;
    inherit (composed) version;
    sbomDrv = sbom;
  };

in
{
  inherit
    artifacts
    composed
    fragments
    inventory
    moduleDocs
    sbom
    schema
    ;
  packages = setFull.downstream;
  usrTree = usrTreeDrv;
  config = normalizedConfig;
  inherit (setFull) catalogue platform pkgs;
  inherit (composed) version name;
}
