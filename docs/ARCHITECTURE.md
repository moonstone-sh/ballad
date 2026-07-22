# Ballad Architecture

Ballad is a partiture-only exporter. A partiture is a DAG of first-class sources, transform plugins, and explicit sinks.

```text
src/main.lua
  -> ballad.cli
  -> ballad.partiture
  -> ballad.pipeline
  -> ballad.project
  -> ballad.fs / ballad.path / ballad.lockfile / ballad.toml
```

## Modules

### `ballad.cli`

Argument parsing and help output.

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

The Moonstone plugin can introduce a synchronized executable scope with
`moonstone.tool(project, { name = "tool-name" })`. It emits a generic tool
asset plus source assets for the scope's executable, Lua roots, native-module
roots, and dependent executable directories. `layout.exec(...)` consumes that
asset set to create a runnable tool distribution.
