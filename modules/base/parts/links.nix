# Part of /base (modules/base/default.nix merges it): the /usr links into the
# packages. /usr/bin/sh, the util-linux and e2fsprogs tools, systemd's farm
# directories, the dlopen sonames, the PAM module directories, the CA bundle, the
# zone database, the compiled hwdb, and the tmpfiles lines that link the CA bundle from /etc.
# `p` is the package set. Returns { links; tmpfiles; }.
{ p }:
let
  inherit (builtins) listToAttrs;

  # The one CA file of the image: cacert's Mozilla bundle. /etc carries only
  # symlinks to it, made at boot by the tmpfiles lines below: OpenSSL's
  # OPENSSLDIR is /etc/ssl, so its default cert file is /etc/ssl/cert.pem, and
  # libcurl is built with CURL_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt.
  # The file stays in /usr, so an image update replaces it; a later p11-kit
  # trust extract may replace the links, but not this file.
  caBundleLinks = {
    "/usr/share/ca-certificates/ca-bundle.crt" = {
      target = "${p.cacert}/etc/ssl/certs/ca-bundle.crt";
      kind = "explicit";
    };
  };
  caBundleTmpfiles = [
    "L /etc/ssl/cert.pem - - - - /usr/share/ca-certificates/ca-bundle.crt"
    "L /etc/ssl/certs/ca-certificates.crt - - - - /usr/share/ca-certificates/ca-bundle.crt"
  ];

  # The zone database: /etc/localtime (the factory's tmpfiles line) links
  # /usr/share/zoneinfo/<timezone>, UTC by default. One directory link: the
  # zone files are data that no $ORIGIN rule reaches.
  zoneinfoLinks = {
    "/usr/share/zoneinfo" = {
      target = "${p.tzdata}/share/zoneinfo";
      kind = "explicit";
    };
  };

  # The compiled hardware database (packages/hwdb). systemd ships no hwdb.bin, so this
  # file sits beside the lib/udev farm without a clash. A file, not a directory link:
  # /usr/lib/udev is systemd's farm.
  hwdbLinks = {
    "/usr/lib/udev/hwdb.bin" = {
      target = "${p.hwdb}/lib/udev/hwdb.bin";
      kind = "explicit";
    };
  };

  # PAM modules: Linux-PAM loads a relative module name from /usr/lib/security/, and the
  # factory's stacks name <package>/<module>. Each package's module directory is one
  # directory link: repkgs writes DT_NEEDED as $ORIGIN/../../../<dep>/lib/..., $ORIGIN is
  # the directory of the path PAM opens, and only a directory link makes `..` reach the
  # store (a file link breaks pam_unix's libcrypt; merged copies break $ORIGIN/../libpam).
  pamLinks = {
    "/usr/lib/security/linux-pam" = {
      target = "${p.linux-pam}/lib/security";
      kind = "explicit";
    };
    "/usr/lib/security/systemd" = {
      target = "${p.systemd}/lib/security";
      kind = "explicit";
    };
  };

  # dash is /bin/sh (/bin -> usr/bin is made by the image builder).
  shLinks = {
    "/usr/bin/sh" = {
      target = "${p.dash}/bin/dash";
      kind = "explicit";
    };
  };

  # Farm links: directories the image builder expands file by file, subdirectories
  # included: systemd's lib/systemd (PID 1, the executor, udevd, every daemon,
  # libsystemd-shared, the units with their static .wants/, generators, presets, catalog),
  # lib/udev (rules, hwdb, the id helpers), sysusers.d, tmpfiles.d; all by systemd's
  # compiled-in /usr/lib/... paths. The D-Bus farm links are in parts/dbus.nix.
  farmLinks = {
    "/usr/lib/systemd" = {
      target = "${p.systemd}/lib/systemd";
      kind = "farm";
    };
    "/usr/lib/udev" = {
      target = "${p.systemd}/lib/udev";
      kind = "farm";
    };
    "/usr/lib/sysusers.d" = {
      target = "${p.systemd}/lib/sysusers.d";
      kind = "farm";
    };
    "/usr/lib/tmpfiles.d" = {
      target = "${p.systemd}/lib/tmpfiles.d";
      kind = "farm";
    };
    # NvPCR definitions: systemd-pcrextend (pcrproduct, pcrlogin@) and cryptsetup look
    # them up in /usr/lib/nvpcr
    "/usr/lib/nvpcr" = {
      target = "${p.systemd}/lib/nvpcr";
      kind = "farm";
    };
  };

  # dlopen: libraries systemd opens by soname (its ELF .note.dlopen, every one the fork
  # enables; libbz2 is static there); the builder checks they resolve. Their packages are
  # in the closure as systemd's dependencies, except tpm2-tss, which only dlopen reaches
  # (modules/base/default.nix lists it in packages for that reason).
  dlopenSonames = {
    "libsystemd.so.0" = p.systemd;
    "libnss_systemd.so.2" = p.systemd; # glibc NSS modules, by name too
    "libnss_myhostname.so.2" = p.systemd;
    "libacl.so.1" = p.acl;
    "libarchive.so.13" = p.libarchive;
    "libblkid.so.1" = p.util-linux;
    "libfdisk.so.1" = p.util-linux;
    "libmount.so.1" = p.util-linux;
    "libcrypto.so.3" = p.openssl;
    "libssl.so.3" = p.openssl;
    "libcryptsetup.so.12" = p.cryptsetup;
    "libcurl.so.4" = p.curl;
    "liblz4.so.1" = p.lz4;
    "liblzma.so.5" = p.xz;
    "libzstd.so.1" = p.zstd;
    "libz.so.1" = p.zlib;
    "libp11-kit.so.0" = p.p11-kit;
    "libpam.so.0" = p.linux-pam;
    "libpcre2-8.so.0" = p.pcre2;
    "libseccomp.so.2" = p.libseccomp;
    "libtss2-esys.so.0" = p.tpm2-tss;
    "libtss2-mu.so.0" = p.tpm2-tss;
    "libtss2-rc.so.0" = p.tpm2-tss;
    "libtss2-tcti-device.so.0" = p.tpm2-tss;
  };
  dlopenLinks = listToAttrs (
    map (so: {
      name = "/usr/lib/${so}";
      value = {
        target = "${dlopenSonames.${so}}/lib/${so}";
        kind = "dlopen";
      };
    }) (builtins.attrNames dlopenSonames)
  );

  # mount units and systemd-fsck exec these from util-linux (in the closure as systemd's
  # library dependency; the whole package would bring 100 more tools). blkid: lvm2's
  # 13-dm-disk.rules probes a dm device with it, and without ID_FS_USAGE systemd's
  # 99-systemd.rules keeps a CRYPT-* device (dm-verity's /usr) at SYSTEMD_READY=0 forever.
  toolLinks =
    listToAttrs (
      map
        (b: {
          name = "/usr/bin/${b}";
          value = {
            target = "${p.util-linux}/bin/${b}";
            kind = "explicit";
          };
        })
        [
          "mount"
          "umount"
          "fsck"
          "blkid"
        ]
    )
    // {
      "/usr/bin/fsck.ext4" = {
        target = "${p.e2fsprogs}/bin/fsck.ext4";
        kind = "explicit";
      };
    };
in
{
  links =
    shLinks
    // toolLinks
    // farmLinks
    // dlopenLinks
    // pamLinks
    // caBundleLinks
    // zoneinfoLinks
    // hwdbLinks;

  # /etc is created by tmpfiles at boot, and an admin file at either path wins (L, not L+)
  tmpfiles = caBundleTmpfiles;
}
