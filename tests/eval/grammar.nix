# Checks of the name and path grammars (modules/lib/grammar.nix) and their schema patterns.
# A function of the harness (./harness.nix); it returns a list of checks.
{
  check,
  composeWith,
  f,
  factoryOf,
  factoryThrows,
  s,
  schemaLib,
  standIn,
  throws,
  ...
}:
# Every name and path rule is in modules/lib/grammar.nix: argv refuses every control
# character, as paths do, not only a newline; the factory's /etc paths and zone names
# are grammar patterns, and the schema carries them, so type and schema agree.
let
  inherit (builtins)
    all
    any
    filter
    match
    stringLength
    substring
    ;
  grammar = import ../../modules/lib/grammar.nix;
  reg = schemaLib.typeRegistry;
  inherit (import ../../modules/lib/path.nix) hasControl;
  whole = p: substring 1 (stringLength p - 2) p;
  argvWith =
    a:
    s.render {
      name = "x";
      app = {
        package = standIn;
        argv = [ a ];
      };
      user = "dynamic";
      sandbox = "strict";
    };
  agree =
    pat: verify: xs:
    all (x: (match (whole pat) x != null) == (verify x == null)) xs;
  factoryTypes = (f.modules { }).modules.factory.options;
  etcSamples = [
    "rc.local"
    "security/limits.conf"
    "a/...b"
    "..."
    "a/./b"
    "./a"
    "."
    "a/../b"
    ".."
    "a//b"
    "a/"
    "/a"
    "a b"
    "a\nb"
    ""
  ];
  baseTypes = (f.modules { }).modules.base.options;
  ntpSamples = [
    "0.pool.ntp.org"
    "192.0.2.1"
    "2001:db8::1"
    "time.example.com"
    "a b"
    "a\nFallbackNTP=x"
    ""
  ];
  sizeSamples = [
    "512M"
    "1G"
    "4096"
    "1.5G"
    "512 M"
    "512M\nForwardToConsole=no"
    "M"
    ""
  ];
  zoneSamples = [
    "UTC"
    "Europe/Berlin"
    "Etc/GMT+1"
    "../etc/shadow"
    "/usr/share/zoneinfo/UTC"
    "a//b"
    ""
  ];
in
[
  (check "grammar: argv refuses a carriage return and a tab" (
    throws (argvWith "a\rb") && throws (argvWith "a\tb") && !(throws (argvWith "a b"))
  ))
  (check "grammar: the argv schema refuses a control character in a string" (
    let
      str = builtins.head (filter (i: (i.type or null) == "string") reg.argv.items.anyOf);
    in
    str.not.pattern == grammar.controlSchema
  ))
  (check "grammar: an /etc path has no . or .. component" (
    factoryThrows { extraFiles."a/./b" = "x"; }
    && factoryThrows { extraFiles."." = "x"; }
    && factoryThrows { extraFiles."a/../b" = "x"; }
    && (factoryOf { extraFiles."a/...b" = "x"; }) ? files
  ))
  (check "grammar: the etcPath and timezone schemas are the typedefs' grammars" (
    reg.etcFiles.propertyNames.pattern == grammar.anchored grammar.etcPath
    && reg.timezone.pattern == grammar.anchored grammar.timezone
    && agree reg.etcFiles.propertyNames.pattern (
      p: factoryTypes.extraFiles.type.verify { ${p} = "x"; }
    ) etcSamples
    && agree reg.timezone.pattern factoryTypes.timezone.type.verify zoneSamples
    && !(any hasControl zoneSamples)
  ))
  (check "grammar: /base's NTP servers and journal size are typed, and the schema has their grammars"
    (
      reg.ntpServer.pattern == grammar.anchored grammar.ntpServer
      && reg.byteSize.pattern == grammar.anchored grammar.byteSize
      && agree reg.ntpServer.pattern (x: baseTypes.ntp.type.verify [ x ]) ntpSamples
      && agree reg.byteSize.pattern baseTypes.journalMaxUse.type.verify sizeSamples
      && throws (composeWith {
        "/base".ntp = [ "a\nFallbackNTP=x" ];
      })
      && throws (composeWith {
        "/base".journalMaxUse = "512M\nForwardToConsole=no";
      })
      && !(throws (composeWith {
        "/base".journalMaxUse = "1G";
      }))
    )
  )
]
