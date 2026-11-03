#! A downstream module for the tests: puts the downstream package `hello` in the image.
_: {
  name = "hello";
  inputs.pkgs.path = "/pkgs";
  impl =
    { results, ... }:
    {
      packages = [ results.pkgs.pkgs.hello ];
    };
}
