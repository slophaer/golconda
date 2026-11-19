#! OpenSSH daemon as a service, with its host key as a var. An optional component: `["/services/sshd"]`, empty for the defaults.
#! Login is by public key or OpenSSH certificate only. The lines that turn off every password path are fixed in the generated `sshd_config`.
#! Only credentials go on the command line; every fixed path is a line in `sshd_config`. `/etc/pam.d/sshd` is in `/factory`.
#! `revokedKeys` and `hostCertificate` take admin vars; until a KRL is pushed, sshd reads `imageRevokedKeys`; with `hostCertificate`, plain keys stop once the host certificate is sealed.
#! The fragment, the options and the boot health unit: docs/reference/modules/README.md. The model: docs/design/trust.md, "Identity", and docs/features/ssh-login.md.
{ types, ... }:
let
  s = import ../../lib/service.nix { inherit types; };
  v = import ../../lib/var.nix { inherit types; };
  merge = import ../../lib/merge.nix;
  base64 = import ../../lib/base64.nix;

  # An OpenSSH KRL (`ssh-keygen -k`) in base64: a KRL is binary, and a Nix string cannot hold its
  # NUL bytes. Checked for the KRL magic, so a text list of keys is refused; at most 256 KiB of
  # base64 (192 KiB of KRL), as the unit holds it on one line, four characters a byte (systemd
  # reads a line of at most 1 MiB).
  # "SSHKRL\n\0" (OpenSSH krl.h, KRL_MAGIC)
  krlMagic = [
    83
    83
    72
    75
    82
    76
    10
    0
  ];
  krl = types.typedef' "krlBase64" (
    v:
    let
      d = base64.decode v;
    in
    if !builtins.isString v then
      "Expected an OpenSSH KRL in base64 (base64 -w0 <krl>), got ${builtins.typeOf v}"
    else if builtins.stringLength v > 262144 then
      "An image KRL is at most 262144 characters of base64 (192 KiB)"
    else
      d.error or (
        if builtins.length d.bytes < 8 || builtins.genList (builtins.elemAt d.bytes) 8 != krlMagic then
          "Expected an OpenSSH KRL (ssh-keygen -k), whose bytes begin with SSHKRL; a list of public keys is not one"
        else
          null
      )
  );

  # A TCP port to listen on: 1 to 65535. 0 would be a port the kernel picks, unknown to anyone
  # who connects.
  port = types.typedef' "port" (
    v:
    if !builtins.isInt v then
      "Expected an integer"
    else if v < 1 || v > 65535 then
      "${toString v} is not a TCP port (1 to 65535)"
    else
      null
  );

  hostkeyVar = "sshd-hostkey";
  # /usr/lib/sshd: sshd_config, ca.pub, authorized_keys/<user>, principals/<user>
  dir = s.filesDir "sshd";
  # The admin-supplied vars (docs/design/trust.md): the host certificate the
  # host CA signs, and the key revocation list. The deploy host pushes
  # them; sshd loads the credentials <name>.<file> when
  # hostCertificate or revokedKeys is on. The image declares both either way.
  hostCertVar = v.admin {
    name = "sshd-host-cert";
    files = [ "cert" ];
    consumers = [ "sshd.service" ];
  };
  revokedKeysVar = v.admin {
    name = "sshd-revoked-keys";
    files = [ "krl" ];
    consumers = [ "sshd.service" ];
  };
