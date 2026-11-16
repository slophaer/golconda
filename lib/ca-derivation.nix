# caDerivation ATTRS: a content-addressed derivation, the form of every builder here that is not a
# repkgs package (nix/run.nix, the dev shell, the /usr tree, the image steps, the package tests).
attrs:
derivation (
  {
    __contentAddressed = true;
    outputHashMode = "recursive";
    outputHashAlgo = "sha256";
  }
  // attrs
)
