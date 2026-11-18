# Checks of the console: a journalctl unit shows the journal on tty1, the screen.
# A function of the harness (./harness.nix); it returns a list of checks.
{
  check,
  compose,
  hasInfix,
  ...
}:
# The kernel draws its console on the firmware framebuffer (tty0 is tty1). journald does not
# write to a console: a journalctl process does, so a slow screen never slows journald.
let
  base = compose [ ];
  journald = base.files."/usr/lib/systemd/journald.conf.d/golconda.conf".text;
  unit = base.units."golconda-console.service" or "";
in
[
  (check "console: journald forwards nothing to a console" (
    !(hasInfix "ForwardToConsole" journald)
    && !(hasInfix "TTYPath" journald)
    && !(hasInfix "MaxLevelConsole" journald)
  ))
  (check "console: golconda-console.service follows this boot's journal on tty1" (
    hasInfix "\nExecStart=/usr/bin/journalctl --follow --no-tail --boot " unit
    && hasInfix "\nStandardOutput=tty\n" unit
    && hasInfix "\nTTYPath=/dev/tty1\n" unit
    && hasInfix "\nRestart=always\n" unit
  ))
  # the kernel console shows the kernel's lines on tty0 (image/uki.nix): the unit shows the rest
  (check "console: golconda-console.service skips the kernel's lines" (
    hasInfix " _TRANSPORT=journal _TRANSPORT=syslog _TRANSPORT=stdout\n" unit
    && !(hasInfix "_TRANSPORT=kernel" unit)
  ))
  (check "console: golconda-console.service starts at sysinit.target, not in the initrd" (
    base.links."/usr/lib/systemd/system/sysinit.target.wants/golconda-console.service".target or null
    == "../golconda-console.service"
    && hasInfix "\nDefaultDependencies=no\n" unit
    && hasInfix "\nConditionPathExists=!/etc/initrd-release\n" unit
    # a journalctl started before the flush misses the persistent journal of the first boot
    && hasInfix "\nAfter=systemd-journal-flush.service\n" unit
  ))
]
