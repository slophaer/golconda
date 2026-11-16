#! Kernel security hardening via sysctl: installs `/usr/lib/sysctl.d/50-golconda.conf`, which systemd-sysctl.service applies at boot.
#! A built-in component. The settings and the reason for each: docs/design/kernel.md.
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
