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
  # install-nokeys: the Makefile's `install` also generates host keys and runs sshd -t
  autotools.installTarget = [ "install-nokeys" ];
  # the install lands below /usr, /etc/ssh and /var in the builder's scratch tree; /usr is the
  # output. The stock configuration and the DH moduli sshd reads from /etc/ssh go to
  # share/openssh, for the image to start from
  stagedRoots = {
    "/etc/ssh" = "share/openssh";
    "/var" = null;
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
