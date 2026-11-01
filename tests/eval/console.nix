# Checks of the console: kernel framebuffer console and journald forwarding.
# A function of the harness (./harness.nix); it returns a list of checks.
{
  check,
  compose,
  hasInfix,
  ...
}:
# The screen mirrors the serial console: the kernel draws its console on the firmware
# framebuffer, and journald forwards to tty1.
let
  inherit (builtins) all;
  kconfig = builtins.readFile ../../packages/kernel/golconda.config;
  journald = (compose [ ]).files."/usr/lib/systemd/journald.conf.d/golconda.conf".text;
in
[
  (check "console: the kernel draws its console on the firmware framebuffer" (
    all (o: hasInfix "\n${o}=y\n" kconfig) [
      "CONFIG_SYSFB_SIMPLEFB"
      "CONFIG_DRM_SIMPLEDRM"
      "CONFIG_DRM_FBDEV_EMULATION"
      "CONFIG_FRAMEBUFFER_CONSOLE"
    ]
  ))
  (check "console: journald forwards to tty1, the screen" (
    hasInfix "\nForwardToConsole=yes\n" journald && hasInfix "\nTTYPath=/dev/tty1\n" journald
  ))
]
