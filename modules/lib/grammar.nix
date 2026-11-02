# The grammars of names, paths and versions, one definition each. The typedefs
# in modules/ test a value with `builtins.match` (a whole-string POSIX ERE), and
# lib/schema.nix exports the same strings as JSON Schema patterns (ECMA-262,
# anchored with `anchored`), so a type and its schema cannot disagree.
#
# Every pattern is in the subset both dialects read alike: bracket expressions
# with `-` last and no backslash inside, `\.` and `\[` outside them, groups,
# `|`, `*`, `+` and `{m,n}`. A pattern with a top-level `|` is one group, so
# anchoring it keeps every alternative anchored.
#
# A control character is the one rule the subset cannot spell: POSIX has the
# class [[:cntrl:]], ECMA-262 the escapes \u0000-\u001f and \u007f. `control` and
# `controlSchema` are the two spellings of the one set (0x00-0x1f and 0x7f).
let
  inherit (builtins) concatStringsSep;

  # One path component that is not . or ..: a non-dot character somewhere, or
  # three dots or more.
  pathComponent = "([^/]*[^/.][^/]*|\\.\\.\\.+)";

  # One component of a path under /etc: letters, digits and _ . + -, not . or ..
  etcComponent = "([A-Za-z0-9_.+-]*[A-Za-z0-9_+-][A-Za-z0-9_.+-]*|\\.\\.\\.+)";

  # The unit suffixes systemd loads from /usr/lib/systemd/system.
  unitSuffixes = [
    "service"
    "target"
    "socket"
    "timer"
    "path"
    "mount"
    "slice"
  ];

  # YYYYMMDD.N, as lib/version.nix defines it: a real date from 1970 on (leap
  # years included) and a revision 0-86399 without a leading zero.
  year = "(19[7-9][0-9]|[2-9][0-9]{3})";
  leapYear = "(19(7[26]|8[048]|9[26])|[2-9][0-9](0[48]|[2468][048]|[13579][26])|([2468][048]|[3579][26])00)";
  monthDay = concatStringsSep "|" [
    "(0[13578]|1[02])(0[1-9]|[12][0-9]|3[01])"
    "(0[469]|11)(0[1-9]|[12][0-9]|30)"
    "02(0[1-9]|1[0-9]|2[0-8])"
  ];
  revision = "(0|[1-9][0-9]{0,3}|[1-7][0-9]{4}|8[0-5][0-9]{3}|86[0-3][0-9]{2})";
in
{
  inherit unitSuffixes;

  # The image id: os-release ID=, the artifact file name stem, the sysupdate match pattern.
  imageName = "[A-Za-z0-9][A-Za-z0-9._-]*";

  version = "(${year}(${monthDay})|${leapYear}0229)\\.${revision}";

  fileMode = "[0-7]{4}";

  # A unit name stem and the names built on it.
  serviceName = "[A-Za-z0-9:_.-]+";
  unitName = "[A-Za-z0-9:_.@-]+\\.(${concatStringsSep "|" unitSuffixes})";
  targetName = "[A-Za-z0-9:_.-]+\\.target";

  # A section header line of a unit, such as [Unit].
  sectionHeader = "\\[[A-Za-z]+]";

  # One path component of a filename or a StateDirectory= entry.
  component = "([A-Za-z0-9_.-]*[A-Za-z0-9_-][A-Za-z0-9_.-]*|\\.\\.\\.+)";

  # Dots separate a var name from its credential filename.
  varName = "[A-Za-z0-9_-]+";

  # Canonical paths, without the control-character rule: components that are
  # not empty, . or .., one separator between them, none at the end.
  relativePath = "${pathComponent}(/${pathComponent})*";
  usrPath = "/usr(/${pathComponent})+";

  # A path under /etc, relative: plain components that are not . or ..
  etcPath = "${etcComponent}(/${etcComponent})*";

  # An IANA zone name, a path under /usr/share/zoneinfo such as Europe/Berlin.
  timezone = "[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*";

  credentialId = "[A-Za-z0-9_.:@-]+";
  credentialPrefix = "[A-Za-z0-9_=:/.,+-]*";
  envName = "[A-Za-z_][A-Za-z0-9_]*";
  programName = "[A-Za-z0-9_@.+-]+";

  control = "[[:cntrl:]]";
  controlSchema = "[\\u0000-\\u001f\\u007f]";

  # A JSON Schema pattern searches; anchored, it matches the whole string as
  # builtins.match does.
  anchored = p: "^${p}$";
}
