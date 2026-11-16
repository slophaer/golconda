# UKI parameters for the ukify build: the command line template and the PCR phase paths.
# lib/image/uki.nix names the file and takes the keys. The whole UKI is signed with the Secure
# Boot db key so the firmware accepts it. Sections and boot process: docs/design/boot.md.
{
  # Command line template: {usrhash} is the verity root hash, {usrhashSig} the base64 PKCS#7
  # signature of it, both filled in at build time. The kernel checks the signature against its
  # built-in db certificate, never the firmware db (docs/design/trust.md).
  # rw: PID 1 writes /etc/machine-id on the first boot, before gpt-auto's remount-rw reaches the
  #   root; on a read-only root the boot fails and reboots. /usr stays read-only by dm-verity.
  # panic=10 and the three hang panics (the kernel has no hardlockup_panic=, so nmi_watchdog=panic):
  #   a panic or a hang reboots after 10 s, so a bad release loses a try and systemd-boot falls
  #   back (docs/design/boot.md).
  # lsm, lockdown, ipe.enforce: docs/design/kernel.md. IPE runs code only from the initramfs and
  #   from verity volumes whose signature the kernel verified. console: output only, no getty.
  # systemd.imds.import=0: the generator would pull the import into the initrd, which has no
  #   network; /imds pulls it into the host instead.
  cmdlineTemplate = "usrhash={usrhash} systemd.verity_usr_options=root-hash-signature=base64:{usrhashSig} rw panic=10 softlockup_panic=1 nmi_watchdog=panic hung_task_panic=1 lsm=lockdown,yama,ipe,bpf lockdown=integrity ipe.enforce=1 systemd.imds.import=0 console=tty0 console=ttyS0,115200";

  # The PCR 11 phase paths that the .pcrsig signs (systemd-pcrphase.service(8)). A sealed
  # credential unseals only when the machine's phase path is signed, so the list starts at the
  # initrd and ends at `ready`; one long chain would permit unsealing only at its end.
  # lib/image/uki.nu checks the built .pcrsig against this list. Any UKI signed by the same key
  # can unseal the credentials (docs/design/trust.md, "Downgrade weakness").
  pcrPhases = [
    "enter-initrd"
    "enter-initrd:leave-initrd"
    "enter-initrd:leave-initrd:sysinit"
    "enter-initrd:leave-initrd:sysinit:ready"
  ];
}
