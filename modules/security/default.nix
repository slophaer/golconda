#! Kernel security hardening via sysctl.
#!
#! Installs `/usr/lib/sysctl.d/50-golconda.conf` with hardening settings.
#! These are applied by systemd-sysctl.service at boot.
#!
#! Settings: Yama ptrace_scope=2 (admin-only), kptr_restrict=2 (hide kernel
#! pointers), dmesg_restrict=1 (root-only dmesg), unprivileged_bpf_disabled=1,
#! bpf_jit_harden=2, kexec_load_disabled=1 (defence-in-depth: kexec is also
#! disabled in the kernel config).
_:
let
  inherit (import ../lib/text.nix) lines;

  sysctlConf = lines [
    "# Golconda kernel hardening (docs/design/kernel.md)"
    "#"
    "# Yama: restrict ptrace to processes with CAP_SYS_PTRACE (scope 2)."
    "# Prevents code injection across processes under the same user."
    "kernel.yama.ptrace_scope = 2"
    ""
    "# Hide kernel pointers from unprivileged users; stops info leaks."
    "kernel.kptr_restrict = 2"
    ""
    "# Restrict dmesg to root; kernel messages can leak addresses and state."
    "kernel.dmesg_restrict = 1"
    ""
    "# Disable unprivileged BPF; BPF programs can inspect kernel memory."
    "kernel.unprivileged_bpf_disabled = 1"
    ""
    "# Harden the BPF JIT against JIT spraying attacks."
    "net.core.bpf_jit_harden = 2"
    ""
    "# Disable kexec_load; defence-in-depth (CONFIG_KEXEC is also off)."
    "# Once set to 1, the kernel refuses to change it back."
    "kernel.kexec_load_disabled = 1"
  ];
in
{
  name = "security";

  options = { };

  impl = _: {
    files = {
      "/usr/lib/sysctl.d/50-golconda.conf" = {
        text = sysctlConf;
        mode = "0644";
      };
    };
  };
}
