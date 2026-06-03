# Ballad

Ballad exports Moonstone-managed Lua projects into plain runtime layouts.

This is the early `v0.1.0` file-graph exporter. It reads a synchronized Moonstone project, collects project Lua files and selected Lua package modules from `.moonstone/env`, and emits a deterministic output tree plus `file-graph.json`.

## Usage

```sh
moon sync
moon run export -- . dist/ballad
```

For a LÖVE-style output layout:

```sh
moon run export -- . dist/love --love
```

or:

```sh
moon run export -- . dist/love --layout love
```

## Layouts

### `lua`

```text
dist/ballad/
  run.lua
  project/
    src/...
  lua/
    dependency.lua
  file-graph.json
```

### `love`

```text
dist/love/
  main.lua
  conf.lua
  dependency.lua
  file-graph.json
```

The `love` layout preserves project-relative paths and dependency module paths at the output root.

## Moonstone Registry Package

Ballad is distributed as a portable Moonstone `bin` package. The artifact contains a `ballad` launcher and the Lua implementation under `libexec/`; it declares `rocks:dkjson` as a transitive library dependency.

Build an upload-ready production bundle for `@moonstone/ballad`:

```sh
./release-tools/build-registry-artifact.py
```

Build a staging bundle for the test namespace:

```sh
BALLAD_PACKAGE_NAME=@kirin/ballad ./release-tools/build-registry-artifact.py
```

The generated `dist/registry/ballad-0.1.0/` directory contains `package.toml`, the deterministic artifact blob, checksums, and `publish.sh`. Upload it with:

```sh
MOONSTONE_TOKEN=... dist/registry/ballad-0.1.0/publish.sh
```

Consumers install the command as a binary dependency:

```sh
moon add --bin @moonstone/ballad
moon exec -- ballad . dist/ballad
```
