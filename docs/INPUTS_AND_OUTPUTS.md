# Native Tasks, Inputs, and Outputs in Ballad

Ballad partitures support executing native tools, build commands, and Moonstone project scripts via native tasks (`moonstone:run`, `moonstone:exec`, and `p:native_task`).

This document explains the semantics of **`inputs`**, **`outputs`**, **caching**, **change invalidation**, and **terminal sinks**.

---

## Overview

When building projects that require pre-export compilation (such as transpiling MoonScript `src/*.moon` to `dist/src/*.lua`, compiling C/Zig extensions, or running asset generators), native tasks define how subprocesses interact with Ballad's graph and cache system.

```
 ┌────────────────┐     ┌────────────────┐     ┌────────────────┐     ┌────────────────┐
 │ 1. Pre-Create  │ ──► │ 2. Subprocess  │ ──► │ 3. Output Check│ ──► │ 4. AssetSet    │
 │    Directories │     │    Execution   │     │    Verification│     │    Propagation │
 └────────────────┘     └────────────────┘     └────────────────┘     └────────────────┘
```

---

## 1. `inputs` (Source Triggers & Cache Invalidation)

- **Definition**: A list of file paths, directory paths, glob patterns (e.g. `"src/*.moon"`), or upstream `AssetSet` handles.
- **How Ballad Uses It**:
  - Ballad expands glob patterns and computes a **BLAKE3 content hash** of all matching files.
  - **Change Invalidation**: Whenever any input file is created, modified, or saved, the content hash changes. On the next `ballad play`, Ballad invalidates the cached task step and re-executes the build command.
  - **Cache Hit**: If no files matching `inputs` changed since the previous run, Ballad skips running the subprocess and reuses the cached results (`Cache hit: native task (...)`).

---

## 2. `outputs` (Verification, Assets, and Self-Healing)

- **Definition**: A list of file or directory paths that the build command promises to write (e.g. `{"dist/src/main.lua"}` or `{"dist/src"}`).
- **How Ballad Uses It**:
  - **Pre-execution Directory Creation**: Ballad automatically creates parent directories (`fs.mkdir(path.dirname(out))`) before spawning the tool so CLI utilities don't fail due to missing folders.
  - **Output Verification**: After the command exits with exit code `0`, Ballad verifies that every path listed in `outputs` exists on disk. If a command exits with code `0` but failed to create a declared output, Ballad raises a build failure error.
  - **Graph Asset Propagation**: Verified outputs are wrapped in `AssetSet` objects so downstream pipeline steps (layouts, registry packagers, or sinks) can consume them.
  - **Cache Self-Healing**: If an output file was manually deleted from disk, Ballad invalidates the cache on the next run and re-executes the command to restore the file.

---

## Usage Patterns in `partiture.lua`

### A. Explicit File Outputs (Transpilers / Bundlers)

```lua
local ballad = require("ballad")

return ballad.partiture(function(p)
  local moonstone = p:use("moonstone")

  local project = moonstone.project({ root = "." })

  -- Run `moon run build` when any src/*.moon file changes
  local build = moonstone:run("build", {
    inputs = { "src/*.moon" },
    outputs = { "dist/src/main.lua" },
  })

  -- Connect handle to terminal sink
  p.sink.none(build)
end)
```

### B. Directory Outputs (Multi-file Compilers)

```lua
  local build = moonstone:exec("moonc -t dist src/", {
    inputs = { "src/*.moon" },
    outputs = { "dist/src" },
  })
```

### C. Side-Effect Only / No Output Assets (`outputs = {}`)

```lua
  local test = moonstone:run("test", {
    inputs = { "src/*.moon", "spec/*.moon" },
    outputs = {},
  })

  p.sink.none(test)
```

---

## Terminal Sinks (`p.sink.none`)

Every Ballad partiture requires at least one explicit sink. When executing a task that generates outputs directly into the workspace or runs side-effect commands (like tests or linters), use `p.sink.none()`:

```lua
p.sink.none()                       -- 0 arguments
p.sink.none(task_handle)           -- 1 task handle
p.sink.none({ label = "my-step" })  -- options table
```
