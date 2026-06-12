# Ballad Architecture

Ballad has a legacy exporter plus the vNext partiture pipeline. The vNext model is a DAG of first-class sources, transform plugins, and explicit sinks.

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

Legacy export orchestration:

1. load Moonstone project metadata
2. reset the output directory
3. copy project Lua files
4. copy selected package Lua modules from `.moonstone/env`
5. write `file-graph.json`
6. write `run.lua` for the plain Lua layout

### `ballad.pipeline`

Partiture graph orchestration:

1. construct source, transform, and sink nodes
2. validate that at least one explicit `p.sink.*` node exists
3. reject dangling transform leaves
4. plan the sink-reachable graph and progress weights
5. execute the planned graph and write debug metadata
6. materialize terminal outputs through core sink handlers

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

## Plugin seam

Plugins provide transforms only. Ballad core owns run boundaries and terminal materialization:

```text
source -> transform -> sink
```
