# Ballad Architecture

Ballad is split around a small v0.1 exporter pipeline.

```text
src/main.lua
  -> ballad.cli
  -> ballad.exporter
  -> ballad.project
  -> ballad.fs / ballad.path / ballad.lockfile / ballad.toml / ballad.json
```

## Modules

### `ballad.cli`

Argument parsing and help output.

### `ballad.exporter`

The actual export orchestration:

1. load Moonstone project metadata
2. reset the output directory
3. copy project Lua files
4. copy selected package Lua modules from `.moonstone/env`
5. emit `file-graph.json`
6. emit `run.lua` for the plain Lua layout

### `ballad.project`

Project root discovery and loading of:

- `moonstone.toml`
- `moonstone.lock`
- `.moonstone/env/env.toml`

### `ballad.fs`

Filesystem and shell-backed file operations.

### `ballad.path`

Path manipulation, module name conversion, ABI directory conversion.

### `ballad.lockfile`

Minimal lockfile parsing and artifact source matching.

### `ballad.toml`

Minimal TOML parser for the subset Ballad currently needs.

## Future plugin seam

The current exporter has a single central `add_file` point. This is the natural seam for v0.2 plugin hooks:

```text
discover -> load -> transform -> emit -> finalize
```

For v0.1, keeping the exporter boring is intentional.
