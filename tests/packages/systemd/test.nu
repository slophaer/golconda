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
done