in
{
  name = "sshd";

  inputs.pkgs.path = "/pkgs";

  options = {
    port = {
      type = port;
      default = 22;
      description = "Listening port.";
    };
    authorizedKeys = {
      type = types.listOf types.string;
      default = [ ];
      description = "Public keys that may log in as root (/usr/lib/sshd/authorized_keys/root). For bootstrap; certificates are the normal path. With hostCertificate on, plain keys stop once the host certificate is sealed.";
    };
    trustedUserCAKeys = {
      type = types.listOf types.string;
      default = [ ];
      description = "Public keys of the user CAs whose certificates may log in (/usr/lib/sshd/ca.pub, TrustedUserCAKeys).";
    };
    principals = {
      type = types.attrsOf (types.listOf types.string);
      default = { };
      description = "User -> certificate principals allowed to log in as that user (/usr/lib/sshd/principals/<user>, AuthorizedPrincipalsFile). Needs trustedUserCAKeys.";
    };
    revokedKeys = {
      type = types.bool;
      default = false;
      description = "Refuse the keys in the admin-supplied revocation list (admin var sshd-revoked-keys, file krl; RevokedKeys reads the credential). Until it is pushed, sshd reads imageRevokedKeys; without it, a list that names the user CAs (trustedUserCAKeys): certificates are refused, plain keys log in.";
    };
    imageRevokedKeys = {
      type = types.option krl;
      default = null;
      description = "The user CA's KRL as the image carries it, in base64 (`base64 -w0 revoked.krl`); needs revokedKeys. Until the admin var sshd-revoked-keys is pushed, and again after a factory reset, sshd reads this list: certificates log in unless it names them.";
    };
    hostCertificate = {
      type = types.bool;
      default = false;
      description = "Present the admin-supplied host certificate (admin var sshd-host-cert, file cert) with the host key (HostCertificate). Until it is pushed, sshd logs that it is missing and presents the plain host key; once it is sealed, sshd refuses every plain key (authorizedKeys, /root/.ssh/authorized_keys): only certificates log in. Needs trustedUserCAKeys.";
    };
  };

  impl =
    { options, results }:
    let
      # OpenSSH from the target set; `[golconda] replaces` swaps it (docs/features/extending.md)
      inherit (results.pkgs.pkgs) openssh;
      inherit (builtins)
        attrNames
        listToAttrs
        ;
      inherit (import ../../lib/text.nix) lines;
      on = import ../../lib/on.nix;

      # The ed25519 host key, generated on the machine on first boot and
      # sealed to its TPM; the public half stays readable for the CA. Its
      # fingerprint goes to the journal and the console: before the CA signs
      # the key that `golconda vars pub` reads over the network, the operator
      # compares it with this line, on a channel the network cannot change.
      hostkey = v.render {
        name = hostkeyVar;
        secrets = [ "key" ];
        publics = [ "key.pub" ];
        script = builtins.concatStringsSep "\n" [
          "ssh-keygen -q -t ed25519 -N '' -f key"
          "fp=\"golconda: ssh host key $(ssh-keygen -l -f key.pub)\""
          "echo \"$fp\""
          "echo \"$fp\" > /dev/console || true"
        ];
        packages = [ openssh ];
      };

      hasCA = options.trustedUserCAKeys != [ ];
      hasPrincipals = options.principals != { };
      hasKRL =
        if options.imageRevokedKeys != null && !options.revokedKeys then
          throw "golconda: /services/sshd.imageRevokedKeys needs revokedKeys = true: it is what sshd reads until the revocation list is pushed"
        else
          options.revokedKeys;

      # Until a KRL is pushed, PID 1 gives sshd a fallback revocation list (SetCredential=): the
      # image's KRL, which a factory reset keeps, or else a list that names the user CAs. sshd
      # refuses every key when RevokedKeys= names no readable file, and the CA list refuses every
      # certificate the CAs signed, so revocation is never off while the plain bootstrap keys log
      # in for the push (docs/design/trust.md).

      # Fail closed once certified: when the host certificate is sealed, plain keys stop and only
      # certificates of the user CAs log in. golconda-sshd-certified.service links certified.conf
      # (AuthorizedKeysFile none) into /run/golconda-sshd; sshd_config includes that directory
      # before its AuthorizedKeysFile line, and sshd takes the first value it reads. The unit is
      # PartOf= sshd, so the push's restart runs it again, and RuntimeDirectory= empties the
      # directory on each stop. The credential is on the state partition: the refusal survives
      # reboots and updates, and only a reflash undoes it.
      certifiedUnit = "golconda-sshd-certified.service";
      certifiedDir = "/run/golconda-sshd";
      hostCertSealed = "/etc/credstore.encrypted/${v.credentialId "sshd-host-cert" "cert"}";
      certified = {
        units.${certifiedUnit} = lines [
          "# Generated by Golconda (/services/sshd), docs/design/trust.md \"Host certificate\""
          "[Unit]"
          "Description=sshd: plain keys stop once the host certificate is sealed"
          "ConditionPathExists=${hostCertSealed}"
          "PartOf=sshd.service"
          "Before=sshd.service"
          ""
          "[Service]"
          "Type=oneshot"
          "RemainAfterExit=yes"
          "RuntimeDirectory=golconda-sshd"
          "ExecStart=/usr/bin/ln -s ${dir}/certified.conf ${certifiedDir}/certified.conf"
        ];
      };

      krlFallback = lines (
        [
          "# Golconda (modules/services/sshd): no revocation list was pushed yet; until one is, the certificates of these user CAs are refused."
        ]
        ++ options.trustedUserCAKeys
      );

      sshdConfig = lines (
        [
          "# Generated by Golconda (modules/services/sshd). The host key, the"
          "# host certificate and the revocation list are systemd credentials:"
          "# they come on the command line as -h and -o Option=<credential>."
        ]
        # first: a file here sets AuthorizedKeysFile before the line below does
        ++ on options.hostCertificate [ "Include ${certifiedDir}/*.conf" ]
        ++ [
          "Port ${toString options.port}"
          "AuthorizedKeysFile .ssh/authorized_keys ${dir}/authorized_keys/%u"
        ]
        ++ on hasCA [ "TrustedUserCAKeys ${dir}/ca.pub" ]
        ++ on hasPrincipals [ "AuthorizedPrincipalsFile ${dir}/principals/%u" ]
        ++ [
          # keys and certificates only; PAM does account and session, not auth
          "PasswordAuthentication no"
          "KbdInteractiveAuthentication no"
          "ChallengeResponseAuthentication no"
          "PermitRootLogin prohibit-password"
          "UsePAM yes"
          # the certificate principal and key id are the audit trail
          "LogLevel VERBOSE"
          "PidFile none"
          # file transfer without a second binary: sshd_config content, not a unit field
          "Subsystem sftp internal-sftp"
        ]
      );

      service = s.render {
        name = "sshd";
        app = {
          package = openssh;
          program = "sshd";
          argv = [
            "-D"
            "-e"
            "-f"
            "${dir}/sshd_config"
            "-h"
            (s.credential "hostkey")
          ]
          ++ on options.hostCertificate [
            "-o"
            (s.credentialArg "HostCertificate=" "hostcert")
          ]
          ++ on hasKRL [
            "-o"
            (s.credentialArg "RevokedKeys=" "krl")
          ];
          files = {
            sshd_config = sshdConfig;
          }
          // on (options.authorizedKeys != [ ]) {
            "authorized_keys/root" = lines options.authorizedKeys;
          }
          // on hasCA { "ca.pub" = lines options.trustedUserCAKeys; }
          // on options.hostCertificate { "certified.conf" = lines [ "AuthorizedKeysFile none" ]; }
          // listToAttrs (
            map (u: {
              name = "principals/${u}";
              value = lines options.principals.${u};
            }) (attrNames options.principals)
          );
        };
        credentials = {
          hostkey = v.credentialId hostkeyVar "key";
        }
        // on hasKRL { krl = v.credentialId "sshd-revoked-keys" "krl"; }
        // on options.hostCertificate { hostcert = v.credentialId "sshd-host-cert" "cert"; };
        credentialFallbacks = on hasKRL {
          krl =
            if options.imageRevokedKeys != null then { base64 = options.imageRevokedKeys; } else krlFallback;
        };
        # sshd runs as root and spawns user sessions, which must see the real
        # system: sandbox "trusted" (no directive).
        user = "root";
        sandbox = "trusted";
        # a restart of sshd must not end the sessions it spawned; the
        # privilege-separation directory is /var/empty (repkgs openssh,
        # --with-privsep-path), so no RuntimeDirectory= is needed
        killMode = "process";
        after = [
          "network.target"
          (v.unitName hostkeyVar)
          # PCR 11 holds enter-initrd:leave-initrd:sysinit from this barrier on; a
          # service with default dependencies (after basic.target) starts later, and
          # sshd must not load the sealed host key before the phase its .pcrsig
          # signs (image/uki.nix, systemd-pcrphase.service(8)).
          "systemd-pcrphase-sysinit.service"
        ]
        ++ on options.hostCertificate [ certifiedUnit ];
        wants = [ (v.unitName hostkeyVar) ] ++ on options.hostCertificate [ certifiedUnit ];
      };

      # Boot health, sshd half. There is no local login, so a candidate whose sshd does
      # not run is not usable and must not be blessed: systemd-bless-boot clears the
      # boot counter when boot-complete.target is reached, and the stock target needs
      # only sysinit.target. The check is `systemctl is-active sshd.service`, nothing
      # more (docs/design/boot.md states what that leaves out). Pulled in by
      # boot-complete.target.requires and ordered by Before=.
      healthService = {
        units."golconda-health-sshd.service" = lines [
          "# Generated by Golconda (/services/sshd), docs/design/boot.md"
          "[Unit]"
          "Description=Golconda health: sshd is running"
          "Documentation=man:sshd(8)"
          "After=sshd.service"
          "Before=boot-complete.target"
          ""
          "[Service]"
          "Type=oneshot"
          "RemainAfterExit=yes"
          "ExecStart=/usr/bin/systemctl is-active --quiet sshd.service"
        ];
        links."/usr/lib/systemd/system/boot-complete.target.requires/golconda-health-sshd.service" = {
          target = "../golconda-health-sshd.service";
          kind = "explicit";
        };
      };
    in
    # without a user CA no certificate logs in: hostCertificate would refuse every login once
    # the certificate is sealed, and principals would have no effect
    if !hasCA && options.hostCertificate then
      throw "/services/sshd: hostCertificate needs trustedUserCAKeys: once the host certificate is sealed, only certificates log in"
    else if !hasCA && hasPrincipals then
      throw "/services/sshd: principals needs trustedUserCAKeys: principals select certificates of a user CA"
    else
      merge (
        [
          hostkey
          service
          healthService
          (on options.hostCertificate certified)
          # the privilege-separation user and its empty directory (repkgs
          # openssh: --with-privsep-path=/var/empty)
          {
            sysusers = [ "u sshd - \"SSH privilege separation\" /var/empty" ];
            tmpfiles = [ "d /var/empty 0755 root root -" ];
            # sshd execs sshd-session, sshd-auth and sftp-server by the compiled-in
            # path /usr/lib/ssh (repkgs openssh: --libexecdir=/usr/lib/ssh)
            links."/usr/lib/ssh" = {
              target = "${openssh}/lib/ssh";
              kind = "farm";
            };
          }
        ]
        # declared whether or not the options use them: a release with the options off
        # accepts a push that a later release reads (docs/design/trust.md, "Identity")
        ++ [
          revokedKeysVar
          hostCertVar
        ]
      )
      // {
        name = "/services/sshd";
      };
}
