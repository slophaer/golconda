#! The boot tests' configured workload: a downstream service that Golconda's library (`/golconda-lib`)
#! renders, with the sandbox tier `strict` and one credential, whose public fallback PID 1 gives.
#! It checks its app file and the credential, then prints `custom-workload: checks passed`, the
#! line that the boot test's `sandbox-tier` waits for. boot-complete.target requires it, so a
#! release boots only when a downstream module's unit starts (nix/test-config.nix).
_: {
  name = "test-workload";

  inputs = {
    golconda.path = "/golconda-lib";
    pkgs.path = "/pkgs";
  };

  impl =
    { results, ... }:
    let
      inherit (results.golconda) service merge;
      name = "custom-workload";
    in
    merge [
      (service.render {
        inherit name;
        app = {
          package = results.pkgs.pkgs.dash;
          argv = [
            "-ec"
            ''read -r f < "$1"; read -r c < "$2"; test "$f" = configured-workload; test "$c" = "$f"; echo "custom-workload: checks passed"''
            name
            "${service.filesDir name}/expected"
            (service.credential "token")
          ];
          files.expected = "configured-workload\n";
        };
        credentials.token = "${name}.token";
        credentialFallbacks.token = "configured-workload\n";
        user = "root";
        sandbox = "strict";
      })
      {
        links."/usr/lib/systemd/system/boot-complete.target.requires/${name}.service" = {
          target = "../${name}.service";
          kind = "explicit";
        };
      }
    ];
}
