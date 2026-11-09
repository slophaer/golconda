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
assert "TPM2 properties (60-tpm2.hwdb)" ($text | str contains "TPM2_BROKEN_NVPCR")
assert "PCI vendor names (20-pci-vendor-model.hwdb)" ($text | str contains "Intel Corporation")
assert "no keyboard remapping (60-keyboard.hwdb is left out)" (not ($text | str contains "KEYBOARD_KEY_"))
assert "no touchpad quirks (60-evdev.hwdb is left out)" (not ($text | str contains "EVDEV_ABS_"))

let size = (ls $db | get 0.size | into int)
assert $"the selection is smaller than the full database: ($size) bytes" ($size < 10000000)
done
