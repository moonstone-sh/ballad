# Ballad agent guide

Ballad is the deterministic Lua exporter and pipeline runner. The public
contract is documented in [`README.md`](README.md); package consumers should use
[`REGISTRY_README.md`](REGISTRY_README.md).

## Workflow

```sh
moon sync
moon exec ballad -- play partiture.lua
```

Keep partitures declarative: sources, transforms, native tasks, and sinks must
be explicit and reproducible. Preserve stable file graphs and cache behavior.
Put implementation rationale in [`docs/`](docs/), not in this file.

Before submitting changes, run the focused Lua tests and at least one real
export (including a registry export when registry behavior changed). Never
commit `.ballad/`, `dist/`, or generated package artifacts.
