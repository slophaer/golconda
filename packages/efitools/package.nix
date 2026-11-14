# efitools: cert-to-efi-sig-list and sign-efi-sig-list, which write the Secure Boot variables
# systemd-boot enrols from the ESP (lib/image/enrol.nu, scripts/make-keys): an EFI_SIGNATURE_LIST
# per certificate, and an EFI_VARIABLE_AUTHENTICATION_2 around a list, signed with OpenSSL. A
# release-host tool, not part of an image.
#
# Only those two programs, built by hand: efitools' Makefile builds its EFI binaries too, which need
# gnu-efi's libraries, sbsign and help2man. The two include gnu-efi's headers for the UEFI types
# (efi.h, efibind.h of the cpu), so gnu-efi is a second source, headers only. -fshort-wchar is
# efitools' own flag and matters: sign-efi-sig-list writes the variable name as wchar_t, which must
# be UTF-16 as UEFI has it. _GNU_SOURCE declares strptime(3), which sign-efi-sig-list's -t needs and
# which C99 and later do not let a compiler assume.
{
  package,
  pkgs,
  platform,
  sources,
}:
package {
  name = "efitools";
  dependencies = [ pkgs.openssl ];
  phases = [
    {
      name = "build";
      run = ''
        let efi = "${sources.fetch "gnu-efi"}/inc"
        let flags = [
          "-O2" "-fshort-wchar" "-DCONFIG_${platform.cpu}" "-DGNU_EFI_USE_MS_ABI" "-D_GNU_SOURCE"
          "-Iinclude" $"-I($efi)" $"-I($efi)/${platform.cpu}" $"-I($efi)/protocol"
        ]
        for f in [lib/guid.c lib/openssl_sign.c cert-to-efi-sig-list.c sign-efi-sig-list.c] {
          x cc ...$flags -c $f -o $"($f | path parse | get stem).o"
        }
        x cc -o cert-to-efi-sig-list cert-to-efi-sig-list.o guid.o -lcrypto
        x cc -o sign-efi-sig-list sign-efi-sig-list.o guid.o openssl_sign.o -lcrypto
        install-bins . [cert-to-efi-sig-list sign-efi-sig-list]
      '';
    }
  ];
  bin = [
    "cert-to-efi-sig-list"
    "sign-efi-sig-list"
  ];
  tests.version = "sign-efi-sig-list --version";
  platforms.os = [ "linux" ];
}
