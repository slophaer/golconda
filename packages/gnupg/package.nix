# GnuPG 2.4 LTS, built for the signed update index: gpg verifies SHA256SUMS.gpg (the argv
# systemd-pull uses) and, on the build host, gpg-agent holds the signing key. No X.509 service,
# keyserver, smartcard, database or TLS code: the build host talks to nothing but its keyring.
{
  package,
  pkgs,
  buildPkgs,
}:
package {
  name = "gnupg";
  uses = [ "autotools" ];
  # Upstream finds gpg-agent (bindir) and the helpers (libexecdir) by compiled-in paths, with
  # gpgconf.ctl as the one override, which needs an absolute rootdir. The patch makes the
  # directory above the running executable the root, so gpg starts bin/gpg-agent from wherever
  # the package is, and keeps /usr paths only for a system without /proc. It also gives a spawned
  # helper its full path as argv[0]: bin/ holds launchers (the libraries' bin/ dirs go on PATH),
  # and a launcher looks itself up by argv[0], which upstream cut down to "gpg-agent"
  patches = [ ./relocatable.patch ];
  autotools.flags = [
    "--sysconfdir=/etc" # /etc/gnupg holds gpg.conf and the system trust settings
    "--localstatedir=/var"
    "--disable-doc"
    "--disable-gpgsm" # X.509 and CMS
    "--disable-dirmngr" # keyservers, WKD, CRLs
    "--disable-scdaemon" # smartcards
    "--disable-card-support"
    "--disable-ccid-driver"
    "--disable-keyboxd" # the sqlite keybox daemon: gpg keeps keyring files
    "--disable-sqlite"
    "--disable-tofu"
    "--disable-tpm2d"
    "--disable-wks-tools"
    "--disable-gpgtar"
    "--disable-ldap"
    "--disable-gnutls"
    "--disable-ntbtls"
    "--disable-libdns"
    "--disable-photo-viewers"
    "--disable-bzip2"
    "--without-readline"
  ];
  # upstream's suite: the OpenPGP half. `make check` also runs the gpgsm tests, which have no gpgsm
  autotools.testTarget = [
    "-C"
    "tests/openpgp"
    "check"
  ];
  # install puts every tool of the tree into bin/, whatever --disable-* says. Keep what verifying and
  # signing use. The rest: sh scripts for multi-user setups (addgnupghome, applygnupgdefaults), the
  # test suite's scheme interpreter, the wks client (a dirmngr peer, with a libexec/ sh stub that
  # names $bindir), and tools for cards, mail and keybox files. kbxutil is the only user of libksba
  phases.after."autotools.install" = {
    name = "drop-tools";
    run = ''
      for t in [addgnupghome applygnupgdefaults gpgscm gpg-wks-client gpg-card gpg-mail-tube gpgparsemail gpgsplit kbxutil watchgnupg] {
        ^rm -f $"($c.out)/bin/($t)" $"($c.out)/libexec/($t)"
      }
    '';
  };
  buildDependencies = [ buildPkgs.libgpg-error ]; # configure runs gpgrt-config
  dependencies = [
    pkgs.libgpg-error
    pkgs.libgcrypt
    pkgs.libassuan
    pkgs.libksba # configure requires it even with gpgsm and dirmngr off
    pkgs.npth
    pkgs.zlib
  ];
  bin = [
    "gpg"
    "gpgv"
    "gpg-agent"
    "gpg-connect-agent"
    "gpgconf"
  ];
  platforms.os = [ "linux" ];
}
