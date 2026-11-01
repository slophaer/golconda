# Out-of-tree repkgs packages: name -> directory with package.nix and sources.toml.
# A name that exists in repkgs replaces the in-tree package. Every package the image needs and
# upstream repkgs lacks lives here; the repkgs fork keeps only build-system work.
{
  # init, IPC and the core system
  systemd = ./systemd;
  dbus-broker = ./dbus-broker;
  tpm2-tss = ./tpm2-tss;
  linux-pam = ./linux-pam;
  # userland: the image's /bin/sh and coreutils
  dash = ./dash;
  uutils-coreutils = ./uutils-coreutils;
  # remote access and network debugging
  openssh = ./openssh;
  iproute2 = ./iproute2;
  libmnl = ./libmnl;
  # the CA store
  p11-kit = ./p11-kit;
  libtasn1 = ./libtasn1;
  # the signed update index: gpg verifies SHA256SUMS.gpg (systemd-pull's argv); gpg-agent signs it
  gnupg = ./gnupg;
  libgpg-error = ./libgpg-error;
  libgcrypt = ./libgcrypt;
  libassuan = ./libassuan;
  libksba = ./libksba;
  npth = ./npth;
  # storage: dm-verity, filesystems
  cryptsetup = ./cryptsetup;
  lvm2 = ./lvm2;
  libaio = ./libaio;
  json-c = ./json-c;
  popt = ./popt;
  e2fsprogs = ./e2fsprogs;
  btrfs-progs = ./btrfs-progs;
  # build-time: the /usr image, the ESP and the UKI
  erofs-utils = ./erofs-utils;
  dosfstools = ./dosfstools;
  # build-time: `ukify build` for the UKI (lib/image/uki.nix); off in the image's systemd
  ukify = ./ukify;
  # build-time: systemd-repart fills the ESP with mcopy/mmd (lib/image/disk.nix)
  mtools = ./mtools;
  # build-time: systemd's and ukify's Python modules
  python-jinja2 = ./python-jinja2;
  python-markupsafe = ./python-markupsafe;
  python-pyelftools = ./python-pyelftools;
  python-pefile = ./python-pefile;
  # the evaluator the dev shell and lint use
  iets = ./iets;
}
