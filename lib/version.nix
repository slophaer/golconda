# lib/version.nix: the release version, YYYYMMDD.N.
#
# One grammar for the /system.version type (modules/system/default.nix) and the
# timestamp the image chain derives from it (lib/usr-tree.nix versionToEpoch).
# A version is a real calendar date and a revision inside that day:
#   - year 1970 or later (the epoch has no earlier date)
#   - month 01-12, day 01-daysInMonth (leap years included)
#   - revision 0-86399, so date + revision is inside the day and a revision can
#     never reach, or pass, the next date's timestamp.
#   - revision without a leading zero: 20261031.01 and 20261031.1 would be two
#     versions with one timestamp, and ConditionNeedsUpdate= compares
#     timestamps.
# The revision is N in YYYYMMDD.N. It is a second offset for the erofs mtime,
# not a free counter: unbounded N made 20261031.86400 share 20261101.0's epoch.
_:
let
  inherit (builtins)
    elemAt
    filter
    foldl'
    fromJSON
    genList
    isString
    length
    match
    stringLength
    substring
    ;

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

  # The last revision whose timestamp is still inside its date: one day is 86400
  # seconds, so 86399 is 23:59:59.
  maxRevision = 86399;

  # parse :: string -> null | { year; month; day; revision; revisionText; }
  parse =
    v:
    if !isString v then
      null
    else
      let
        m = match "([0-9]{4})([0-9]{2})([0-9]{2})\\.([0-9]+)" v;
      in
      if m == null then
        null
      else
        {
          year = toInt (elemAt m 0);
          month = toInt (elemAt m 1);
          day = toInt (elemAt m 2);
          revision = toInt (elemAt m 3);
          revisionText = elemAt m 3;
        };

  # error :: string -> null | string: the reason a version is refused, or null.
  error =
    v:
    let
      p = parse v;
    in
    if p == null then
      "'${v}' is not a version: YYYYMMDD.N, such as 20261031.1"
    else if p.year < 1970 then
      "'${v}' is not a version: the year must be 1970 or later"
    else if p.month < 1 || p.month > 12 then
      "'${v}' is not a version: the month must be 01-12"
    else if p.day < 1 || p.day > elemAt (monthLengths p.year) (p.month - 1) then
      "'${v}' is not a version: ${toString p.year}-${toString p.month} has no day ${toString p.day}"
    else if match "0[0-9]+" p.revisionText != null then
      "'${v}' is not a version: the daily revision has no leading zero (write ${toString p.revision})"
    else if p.revision > maxRevision then
      "'${v}' is not a version: the daily revision must be 0-${toString maxRevision}, or it reaches the next date"
    else
      null;

  check = v: error v == null;

  # toEpoch :: string -> int. Seconds since 1970-01-01 UTC: the date's epoch plus
  # the revision, the one timestamp the image chain gives a release.
  toEpoch =
    v:
    let
      msg = error v;
    in
    if msg != null then
      throw "versionToEpoch: ${msg}"
    else
      let
        p = parse v;
        daysBeforeMonth = foldl' (acc: i: acc + elemAt (monthLengths p.year) i) 0 (
          genList (i: i) (p.month - 1)
        );
        years = genList (i: 1970 + i) (p.year - 1970);
        daysSinceEpoch = (p.year - 1970) * 365 + length (filter isLeap years) + daysBeforeMonth + p.day - 1;
      in
      daysSinceEpoch * 86400 + p.revision;
in
{
  inherit
    check
    error
    maxRevision
    parse
    toEpoch
    ;
}
