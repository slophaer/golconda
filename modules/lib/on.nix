# `on cond value`: the value when the condition holds, else the empty list or set,
# whichever the value is. The one helper for an optional list or set (the lint
# lints/nix/if-else-empty.yml points here); the same shape as repkgs' `on`.
#   let on = import ../lib/on.nix; in [ a ] ++ on cond [ b ] and { } // on cond { c = 1; }
# A false condition still evaluates the value to see its type, not its contents.
# Not for strings, which have no empty value here.
cond: v:
if cond then
  v
else if builtins.isAttrs v then
  { }
else
  [ ]
