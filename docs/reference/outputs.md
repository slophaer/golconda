# Outputs and inputs

`default.nix` is the entry point for both classic Nix and iets; `flake.nix` calls it. The output
schema is the flake one, produced by flake-incompat.

## Outputs

| attribute                    | per system | content                          |
| ---------------------------- | ---------- | -------------------------------- |
| `packages.<system>`          | yes        | repkgs packages Golconda exposes |
| `checks.<system>`            | yes        | `treefmt`, `docs`, `boundary`    |
| `formatter.<system>`         | yes        | treefmt with pinned tools        |
| `devShells.<system>.default` | yes        | treefmt, mdbook, iets, npins     |
| `lib.system`                 | no         | `supported`, `elaborate`         |
| `modules`                    | no         | the adios tree                   |

## Inputs

Pinned in `npins/sources.json`: `repkgs`, `adios`, `flake-incompat`, `iets`, and `nixpkgs-dev-only`
(developer tooling, nowhere else).
