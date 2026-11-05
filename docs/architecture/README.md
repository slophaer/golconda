# Architecture diagrams

The C4 model of Golconda, written as text for [LikeC4](https://likec4.dev). One model holds every
element and relationship; each view picks what to show. The design pages say why; this model shows
how the parts connect.

## Views

| view                    | level      | shows                                                                                             |
| ----------------------- | ---------- | ------------------------------------------------------------------------------------------------- |
| `index`                 | context    | Golconda, its people, its build-time dependencies and the systems around a running server         |
| `build-containers`      | container  | the build host: evaluation, the `/usr` tree builder, the image chain, keys, release, tools        |
| `machine-containers`    | container  | a server: ESP, `/usr` slots, state, the boot chain, systemd, sshd, vars, the boot gate, sysupdate |
| `console-containers`    | container  | the planned console (`golcondad`) and the vars deploy tool                                        |
| `evaluation-components` | component  | the adios modules, the composer, and the fragments the build adds itself                          |
| `usr-origins`           | component  | every part of `/usr` and where it comes from: a module, a build fragment, or the build itself     |
| `usr-readers`           | component  | which part of the machine reads each part of `/usr`                                               |
| `imagechain-components` | component  | the image steps, the keys each signs with, and what each writes                                   |
| `initrd-components`     | component  | what the initrd does before switch-root                                                           |
| `runtime-components`    | component  | PID 1 and the systemd services every image has                                                    |
| `bootgate-components`   | component  | the health checks, boot blessing and the loader update                                            |
| `build-release`         | dynamic    | `lib.mkImage` from `server.toml` to a published release                                           |
| `first-boot`            | dynamic    | firmware to a blessed entry on a fresh disk                                                       |
| `update-and-fallback`   | dynamic    | an A/B update, and the fallback after three failed boots                                          |
| `deployment-overview`   | deployment | the build host, the update server, the deploy host and a server's partitions                      |

## Conventions

- Every element has a kind: person, software system, container, data store, component, or content.
  Content is a part of a data store, such as a file in `/usr`, with one origin.
- Grey elements are owned by someone else (tag `#external`).
- Muted elements are not built yet (tag `#planned`). Their titles say *(planned)* or *(after v1)*,
  as the design pages do. Planned relationships are dotted (kind `planned`).
- In the `/usr` views, slate content comes from a module's fragment. Amber marks a fragment that the
  build adds itself and that is not a module (`/image/loader`, `/image/index`, `/image/initrd`);
  `modules.json` lists these under `fragments`. Red marks a file that the build writes outside any
  fragment (`os-release`, `config.json`, `schema.json`, `modules.json`, `sbom.json`,
  `packages.json`, `attribution.json`).

## Files

| file                 | holds                                                       |
| -------------------- | ----------------------------------------------------------- |
| `likec4.config.json` | the project name; relationships are solid unless planned    |
| `spec.c4`            | the element kinds, deployment node kinds and tags           |
| `context.c4`         | people and outside systems                                  |
| `build.c4`           | the build side: data stores, evaluation, image chain, tools |
| `usr.c4`             | the `/usr` image, its parts, and who writes each            |
| `machine.c4`         | the server side: disk, boot chain, runtime                  |
| `console.c4`         | the planned console and vars deploy tool                    |
| `views.c4`           | the static views                                            |
| `dynamic.c4`         | the dynamic views                                           |
| `deployment.c4`      | the deployment model and its view                           |

## Working on it

```sh
likec4 validate --json --no-layout docs/architecture
likec4 format docs/architecture
likec4 start docs/architecture
```

Keep the model in step with the design pages. When a planned element is built, remove its `#planned`
tag and the *(planned)* in its title.
