#! A downstream service for the tests (tests/eval/components.nix): its table gives the text of
#! one app file, and the `service` type of `/golconda-lib` checks it.
{ types, ... }:
{
  name = "library-service";

  inputs = {
    golconda.path = "/golconda-lib";
    pkgs.path = "/pkgs";
  };

  options.text = {
    type = types.string;
    default = "ok\n";
    description = "The text of the app file `conf`.";
  };

  impl =
    { options, results, ... }:
    results.golconda.service.render {
      name = "library-service";
      app = {
        package = results.pkgs.pkgs.dash;
        files.conf = options.text;
      };
      user = "root";
      sandbox = "default";
    };
}
