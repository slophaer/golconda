# systemd: the IMDS stack (meson `imds`) is built, with its units and its system user. /base's
# farm links lib/systemd and lib/sysusers.d, so these files reach every image; /base's drop-ins
# keep the units off unless the configuration has `/imds` (modules/base/parts/imds.nix).
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
done
