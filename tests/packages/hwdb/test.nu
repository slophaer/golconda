# hwdb: the compiled database holds what a server looks up and nothing of the desktop data.
# The test has only the package and the seed (no systemd-hwdb to query with), so it reads the
# file: the trie header, and the value strings the trie stores verbatim. The boot test's `hwdb`
# marker queries it on the machine (systemd-hwdb query dmi:bvnHetzner:).
use checks.nu *
let db = $"($env.pkg)/lib/udev/hwdb.bin"
assert "hwdb.bin is at lib/udev, where /base links it from" ($db | path exists)

let bytes = (open --raw $db)
# systemd's on-disk format starts with the signature "KSLPHHRH" (src/shared/hwdb-internal.h)
assert "the file is a compiled hwdb" (($bytes | bytes at 0..<8 | decode utf-8) == "KSLPHHRH")

let text = ($bytes | decode latin1)
assert "IMDS: Hetzner is matched by DMI (40-imds.hwdb)" ($text | str contains "hetzner-cloud")
# packages/systemd's hwdb-imds-hetzner.patch (systemd's own fix): Hetzner's real paths, no ssh key
assert "IMDS: Hetzner's base URL is /hetzner/v1" ($text | str contains "http://169.254.169.254/hetzner/v1\u{0}")
assert "IMDS: Hetzner's keys are under /metadata/" ($text | str contains "/metadata/availability-zone")
assert "IMDS: no Hetzner key path that answers 404" (not ($text | str contains "/public-keys/0\u{0}"))
assert "IMDS: no data URL /hetzner/v1/metadata" (not ($text | str contains "/hetzner/v1/metadata\u{0}"))
# packages/systemd's hwdb-imds-hetzner-ssh-keys.patch: Hetzner's keys as the JSON array (ssh-key-json)
assert "IMDS: Hetzner's ssh keys as a JSON array" ($text | str contains "IMDS_KEY_SSH_KEY_JSON")
assert "IMDS: Hetzner's ssh keys at /metadata/public-keys" ($text | str contains "/metadata/public-keys\u{0}")
# modules/imds/default.nix locks these endpoints (IMDS_ADDRESS_IPV4 and IMDS_ADDRESS_IPV6). A systemd
# update that adds an IPv6 endpoint to 40-imds.hwdb fails here until the lock names it. The
# database stores each value string between NULs; IPv6 ones are the only values with "::" that
# start with a hex digit.
let v6 = ($text | parse --regex '\x00([0-9a-f]+:[0-9a-f:]*::[0-9a-f:]*)\x00' | get capture0 | uniq | sort)
assert $"IMDS: the IPv6 endpoints are the ones /imds locks: ($v6)" ($v6 == ["fd00:42::42" "fd00:c1::a9fe:a9fe" "fd00:ec2::254"])
for a in ["169.254.169.254" "169.254.42.42" "100.100.100.200"] {
  assert $"IMDS: the IPv4 endpoint ($a) is in the database" ($text | str contains $a)
}
assert "TPM2 properties (60-tpm2.hwdb)" ($text | str contains "TPM2_BROKEN_NVPCR")
assert "PCI vendor names (20-pci-vendor-model.hwdb)" ($text | str contains "Intel Corporation")
assert "no keyboard remapping (60-keyboard.hwdb is left out)" (not ($text | str contains "KEYBOARD_KEY_"))
assert "no touchpad quirks (60-evdev.hwdb is left out)" (not ($text | str contains "EVDEV_ABS_"))

let size = (ls $db | get 0.size | into int)
assert $"the selection is smaller than the full database: ($size) bytes" ($size < 10000000)
done
