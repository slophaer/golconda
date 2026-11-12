# OVMF as scripts/boot-test loads it: for each variant a code image and an empty variable store
# that fill the flash together (4 MB with Secure Boot, SMM and TPM 2.0; 2 MB plain). Each is a
# firmware volume ("_FVH"): the code one a file system (EFI_FIRMWARE_FILE_SYSTEM2_GUID), the
# variable store the NV data volume (EFI_SYSTEM_NV_DATA_FV_GUID) holding an authenticated variable
# store (gEfiAuthenticatedVariableGuid), which Secure Boot's variables need. The GUIDs are as edk2
# lays them out on disk (the first three fields little-endian). Whether the firmware enforces
# Secure Boot and measures into the TPM, only booting shows: the boot test's --secure-boot and --tpm.
use checks.nu *
let ovmf = $"($env.pkg)/share/ovmf"

const FS2 = 0x[78 e5 8c 8c 3d 8a 1c 4f 99 35 89 61 85 c3 2d d3]
const NV = 0x[8d 2b f1 ff 96 76 8b 4c a9 85 27 47 07 5b 4f 50]
const AUTH = 0x[78 2c f3 aa 7b 94 9a 43 a1 80 2e 14 4e c3 77 92]

def check [variant: string, flash: int] {
  let code = (open --raw $"($ovmf)/($variant)/OVMF_CODE.fd" | into binary)
  let vars = (open --raw $"($ovmf)/($variant)/OVMF_VARS.fd" | into binary)
  let sizes = $"code ($code | bytes length), vars ($vars | bytes length)"
  assert $"($variant): code and vars fill ($flash) bytes of flash: ($sizes)" ((($code | bytes length) + ($vars | bytes length)) == $flash)
  for fv in [[name data guid]; [code $code $FS2] [vars $vars $NV]] {
    assert $"($variant) ($fv.name): a firmware volume" (($fv.data | bytes at 0x28..<0x2c) == ("_FVH" | into binary))
    assert $"($variant) ($fv.name): its file system GUID" (($fv.data | bytes at 0x10..<0x20) == $fv.guid)
  }
  # the volume's length (offset 0x20, 64-bit little-endian): the variable store is one volume; the
  # code image holds two (the compressed main volume first, then SEC with the reset vector)
  let len = {|data| $data | bytes at 0x20..<0x28 | into int -e little }
  assert $"($variant) vars: one volume, the whole file" ((do $len $vars) == ($vars | bytes length))
  assert $"($variant) code: the main volume, then more" ((do $len $code) < ($code | bytes length))
  # the variable store header follows the 0x48-byte volume header
  assert $"($variant) vars: an authenticated variable store" (($vars | bytes at 0x48..<0x58) == $AUTH)
  # empty: after the store header (28 bytes) the variable area is erased flash, 0xff
  assert $"($variant) vars: no variable is set" (($vars | bytes at 0x64..<0x1064 | bytes remove --all 0x[ff] | bytes length) == 0)
}

check secure-boot 4194304
check plain 2097152
done
