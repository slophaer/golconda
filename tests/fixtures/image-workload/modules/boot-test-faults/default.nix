#! Faults for the boot tests (scripts/boot-test, nix/test-config.nix), each off until the harness
#! arms it for one release: a file /var/lib/boot-test/<fault>-<IMAGE_VERSION> (%A) on the state
#! partition. On every boot of that release, before multi-user.target: boot-test-crash.service
#! crashes PID 1 (kill -SEGV 1), boot-test-panic.service panics the kernel (sysrq c), and
#! boot-test-watchdog.service freezes PID 1, which then stops feeding the hardware watchdog.
_: {
  name = "boot-test-faults";

  impl =
    _:
    let
      wanted = unit: {
        "/usr/lib/systemd/system/multi-user.target.wants/${unit}" = {
          target = "../${unit}";
          kind = "explicit";
        };
      };
    in
    {
      units = {
        "boot-test-crash.service" = ''
          [Unit]
          Description=Boot test: crash PID 1
          ConditionPathExists=/var/lib/boot-test/crash-%A
          Before=multi-user.target

          [Service]
          Type=oneshot
          StandardOutput=file:/dev/kmsg
          ExecStart=/usr/bin/sh -c 'echo "boot-test: crash PID 1 (%A)"; kill -SEGV 1'
        '';
        # root may write /proc/sysrq-trigger whatever kernel.sysrq says; lockdown does not stop it
        "boot-test-panic.service" = ''
          [Unit]
          Description=Boot test: panic the kernel
          ConditionPathExists=/var/lib/boot-test/panic-%A
          Before=multi-user.target

          [Service]
          Type=oneshot
          StandardOutput=file:/dev/kmsg
          ExecStart=/usr/bin/sh -c 'echo "boot-test: panic (%A)"; echo c > /proc/sysrq-trigger'
        '';
        # the cgroup v2 freezer stops PID 1 as a deadlock would. A busy loop at real-time priority
        # on every CPU does not: the kernel's fair server still gives PID 1 50 ms of each second
        "boot-test-watchdog.service" = ''
          [Unit]
          Description=Boot test: freeze PID 1, so the hardware watchdog resets the machine
          ConditionPathExists=/var/lib/boot-test/watchdog-%A
          Before=multi-user.target

          [Service]
          Type=oneshot
          StandardOutput=file:/dev/kmsg
          ExecStart=/usr/bin/sh -c 'echo "boot-test: freeze PID 1 (%A)"; echo 1 > /sys/fs/cgroup/init.scope/cgroup.freeze'
        '';
      };
      links =
        wanted "boot-test-crash.service"
        // wanted "boot-test-panic.service"
        // wanted "boot-test-watchdog.service";
    };
}
