# Modules

One page per adios module, generated from its `options` and types. Until the generator exists, the
tree is `modules/`:

| path      | role                                                                                            |
| --------- | ----------------------------------------------------------------------------------------------- |
| `/types`  | the `fragment` type                                                                             |
| `/system` | the composer: `name`, `version`, `fragments` → `{ units; files; sysusers; tmpfiles; packages }` |
