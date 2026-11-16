# lib/system.nix: the entry point for one Golconda system.
#
# mkSystem { config; platform?; system?; sources?; extraFragments?; verityCert?; } -> composed,
#   usrTree, sbom, config, inventory, moduleDocs, schema, fragments, packages,
#   artifacts, platform, version, name and pkgs (the attributes below).
# `config` is a path to a TOML file or an attrset of options: the document is the whole
#   configuration, with no Nix hook. `platform` defaults to `system` (builtins.currentSystem).
# `verityCert` is the certificate that signs /usr (lib.mkImage passes the db certificate of its
#   publicKeys). The kernel carries it in its built-in keyring, the only keyring dm-verity and IPE
#   trust; `/system.secureBoot = false` requires it (docs/design/trust.md).
# `extraFragments` are the build's own fragments (lib/image), each with a `name`; `fragments` lists
#   them. The `[golconda]` table: docs/features/extending.md.
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
    inherit (trustOptions) caAnchors caDistrust;
  };

  # /trust's lists, read from the options before the tree checks them (as secureBoot is): the CA
  # bundle package is built from them, and the option types still check every entry when /trust is
  # evaluated. A document that gives anything but lists fails there, not here.
  trustOptions = {
    caAnchors = (loadedOptions."/trust" or { }).anchors or [ ];
    # one form for the build (the option's type has checked the entries; a bad one throws there)
    caDistrust = map (
      x: if builtins.isString x then (import ../modules/lib/fingerprint.nix).normalise x else x
    ) ((loadedOptions."/trust" or { }).distrust or [ ]);
  };
  # The kernel's built-in keyring holds the verity certificate, the one key dm-verity and IPE
  # trust (packages/kernel/golconda.config). With Secure Boot too: the firmware's db, the
  # platform keyring, holds Microsoft's UEFI CAs by default, and a signature that chains to one
  # must not pass (docs/design/trust.md). So each key set has its own kernel. The config names a
  # fixed path in the kernel tree, and the build copies the certificate there
  # (packages/kernel/kbuild.nu): a store path in the config would change autoconf.h, which every
  # object includes, so each certificate would recompile the whole kernel past jig's cache.
  # The certificate stays an input of the kernel through GOLCONDA_KERNEL_FILES.
  # A system that no image signs (no verityCert: lib.mkSystem alone, for a /usr tree or the
  # SBOM) gets a kernel with no built-in key, which verifies no /usr signature; without Secure
  # Boot that is an error, as nothing else could check one.
  trustedKeysFile = "certs/golconda-verity.pem";
  builtinKey = verityCert != null || secureBoot == false;
  on = import ../modules/lib/on.nix;
  kernelConfig = on builtinKey { SYSTEM_TRUSTED_KEYS = trustedKeysFile; };
  kernelFiles = on builtinKey {
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
  # The image's own fragments, each named: the image is the selected components plus these,
  # nothing else.
  fragments = map (
    fr:
    fr.name or (throw "golconda: mkSystem extraFragments: every fragment needs a `name`, its origin")
  ) extraFragments;

  # The composed system: /system with the selected components and the listed fragments.
  composedRaw = componentsLib.compose {
    modules = tree;
    options = mergedOptions;
    inherit extraFragments;
  };

  # Reading the name forces the option types, including the image-id and transfer-path rules.
  composed = builtins.seq composedRaw.name composedRaw;

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
    inherit (trustOptions) caAnchors caDistrust;
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
  # comes from (golconda:origin), and a downstream replacement names what it replaced
  # (pedigree.ancestors). The generator reads purl and cpe from each sources.toml (or a package's
  # sourceOf), and lists a patched package's patches (pedigree.patches; a patch that says it is an
  # upstream commit is a backport).
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
      in
      if downstream == null || downstream.replaces == null then
        { }
      else
        {
          # merged over the generator's pedigree, which keeps its patches
          pedigree = {
            ancestors = [ (ancestorOf type downstream.name) ];
            notes = "replaced by the downstream package ${downstream.name}; the original comes from ${downstream.replaces}";
          };
        };
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
  };

  # The usr tree with the image artifacts.
  usrTreeDrv = usrTreeLib.usrTree {
    composerOutput = composed // {
      files = composed.files // artifacts;
    };
    inherit (setFull) platform;
    inherit (composed) version;
    inherit sources;
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
  inherit (setFull) platform pkgs;
  inherit (composed) version name;
}
