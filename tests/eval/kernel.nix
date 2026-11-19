# Checks of the kernel config fragment, the packages' build options, kernel hardening sysctl and the UKI cmdline.
# A function of the harness (./harness.nix); it returns a list of checks.
{
  check,
  compose,
  hasInfix,
  hasPrefix,
  pkgs,
  ...
}:
let
  inherit (builtins)
    all
    attrNames
    elem
    elemAt
    filter
    isString
    length
    listToAttrs
    match
    readFile
    split
    ;
in
[
  (check "kernel: vmlinux carries full DWARF 5 (Linux 6.18 \"Debug information\" choice)" (
    let
      base = builtins.fromJSON (
        builtins.unsafeDiscardStringContext pkgs.linux-kernel.args.env.GOLCONDA_KERNEL_CONFIG
      );
      conf = readFile ../../packages/kernel/golconda.config;
      names = [
        "DEBUG_KERNEL"
        "DEBUG_INFO"
        "DEBUG_INFO_NONE"
        "DEBUG_INFO_DWARF5"
        "DEBUG_INFO_REDUCED"
        "DEBUG_INFO_SPLIT"
      ];
    in
    base.DEBUG_KERNEL or null == "y"
    && base.DEBUG_INFO or null == "y"
    && base.DEBUG_INFO_DWARF5 or null == "y"
    && base.DEBUG_INFO_REDUCED or null == "n"
    && base.DEBUG_INFO_SPLIT or null == "n"
    # the fragment must not change the choice
    && all (n: !(hasInfix "CONFIG_${n}=" conf) && !(hasInfix "# CONFIG_${n} is not set" conf)) names
  ))
  (check "kernel: the ORC config only advertises x86_64" (
    pkgs.linux-kernel.args.platforms.cpu == [ "x86_64" ]
  ))
  # 12. The kernel config fragment (packages/kernel/golconda.config)
  (check "kernel: the fragment is KEY=VALUE lines, comments and 'is not set' lines, no name twice" (
    let
      lines = filter (l: isString l && l != "") (
        split "\n" (readFile ../../packages/kernel/golconda.config)
      );
      isComment = l: match "#.*" l != null && match "# CONFIG_[A-Za-z0-9_]+ is not set" l == null;
      isSet = l: match "CONFIG_[A-Za-z0-9_]+=.+" l != null;
      isUnset = l: match "# CONFIG_[A-Za-z0-9_]+ is not set" l != null;
      nameOf =
        l:
        if isUnset l then
          elemAt (match "# CONFIG_([A-Za-z0-9_]+) is not set" l) 0
        else
          elemAt (match "CONFIG_([A-Za-z0-9_]+)=.*" l) 0;
      names = map nameOf (filter (l: isSet l || isUnset l) lines);
    in
    all (l: isComment l || isSet l || isUnset l) lines
    && length names > 100
    &&
      length (
        attrNames (
          listToAttrs (
            map (n: {
              name = n;
              value = true;
            }) names
          )
        )
      ) == length names
  ))
  (check "kernel: PID 1 can read SMBIOS and fw_cfg credentials (DMI_SYSFS, FW_CFG_SYSFS)" (
    let
      conf = readFile ../../packages/kernel/golconda.config;
    in
    hasInfix "\nCONFIG_DMI_SYSFS=y\n" conf && hasInfix "\nCONFIG_FW_CFG_SYSFS=y\n" conf
  ))
  (check "kernel: no 9P, no vsock, no /proc/config.gz (nothing in the image uses them)" (
    let
      base = builtins.fromJSON (
        builtins.unsafeDiscardStringContext pkgs.linux-kernel.args.env.GOLCONDA_KERNEL_CONFIG
      );
      conf = readFile ../../packages/kernel/golconda.config;
      off = n: hasInfix "\n# CONFIG_${n} is not set\n" conf && !(hasInfix "\nCONFIG_${n}=" conf);
    in
    off "NET_9P"
    && off "VSOCKETS"
    && base.IKCONFIG or null == "n"
    && !(base ? IKCONFIG_PROC)
    && !(hasInfix "CONFIG_IKCONFIG" conf)
  ))
  # the defconfig base turns these on; a deleted line would leave them on (docs/design/kernel.md)
  (check "kernel: the defconfig's desktop parts, NFS, ISO 9660, quota and btrfs are off" (
    let
      conf = readFile ../../packages/kernel/golconda.config;
      off = n: hasInfix "\n# CONFIG_${n} is not set\n" conf && !(hasInfix "\nCONFIG_${n}=" conf);
      on = n: hasInfix "\nCONFIG_${n}=y\n" conf;
    in
    all off [
      "SOUND"
      "CFG80211"
      "WLAN"
      "RFKILL"
      "PCCARD"
      "AGP"
      "DRM_I915"
      "USB_PRINTER"
      "INPUT_JOYSTICK"
      "INPUT_TOUCHSCREEN"
      "INPUT_TABLET"
      "HIBERNATION"
      "BINFMT_MISC"
      "IA32_EMULATION"
      "SECURITY_SELINUX"
      "NETLABEL"
      "NETWORK_SECMARK"
      "NFS_FS"
      "NFSD"
      "ISO9660_FS"
      "QUOTA"
      "BTRFS_FS"
    ]
    && all on [
      "BPF_LSM"
      "NF_TABLES"
      "WIREGUARD"
      "ZRAM"
      "DRM_SIMPLEDRM"
    ]
  ))
  (check "systemd: no sysext or confext stack (they would overlay /usr and /etc)" (
    pkgs.systemd.args.meson.defs.sysext == false
  ))
  # kernel code through jig in passthrough: no jig policy flags (hardening, sysroot, RUNPATH),
  # but the compile cache; host tools through jig's normal policy (they need the sysroot)
  (check "kernel: kernel code compiles through jig's cache in passthrough, host tools with its policy"
    (
      let
        make = builtins.fromJSON (
          builtins.unsafeDiscardStringContext pkgs.linux-kernel.args.env.GOLCONDA_KERNEL_MAKE
        );
      in
      elem "CC=env JIG_PASSTHROUGH=1 cc" make
      && !(elem "CC=clang" make)
      && elem "HOSTCC=cc" make
      && elem "HOSTCXX=c++" make
    )
  )
  # the package's own env, as package.nix writes it: its fragment, and the IPE boot policy at the
  # fixed path the fragment names. No store path is in the config: a change of the policy
  # recompiles the policy alone, not every object (packages/kernel/kbuild.nu copy-files)
  (check "kernel: the package carries its fragment and the IPE boot policy at a fixed path" (
    let
      env = pkgs.linux-kernel.args.env;
      json = v: builtins.fromJSON (builtins.unsafeDiscardStringContext v);
      fragments = json env.GOLCONDA_KERNEL_FRAGMENTS;
      files = json env.GOLCONDA_KERNEL_FILES;
      fixed = "security/ipe/golconda-boot-policy";
      conf = readFile ../../packages/kernel/golconda.config;
    in
    length fragments == 1
    && match ".*-golconda\\.config" (elemAt fragments 0) != null
    && attrNames files == [ fixed ]
    && match ".*-ipe-boot-policy" files.${fixed} != null
    && builtins.hasContext env.GOLCONDA_KERNEL_FILES
    && hasInfix "\nCONFIG_IPE_BOOT_POLICY=\"${fixed}\"\n" conf
  ))
  # security module: kernel hardening sysctl
  (check "security: sysctl.d file exists with Yama and hardening" (
    let
      result = compose [ ];
      sysctlFile = result.files."/usr/lib/sysctl.d/50-golconda.conf";
    in
    sysctlFile.mode == "0644"
    && hasInfix "kernel.yama.ptrace_scope = 2" sysctlFile.text
    && hasInfix "kernel.kptr_restrict = 2" sysctlFile.text
    && hasInfix "kernel.dmesg_restrict = 1" sysctlFile.text
    && hasInfix "kernel.unprivileged_bpf_disabled = 1" sysctlFile.text
    && hasInfix "net.core.bpf_jit_harden = 2" sysctlFile.text
    && hasInfix "kernel.kexec_load_disabled = 1" sysctlFile.text
  ))
  (check "security: is built in (a system with no table has the sysctl file)" (
    let
      # the built-in components, as mkSystem selects them (lib/components.nix)
      result = compose [ ];
    in
    result.files ? "/usr/lib/sysctl.d/50-golconda.conf"
  ))
  # UKI cmdline: LSM order and security parameters
  (check "uki: cmdline has lsm order and security parameters" (
    let
      uki = import ../../image/uki.nix;
    in
    hasInfix "lsm=lockdown,yama,ipe,bpf" uki.cmdlineTemplate
    && hasInfix "lockdown=integrity" uki.cmdlineTemplate
    && hasInfix "ipe.enforce=1" uki.cmdlineTemplate
  ))
  # a kernel lockup becomes a panic, and panic=10 reboots (docs/design/boot.md, "Trial boot"): the
  # detectors are built in, the cmdline makes both lockup detectors panic after 30 s (60 s for a
  # soft lockup), and a hung task only warns
  (check "kernel: the lockup and hung task detectors are built in, a lockup panics" (
    let
      uki = import ../../image/uki.nix;
      config = readFile ../../packages/kernel/golconda.config;
    in
    hasInfix "\nCONFIG_SOFTLOCKUP_DETECTOR=y\n" config
    && hasInfix "\nCONFIG_HARDLOCKUP_DETECTOR=y\n" config
    && hasInfix "\nCONFIG_HARDLOCKUP_DETECTOR_PERF=y\n" config
    && hasInfix "\nCONFIG_DETECT_HUNG_TASK=y\n" config
    && hasInfix " panic=10 " uki.cmdlineTemplate
    && hasInfix " softlockup_panic=1 " uki.cmdlineTemplate
    && hasInfix " nmi_watchdog=panic " uki.cmdlineTemplate
    && hasInfix " watchdog_thresh=30 " uki.cmdlineTemplate
    && hasInfix " hung_task_panic=0 " uki.cmdlineTemplate
  ))
  # the hardware watchdogs are built in (no modules), softdog last: the Makefile's link order
  # registers it after the hardware drivers, so it is watchdog0 only on a machine without one
  (check "kernel: watchdog drivers for QEMU, Intel and AMD, and softdog, built in" (
    let
      config = readFile ../../packages/kernel/golconda.config;
    in
    all (o: hasInfix "\nCONFIG_${o}=y\n" config) [
      "WATCHDOG"
      "WATCHDOG_CORE"
      "WATCHDOG_SYSFS"
      "I6300ESB_WDT"
      "ITCO_WDT"
      "LPC_ICH"
      "SP5100_TCO"
      "SOFT_WATCHDOG"
    ]
    # the failed-boot counter's halt closes the watchdog: NOWAYOUT would keep it running
    && hasInfix "\n# CONFIG_WATCHDOG_NOWAYOUT is not set\n" config
  ))
  # kernel config: IPE and lockdown; the /usr signature and IPE policies trust the kernel's
  # built-in key (the secondary keyring), never the platform keyring: that is the firmware db,
  # which holds Microsoft's UEFI CAs by default (docs/design/trust.md)
  (check "kernel: config has IPE and lockdown, and verity and IPE trust no platform key" (
    let
      config = readFile ../../packages/kernel/golconda.config;
    in
    hasInfix "CONFIG_SECURITY_IPE=y" config
    && hasInfix "CONFIG_IPE_PROP_DM_VERITY=y" config
    && hasInfix "CONFIG_IPE_PROP_DM_VERITY_SIGNATURE=y" config
    && hasInfix "CONFIG_SECURITY_LOCKDOWN_LSM=y" config
    && hasInfix "CONFIG_SECURITY_LOCKDOWN_LSM_EARLY=y" config
    && hasInfix "CONFIG_SECURITY_YAMA=y" config
    && hasInfix "CONFIG_DM_VERITY_VERIFY_ROOTHASH_SIG_SECONDARY_KEYRING=y" config
    && hasInfix "CONFIG_IPE_POLICY_SIG_SECONDARY_KEYRING=y" config
    && hasInfix "# CONFIG_DM_VERITY_VERIFY_ROOTHASH_SIG_PLATFORM_KEYRING is not set" config
    && hasInfix "# CONFIG_IPE_POLICY_SIG_PLATFORM_KEYRING is not set" config
  ))
  (check "kernel: IPE boot policy allows initramfs and signed verity" (
    let
      policyContent = readFile ../../packages/kernel/ipe-boot-policy;
    in
    hasInfix "policy_name=golconda" policyContent
    && hasInfix "boot_verified=TRUE action=ALLOW" policyContent
    && hasInfix "dmverity_signature=TRUE action=ALLOW" policyContent
    && hasInfix "DEFAULT op=EXECUTE action=DENY" policyContent
  ))
  # PCR 11: a credential unseals only at a phase path the UKI signs. ukify --phases
  # takes a list of paths (split on commas or spaces); each path is the colon chain
  # measured into PCR 11 up to a state, and a signature covers only that path's last
  # state. Signing the four default paths lets the host key unseal in the initrd and
  # from sysinit on; one long "enter-initrd:...:ready" chain would leave sshd, which
  # starts at ...:sysinit (after basic.target), with nothing it may decrypt.
  (check "uki: the PCR phase policy signs every boot phase path" (
    let
      uki = import ../../image/uki.nix;
      phases = uki.pcrPhases;
      full = "enter-initrd:leave-initrd:sysinit:ready";
      sysinit = "enter-initrd:leave-initrd:sysinit";
    in
    builtins.isList phases
    && length phases == 4
    && elem "enter-initrd" phases
    && elem sysinit phases
    && elem full phases
    # every path is the chain so far: a prefix of the full path
    && all (p: hasPrefix p full) phases
    # a colon chain is one state, not a list of states: no path may be a
    # comma-joined list that ukify would split into the same single chain
    && all (p: !(hasInfix "," p)) phases
  ))
]
