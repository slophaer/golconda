# Summary

[Golconda](index.md)

[What is proven](proven.md)

[The v1 checklist](v1.md)

# Features

- [One image for every machine](features/one-image.md)
- [A read-only, verified /usr](features/verified-usr.md)
- [Only signed code runs](features/execution-policy.md)
- [Secure Boot and measured boot](features/measured-boot.md)
- [A/B updates with health-checked rollback](features/updates.md)
- [Reproducible, signed releases](features/signed-releases.md)
- [Secrets as vars](features/vars.md)
- [Provisioning without cloud-init](features/provisioning.md)
- [Certificate login, no local login](features/ssh-login.md)
- [Factory reset and recovery](features/factory-reset.md)
- [One of each](features/one-of-each.md)
- [Typed modules, duplicates are errors](features/typed-modules.md)
- [Configuration as data](features/config-as-data.md)
- [Your own modules and packages](features/extending.md)

# Guides

- [Walkthrough](reference/walkthrough.md)
- [Pinning Golconda in your repository](reference/pinning.md)
- [Build host](reference/build-host.md)
- [Making a release](reference/release.md)
- [Deploying to Hetzner Cloud](reference/hetzner-cloud.md)

# Design

- [Principles](design/principles.md)
- [Scope](design/scope.md)
- [Architecture](design/architecture.md)
- [Layout](design/layout.md)
- [Boot](design/boot.md)
- [Boot loader](design/bootloader.md)
- [Updates](design/updates.md)
- [Releases](design/releases.md)
- [Recovery](design/recovery.md)
- [Trust](design/trust.md)
- [Kernel](design/kernel.md)
- [Modules](design/modules.md)
- [Configuration](design/config.md)
- [Packaging](design/packaging.md)
- [Comparison](design/comparison.md)

# Reference

- [Partitions and paths](reference/layout.md)
- [Image artifacts](reference/image.md)
- [Modules](reference/modules/README.md)
  - [`/base`](reference/modules/generated/base.md)
  - [`/factory`](reference/modules/generated/factory.md)
  - [`/imds`](reference/modules/generated/imds.md)
  - [`/network`](reference/modules/generated/network.md)
  - [`/pkgs`](reference/modules/generated/pkgs.md)
  - [`/security`](reference/modules/generated/security.md)
  - [`/services`](reference/modules/generated/services.md)
    - [`/services/sshd`](reference/modules/generated/services-sshd.md)
  - [`/system`](reference/modules/generated/system.md)
  - [`/vars`](reference/modules/generated/vars.md)
  - [Types](reference/modules/generated/types.md)
- [Configuration](reference/config.md)
- [Commands](reference/cli.md)
- [Outputs and inputs](reference/outputs.md)
- [Glossary](reference/glossary.md)
