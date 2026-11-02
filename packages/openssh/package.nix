# OpenSSH client and server. A farm package: sshd execs sshd-session, sshd-auth and sftp-server by
# a compiled-in path (/usr/lib/ssh), so it is configured for /usr and installed through DESTDIR
{
  package,
  pkgs,
}:
package {
  name = "openssh";
  uses = [ "autotools" ];
  prefix = "/usr";
  autotools.flags = [
    "--sbindir=/usr/bin"
    "--sysconfdir=/etc/ssh"
    "--libexecdir=/usr/lib/ssh"
    "--with-pid-dir=/run"
    "--with-privsep-path=/var/empty"
    "--with-privsep-user=sshd"
    "--with-default-path=/usr/bin"
    "--with-superuser-path=/usr/bin"
    "--with-pam"
    "--without-kerberos5"
    "--without-libedit"
    "--without-selinux"
    "--disable-strip"
  ];
  # install-nokeys: the Makefile's `install` also generates host keys and runs sshd -t. Everything
  # lands below /usr, /etc and /var in the scratch tree; /usr is the output
  phases.replace."autotools.install" = {
    name = "install";
    run = ''
      with-env {DESTDIR: $"($c.build)/dest"} { x make install-nokeys }
      ^cp -r $"($c.build)/dest/usr/." $c.out
      # the stock configuration and the DH moduli sshd reads from /etc/ssh, for the image to start from
      mkdir $"($c.out)/share/openssh"
      ^cp ...(glob $"($c.build)/dest/etc/ssh/*") $"($c.out)/share/openssh"
    '';
  };
  dependencies = [
    pkgs.openssl
    pkgs.zlib
    pkgs.libxcrypt
    pkgs.linux-pam
  ];
  tests.run = false; # the suite starts sshd as a user and needs the sshd account and ports
  tests.version = "-V";
  bin = [
    "ssh"
    "sshd"
    "ssh-keygen"
    "ssh-keyscan"
    "ssh-add"
    "ssh-agent"
    "scp"
    "sftp"
  ];
  platforms.os = [ "linux" ];
}
