# ccid, pcscd's USB reader driver, which carries the YubiKey's smart card interface: the bundle
# pcscd loads from PCSCLITE_HP_DROPDIR has an Info.plist that lists Yubico's USB vendor ID (0x1050)
# and a libccid.so that finds libusb by itself.
use checks.nu *
let p = $env.pkg
let bundle = $"($p)/lib/pcsc/drivers/ifd-ccid.bundle/Contents"

assert "Info.plist" ($"($bundle)/Info.plist" | path exists)
assert "libccid.so" ($"($bundle)/Linux/libccid.so" | path exists)
let plist = (open --raw $"($bundle)/Info.plist")
assert "the plist lists Yubico's vendor ID" ($plist | str contains "0x1050")
assert "the plist names the library" ($plist | str contains "libccid.so")
let needed = (^llvm-readelf -dW $"($bundle)/Linux/libccid.so" | complete)
assert "libccid.so needs libusb" ($needed.stdout | str contains "libusb-1.0")
assert "the driver is no rule or file outside lib/" (not ($"($p)/etc" | path exists))
done
