#! Faults for the boot tests (scripts/boot-test, nix/test-config.nix), each off until the harness
#! arms it for one release: a file /var/lib/boot-test/<fault>-<IMAGE_VERSION> (%A) on the state
#! partition. boot-test-crash.service crashes PID 1 (kill -SEGV 1) before multi-user.target, on
#! every boot of that release.
_: {
  name = "boot-test-faults";

  impl = _: {
    units."boot-test-crash.service" = ''
      [Unit]
      Description=Boot test: crash PID 1
      ConditionPathExists=/var/lib/boot-test/crash-%A
      Before=multi-user.target

      [Service]
      Type=oneshot
      StandardOutput=file:/dev/kmsg
      ExecStart=/usr/bin/sh -c 'echo "boot-test: crash PID 1 (%A)"; kill -SEGV 1'
    '';
    links."/usr/lib/systemd/system/multi-user.target.wants/boot-test-crash.service" = {
      target = "../boot-test-crash.service";
      kind = "explicit";
    };
  };
}
