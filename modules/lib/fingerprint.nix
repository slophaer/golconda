# The one form of a SHA-256 fingerprint: 64 lower-case hex digits, no colons. The input is a
# value that modules/lib/grammar.nix `sha256Fingerprint` accepts.
let
  inherit (builtins) replaceStrings;
in
{
  normalise =
    s:
    replaceStrings
      [
        ":"
        "A"
        "B"
        "C"
        "D"
        "E"
        "F"
      ]
      [
        ""
        "a"
        "b"
        "c"
        "d"
        "e"
        "f"
      ]
      s;
}
