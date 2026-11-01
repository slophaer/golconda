# Linux-PAM for sshd and the console. A farm package: libpam dlopens modules from a compiled-in
# directory (/usr/lib/security), and pam_unix, pam_timestamp & co. exec helpers by absolute path
{
  package,
  pkgs,
}:
package {
  name = "linux-pam";
  uses = [ "meson" ];
  meson.defs = {
    prefix = "/usr";
    sysconfdir = "/etc";
    docs = "disabled"; # xsltproc and docbook
    i18n = "disabled";
    audit = "disabled";
    selinux = "disabled";
    econf = "disabled";
    # pam_systemd comes from systemd, which needs no libsystemd here
    logind = "disabled";
    elogind = "disabled";
    nis = "disabled";
    pwaccess = "disabled";
    pam_userdb = "disabled";
    pam_unix = "enabled";
    # pam_unix asks getspnam() first and runs unix_chkpwd only as a fallback. The image has no
    # setuid binary, so without this every shadowed account (root included) needs the helper and
    # the account phase fails
    "pam_unix-try-getspnam" = true;
    examples = false;
  };
  # pam_start("dummy") reads /etc/pam.d/other, which is the image's and not in the sandbox
  meson.skipTests = [
    "tst-pam_(start|end|fail_delay|get_item|set_item|getenvlist|get_user|get_data|set_data)$"
  ];
  # Everything is compiled in as /usr/..., /etc/...: install into a scratch tree and take /usr
  phases.replace."meson.install" = {
    name = "install";
    run = ''
      with-env {DESTDIR: $"($c.build)/dest"} { x meson install --no-rebuild }
      ^cp -r $"($c.build)/dest/usr/." $c.out
      # prefix=/usr is where the files will be linked, not where this package is
      for f in (glob $"($c.out)/lib/pkgconfig/*.pc") { edit $f { str replace "prefix=/usr" "prefix=''${pcfiledir}/../.." } }
      rm -rf $"($c.out)/lib/systemd" # pam_namespace.service
      # The image has no setuid binaries: pam_unix's helper for callers that may not read
      # /etc/shadow is not installed (unix_update is only built with SELinux). pam_unix.so reads
      # the shadow entry itself (pam_unix-try-getspnam above)
      rm $"($c.out)/bin/unix_chkpwd"
    '';
  };
  dependencies = [ pkgs.libxcrypt ];
  bin = [ "faillock" ];
  tests.version = false;
  platforms.os = [ "linux" ];
}
