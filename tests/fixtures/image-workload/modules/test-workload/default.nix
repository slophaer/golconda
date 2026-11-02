#! The boot tests' configured workload: a oneshot that boot-complete.target requires, so a
#! release boots only when a downstream module's unit runs (nix/default.nix testConfig).
_: {
  name = "test-workload";

  impl = _: {
    files."/usr/lib/golconda/test-workload".text = "configured-workload\n";
    units."custom-workload.service" = ''
      [Unit]
      Description=Configured module regression test
      Before=boot-complete.target multi-user.target

      [Service]
      Type=oneshot
      ExecStart=/usr/bin/sh -ec 'test "$$(/usr/bin/cat /usr/lib/golconda/test-workload)" = configured-workload'
      RemainAfterExit=yes
    '';
    links."/usr/lib/systemd/system/boot-complete.target.requires/custom-workload.service" = {
      target = "../custom-workload.service";
      kind = "explicit";
    };
    links."/usr/lib/systemd/system/multi-user.target.wants/custom-workload.service" = {
      target = "../custom-workload.service";
      kind = "explicit";
    };
  };
}
