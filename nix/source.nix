# The checks' source: the files git tracks in the checkout, with their working-tree contents. A
# tracked edit and a staged new file are in; an untracked or ignored file (a key set, a token, a
# result link) is not, so nothing private reaches the world-readable store (tests/source).
# builtins.fetchGit reads git's index, in a worktree too; it needs an impure evaluation (nix-build,
# iets --impure). A tree without .git (a pinned tarball, a flake's store copy) holds nothing
# untracked and is taken whole.
self:
if builtins.pathExists (self + "/.git") then
  (builtins.fetchGit self).outPath
else
  builtins.path {
    path = self;
    name = "golconda-src";
  }
