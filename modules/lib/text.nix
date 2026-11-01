# Text helpers for the renderers in modules/. `lines` joins a list of lines
# into the text of a file: one newline between lines and one at the end.
# modules/lib is not a module directory (no default.nix); modules import it:
#   let inherit (import ../lib/text.nix) lines; in ...
{
  lines = l: builtins.concatStringsSep "\n" l + "\n";
}
