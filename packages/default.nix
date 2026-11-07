# Out-of-tree repkgs packages: name -> directory with package.nix and sources.toml.
# A name that exists in repkgs replaces the in-tree package. Every package the image needs and
# upstream repkgs lacks lives here; the repkgs fork keeps only build-system work.
{
  # kernel, init, IPC and the core system
  linux-kernel = ./kernel;
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
  # the compiled hardware database udev reads (/base links it)
  hwdb = ./hwdb;
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
  # the console's command line, for operators' machines (console/)
  golconda-console = ../console;
  # the fonts golcondad serves its pages in (console/daemon)
  ibm-plex-web = ./ibm-plex-web;
  # file encryption for golconda vars, on PATH beside golconda (console/)
  age = ./age;
  # copies a release to its update source for golconda release publish (local, S3, SFTP)
  rclone = ./rclone;
  # an S3-compatible store: the release tool's tests publish to it through rclone
  garage = ./garage;
  # development tools (nix/dev, nix/checks.nix), in place of the dev-only nixpkgs pin
  nixfmt-rs = ./nixfmt-rs;
  treefmt = ./treefmt;
  statix = ./statix;
  deadnix = ./deadnix;
  taplo = ./taplo;
  ast-grep = ./ast-grep;
  tree-sitter-nu = ./tree-sitter-nu;
  mdbook = ./mdbook;
  # Hetzner Cloud's command line, for the Hetzner run (docs/reference/hetzner-cloud.md)
  hcloud = ./hcloud;
  # the Markdown formatter and the Python libraries it needs
  python-mdformat-gfm = ./python-mdformat-gfm;
  python-markdown-it-py = ./python-markdown-it-py;
  python-mdit-py-plugins = ./python-mdit-py-plugins;
  python-mdurl = ./python-mdurl;
  python-wcwidth = ./python-wcwidth;
}
