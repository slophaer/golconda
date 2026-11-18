#! A downstream service for the tests (tests/eval/components.nix): its table gives the text of
#! one app file, and the `service` type of `/golconda/api` checks it.
{ types, ... }:
{
  name = "api-service";

  inputs = {
    api.path = "/golconda/api";
    pkgs.path = "/pkgs";
  };

  options.text = {
    type = types.string;
    default = "ok\n";
    description = "The text of the app file `conf`.";
  };

  impl =
    { options, results, ... }:
    results.api.service.render {
      name = "api-service";
      app = {
        package = results.pkgs.pkgs.dash;
        files.conf = options.text;
      };
      user = "root";
      sandbox = "default";
    };
}
