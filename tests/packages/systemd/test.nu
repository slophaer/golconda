# systemd: the IMDS stack (meson `imds`) is built, with its units and its system user. /base's
# farm links lib/systemd and lib/sysusers.d, so these files reach every image; /base's drop-ins
# keep the units off unless the configuration has `/imds` (modules/base/parts/imds.nix).
# Not built: the sysext and confext stack (meson `sysext`), whose units would overlay /usr and
# /etc with images from /var/lib/extensions and /etc/extensions. Not installed: the ssh generator,
# whose sockets would start a stock sshd beside Golconda's.
use checks.nu *
let p = $env.pkg
let unit = {|n| $"($p)/lib/systemd/system/($n)" }

assert "systemd-imdsd, the daemon that talks to the endpoint" ($"($p)/lib/systemd/systemd-imdsd" | path exists)
assert "systemd-imds, its client" ($"($p)/lib/systemd/systemd-imds" | path exists)
assert "the generator that turns it on where hwdb finds a cloud" ($"($p)/lib/systemd/system-generators/systemd-imds-generator" | path exists)
for n in [systemd-imdsd.socket systemd-imdsd@.service systemd-imds-early-network.service systemd-imds-import.service systemd-imds-metrics.socket systemd-imds-metrics@.service] {
  assert $"unit ($n)" (do $unit $n | path exists)
}
let sysuser = $"($p)/lib/sysusers.d/systemd-imds.conf"
assert "the systemd-imds system user" (($sysuser | path exists) and ((open --raw $sysuser) | str contains "u! systemd-imds"))

# sysext off: neither program, no unit of either (the initrd's and the socket's included)
for n in [systemd-sysext systemd-confext] {
  assert $"no ($n) program" (not ($"($p)/bin/($n)" | path exists -n))
}
let ext = (ls $"($p)/lib/systemd/system" | get name | path basename | where {|n| ($n | str contains "sysext") or ($n | str contains "confext") })
assert $"no sysext or confext unit \(($ext | str join ' ')\)" ($ext | is-empty)

# no ssh generator: it binds sshd to AF_UNIX, AF_VSOCK and any ssh.listen address with an
# AuthorizedKeysFile of its own
assert "no systemd-ssh-generator" (not ($"($p)/lib/systemd/system-generators/systemd-ssh-generator" | path exists -n))

# userspace hardening: the set-wide flags (repkgs builder/hardening.nu) reach PID 1 and the
# shared library every program links; only the flags the EFI code cannot take are off
# (packages/systemd/package.nix). _FORTIFY_SOURCE shows as glibc's checked variants
# (__memcpy_chk, __snprintf_chk, …; __stack_chk_fail is the stack protector, which systemd's
# own meson adds), BIND_NOW as the dynamic FLAGS, noexecstack as a GNU_STACK without E
for f in [lib/systemd/systemd lib/systemd/libsystemd-shared-262.so] {
  let path = $"($p)/($f)"
  let chk = (^llvm-nm -D --undefined-only $path | lines | parse -r '\s(?<s>__\w+_chk)@' | get s | where { $in != "__stack_chk_fail" })
  assert $"($f): fortified \(__*_chk imports\)" ($chk | is-not-empty)
  assert $"($f): BIND_NOW" (^llvm-readelf -dW $path | lines | any { $in =~ '\(FLAGS\)\s.*BIND_NOW' })
  let stack = (^llvm-readelf -lW $path | lines | where { $in =~ GNU_STACK })
  assert $"($f): a GNU_STACK header, not executable" (($stack | length) == 1 and not ($stack.0 =~ 'RWE'))
}

# the EFI binaries still build as PE images (elf2efi), with the flags they cannot take off
let efi = (ls $"($p)/lib/systemd/boot/efi" | get name)
assert "systemd-boot, the UKI stub and the addon stub" (($efi | length) == 3)
for f in $efi {
  assert $"($f | path basename): a PE image" ((open --raw $f | first 2 | decode) == "MZ")
}
done
