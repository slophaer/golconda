# The shared fixtures and helpers of the pure-Nix tests: the stand-in package set, the composer
# entry points (compose, composeWith, withPkgs), `check`, `throws` and the string helpers, and the
# sshd system that mkSystem makes. tests/eval/default.nix passes it to every area file.
{ sources, platform }:
let
  inherit (builtins)
    any
    deepSeq
    genList
    stringLength
    substring
    tryEval
    ;

  f = import ../../default.nix;
  adios = import sources.adios;
  types = adios.adios.types;
  a = import ../../modules/lib/app.nix { inherit types; };
  s = import ../../modules/lib/service.nix { inherit types; };
  v = import ../../modules/lib/var.nix { inherit types; };
  fr = import ../../modules/lib/fragment.nix { inherit types; };
  merge = import ../../modules/lib/merge.nix;
  schemaLib = import ../../lib/schema.nix { };
  moduleDocs = import ../../lib/module-docs.nix { };
  docComments = import ../../lib/doc-comments.nix { };
  modulePaths = moduleDocs.discoverModulePaths ../../modules;
  docs = moduleDocs.toMarkdown {
    moduleSchemas = schemaLib.moduleSchemas (f.modules { });
    inherit modulePaths docComments;
    inherit (schemaLib) typeRegistry;
    tree = f.modules { };
  };
  configLib = import ../../lib/config.nix { tree = f.modules { }; };
  usrTreeLib = import ../../lib/usr-tree.nix { };
  imageLib = import ../../lib/image { };
  inherit
    (import ../../nix/packages.nix {
      inherit sources;
      system = platform;
      inherit platform;
    })
    pkgs
    ;

  # repkgs needs ca-derivations to instantiate, so no package is built here;
  # jq stands in for the type check (the unit then says /usr/bin/jq).
  standIn = pkgs.jq;

  # stand-ins for repkgs packages: `bin` exists only on those
  withBin =
    name: bin:
    pkgs.jq
    // {
      inherit name bin;
      outPath = "/nix/store/${name}";
    };
  # openssh as repkgs declares it: `bin` lists the client tools first
  openssh =
    withBin "openssh-10.6p1" [
      "ssh"
      "sshd"
      "ssh-keygen"
    ]
    // {
      pname = "openssh";
    };
  # base packages for /base module
  stubSystemd = withBin "systemd-262" [
    "systemctl"
    "systemd-tmpfiles"
  ];
  stubDbusBroker = withBin "dbus-broker-42" [ "dbus-broker" ];
  stubDash = withBin "dash-0.5.13.5" [ "dash" ];
  stubUutils = withBin "uutils-coreutils-0.0.25" [
    "ls"
    "cat"
    "cp"
    "mv"
    "rm"
  ];
  stubLinuxKernel = withBin "linux-kernel-6.18.0" [ ];
  # cacert ships one file, tzdata one directory: neither has a bin list
  stubCacert = withBin "cacert-2026.1" [ ];
  stubTzdata = withBin "tzdata-2026a" [ ];
  # the repkgs set as /pkgs sees it: the stand-ins above
  stubSet = {
    buildPkgs = stubSet.pkgs;
    pkgs = {
      inherit openssh;
      jq = standIn;
      # base packages
      systemd = stubSystemd;
      dbus-broker = stubDbusBroker;
      dash = stubDash;
      uutils-coreutils = stubUutils;
      cacert = stubCacert;
      tzdata = stubTzdata;
      linux-kernel = stubLinuxKernel;
    }
    # the libraries /base links for systemd's dlopen (dlopenSonames): no bin, name only
    // builtins.listToAttrs (
      map
        (n: {
          name = n;
          value = withBin "${n}-0" [ ];
        })
        [
          "acl"
          "libarchive"
          "util-linux"
          "openssl"
          "cryptsetup"
          "curl"
          "lz4"
          "xz"
          "zstd"
          "zlib"
          "p11-kit"
          "linux-pam"
          "pcre2"
          "libseccomp"
          "tpm2-tss"
          "e2fsprogs"
        ]
    );
  };
  withPkgs =
    options:
    f.modules {
      options = options // {
        "/pkgs".target = stubSet;
      };
    };

  compose =
    fragments:
    (f.modules {
      options = {
        "/pkgs".target = stubSet;
        "/system" = {
          name = "t";
          version = "20261031.1";
          inherit fragments;
        };
      };
    }).modules.system
      { };
  # compose with extra module options (for /network, /factory, etc.)
  composeWith =
    extraOpts:
    (f.modules {
      options = {
        "/pkgs".target = stubSet;
        "/system" = {
          name = "t";
          version = "20261031.1";
          fragments = [ ];
        };
      }
      // extraOpts;
    }).modules.system
      { };
  # the composer's files, forced: a type error in a file fires here
  filesOf =
    fragments:
    let
      r = (compose fragments).files;
    in
    deepSeq r r;
  filesThrow = fragments: !(tryEval (filesOf fragments)).success;
  # Force the /system version type: the composer runs it. The parentheses put
  # the call inside deepSeq; without them it would apply deepSeq's result.
  versionAccepted =
    v:
    (tryEval (
      deepSeq (
        (f.modules {
          options = {
            "/pkgs".target = stubSet;
            "/system" = {
              name = "t";
              version = v;
            };
          };
        }).modules.system
          { }
      ) true
    )).success;

  check = name: cond: if cond then true else throw "golconda tests: ${name} failed";
  # forcing the units is enough: a type error fires before any field; the
  # package derivations stay unevaluated (repkgs needs ca-derivations to instantiate)
  throws = r: !(tryEval (deepSeq r.units r.units)).success;
  hasInfix =
    needle: hay:
    let
      n = stringLength needle;
      h = stringLength hay;
    in
    n <= h && any (i: substring i n hay == needle) (genList (i: i) (h - n + 1));
  hasPrefix = p: s: substring 0 (stringLength p) s == p;
  hasSuffix =
    x: s:
    let
      n = stringLength s - stringLength x;
    in
    n >= 0 && substring n (stringLength x) s == x;

  # 1. sshd composes: the unit loads the host key credential and passes it
  tree = withPkgs {
    "/services/sshd" = {
      authorizedKeys = [ "ssh-ed25519 AAAA test" ];
    };
  };
  sshd = tree.modules.services.modules.sshd { };
  factory = tree.modules.factory { };
  # the sshd system as mkSystem makes it: the pinned package set, /vars and /factory
  # added by mkSystem itself
  mkSystemFixture = import ../../lib/system.nix {
    inherit sources platform;
    system = platform;
    config = {
      "/system" = {
        name = "test";
        version = "20261031.1";
      };
      "/services/sshd" = {
        authorizedKeys = [ "ssh-ed25519 AAAA test" ];
      };
    };
  };
  system = mkSystemFixture.composed;
  # the pinned packages the fixture holds
  fixturePkgs = mkSystemFixture.pkgs;
  unit = system.units."sshd.service";
  sshdDir = "/usr/lib/sshd";
  sshdConfig = system.files."${sshdDir}/sshd_config".text;

  sshdTree = opts: withPkgs { "/services/sshd" = opts; };

  # 8. the factory: /etc seeds under /usr/share/factory/etc as symlinks
  factoryDir = "/usr/share/factory/etc";
  factoryOf = opts: ((f.modules { options."/factory" = opts; }).modules.factory { });
  factoryThrows = opts: filesThrow [ (factoryOf opts) ];
  pamSshd = factory.files."${factoryDir}/pam.d/sshd";
in
{
  inherit
    a
    adios
    check
    compose
    composeWith
    configLib
    docComments
    docs
    f
    factory
    factoryDir
    factoryOf
    factoryThrows
    filesOf
    filesThrow
    fixturePkgs
    fr
    hasInfix
    hasPrefix
    hasSuffix
    imageLib
    merge
    mkSystemFixture
    moduleDocs
    modulePaths
    openssh
    pamSshd
    pkgs
    platform
    s
    schemaLib
    sources
    sshd
    sshdConfig
    sshdDir
    sshdTree
    standIn
    stubCacert
    stubDash
    stubSet
    stubSystemd
    stubTzdata
    system
    throws
    tree
    types
    unit
    usrTreeLib
    v
    versionAccepted
    withBin
    withPkgs
    ;
}
