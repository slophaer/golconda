#! Faults for the boot tests (scripts/boot-test, nix/test-config.nix), each off until the harness
#! arms it for one release: a file /var/lib/boot-test/<fault>-<IMAGE_VERSION> (%A) on the state
#! partition. Before multi-user.target, on every boot of that release, boot-test-crash.service
#! crashes PID 1 (kill -SEGV 1) and boot-test-panic.service panics the kernel (sysrq c; root may
#! write /proc/sysrq-trigger whatever kernel.sysrq says, and lockdown does not stop it).
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
    units."boot-test-panic.service" = ''
      [Unit]
      Description=Boot test: panic the kernel
      ConditionPathExists=/var/lib/boot-test/panic-%A
      Before=multi-user.target

      [Service]
      Type=oneshot
      StandardOutput=file:/dev/kmsg
      ExecStart=/usr/bin/sh -c 'echo "boot-test: panic (%A)"; echo c > /proc/sysrq-trigger'
    '';
    links."/usr/lib/systemd/system/multi-user.target.wants/boot-test-crash.service" = {
      target = "../boot-test-crash.service";
      kind = "explicit";
    };
    links."/usr/lib/systemd/system/multi-user.target.wants/boot-test-panic.service" = {
      target = "../boot-test-panic.service";
      kind = "explicit";
    };
  };
}
