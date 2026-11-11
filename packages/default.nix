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
  # build-time: `ukify build` for the UKI (the signer, lib/image/uki.nu); off in the image's systemd
  ukify = ./ukify;
  # build-time: systemd-repart fills the ESP with mcopy/mmd (the signer, lib/image/disk.nu)
  mtools = ./mtools;
  # build-time: the initrd's newc cpio, reproducible by itself (lib/image/initrd.nu)
  gen-init-cpio = ./gen-init-cpio;
  # build-time: systemd's and ukify's Python modules
  python-jinja2 = ./python-jinja2;
  python-markupsafe = ./python-markupsafe;
  python-pyelftools = ./python-pyelftools;
  python-pefile = ./python-pefile;
  # the evaluator the dev shell and lint use
  iets = ./iets;
  # the command line, for operators' machines (cli/)
  golconda-cli = ../cli;
  # the command line's build with other phases, for checks.cli-clippy
  golconda-cli-clippy = ../cli/checks/clippy;
  # file encryption for golconda vars, on PATH beside golconda (cli/)
  age = ./age;
  # copies a release to its update source for golconda release publish (local, S3, SFTP)
  rclone = ./rclone;
  # repkgs' update tool: scripts check the packages' upstreams with it
  uptrack = ./uptrack;
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
  mdbook-pele = ./mdbook-pele;
  # Hetzner Cloud's command line, for the Hetzner run (docs/reference/hetzner-cloud.md)
  hcloud = ./hcloud;
  # the Markdown formatter and the Python libraries it needs
  mdformat = ./mdformat;
  python-mdformat-gfm = ./python-mdformat-gfm;
  python-markdown-it-py = ./python-markdown-it-py;
  python-mdit-py-plugins = ./python-mdit-py-plugins;
  python-mdurl = ./python-mdurl;
  python-wcwidth = ./python-wcwidth;
  # python's jsonschema, for checks.schema-parity, and the Python libraries it needs
  python-jsonschema = ./python-jsonschema;
  python-jsonschema-specifications = ./python-jsonschema-specifications;
  python-referencing = ./python-referencing;
  python-attrs = ./python-attrs;
  python-hatch-fancy-pypi-readme = ./python-hatch-fancy-pypi-readme;
}
