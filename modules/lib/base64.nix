# Base64 (RFC 4648: the standard alphabet, `=` padding, no line breaks) to bytes, in pure Nix.
# A Nix string cannot hold a NUL byte, so binary data, such as an OpenSSH KRL, comes in as
# base64 and leaves as a list of bytes for a renderer to escape.
#
#   decode "U1NI" → { bytes = [ 83 83 72 ]; }
#   decode "U1N"  → { error = "…"; }
let
  inherit (builtins)
    all
    bitAnd
    concatLists
    div
    genList
    isString
    listToAttrs
    stringLength
    substring
    ;

  alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  value = listToAttrs (
    genList (i: {
      name = substring i 1 alphabet;
      value = i;
    }) 64
  );

  decode =
    s:
    let
      n = stringLength s;
      pad =
        if substring (n - 2) 2 s == "==" then
          2
        else if substring (n - 1) 1 s == "=" then
          1
        else
          0;
      # a character outside the alphabet (the padding is none) reads as 0
      at = i: value.${substring i 1 s} or 0;
      group =
        g:
        let
          v = at (4 * g) * 262144 + at (4 * g + 1) * 4096 + at (4 * g + 2) * 64 + at (4 * g + 3);
        in
        [
          (div v 65536)
          (bitAnd (div v 256) 255)
          (bitAnd v 255)
        ];
      bytes = concatLists (genList group (div n 4));
    in
    if !isString s then
      { error = "Expected base64 text, got ${builtins.typeOf s}"; }
    else if n == 0 || n - 4 * (div n 4) != 0 then
      { error = "Expected base64 text: not empty, and a length that is a multiple of 4"; }
    else if !all (i: value ? ${substring i 1 s}) (genList (i: i) (n - pad)) then
      { error = "Expected base64 text: only A-Z a-z 0-9 + /, and up to two = at the end"; }
    else
      { bytes = genList (builtins.elemAt bytes) (3 * div n 4 - pad); };
in
{
  inherit decode;
}
