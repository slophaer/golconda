# lib/version.nix: the timestamp of a release version, YYYYMMDD.N.
#
# toEpoch :: string -> int is the date's epoch plus the revision N, in seconds since
# 1970-01-01 UTC. It throws for a value that grammar.version (modules/lib/grammar.nix), the
# one grammar of the /system.version type, refuses: a real date from 1970 on and a revision
# 0-86399 without a leading zero, so the timestamp stays inside its date and no two versions
# share one.
# The image chain gives it to mkfs.erofs -T, and it must grow with each version: the units with
# ConditionNeedsUpdate= run only when /usr is newer than /etc/.updated (docs/design/releases.md).
_:
let
  inherit (builtins)
    elemAt
    filter
    foldl'
    fromJSON
    genList
    length
    match
    stringLength
    substring
    ;
  grammar = import ../modules/lib/grammar.nix;

  # decimal digits to an integer; the month and day have a leading zero ("01"),
  # which fromJSON would refuse
  toInt =
    s: foldl' (acc: i: acc * 10 + fromJSON (substring i 1 s)) 0 (genList (i: i) (stringLength s));

  isLeap = y: (y / 4 * 4 == y) && ((y / 100 * 100 != y) || (y / 400 * 400 == y));

  monthLengths = y: [
    31
    (if isLeap y then 29 else 28)
    31
    30
    31
    30
    31
    31
    30
    31
    30
    31
  ];
in
{
  toEpoch =
    v:
    if !builtins.isString v || match grammar.version v == null then
      throw "golconda: toEpoch: '${toString v}' is not a version: YYYYMMDD.N, a real date from 1970 on and a revision 0-86399 without a leading zero, such as 20261031.1"
    else
      let
        m = match "([0-9]{4})([0-9]{2})([0-9]{2})\\.([0-9]+)" v;
        year = toInt (elemAt m 0);
        month = toInt (elemAt m 1);
        daysBeforeMonth = foldl' (acc: i: acc + elemAt (monthLengths year) i) 0 (
          genList (i: i) (month - 1)
        );
        years = genList (i: 1970 + i) (year - 1970);
        daysSinceEpoch =
          (year - 1970) * 365 + length (filter isLeap years) + daysBeforeMonth + toInt (elemAt m 2) - 1;
      in
      daysSinceEpoch * 86400 + toInt (elemAt m 3);
}
