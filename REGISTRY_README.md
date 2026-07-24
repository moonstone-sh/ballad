# Ballad

Ballad turns a Moonstone project into explicit, inspectable release outputs.
Write a small Lua **partiture** that declares the source, transforms, and sinks;
Ballad plans the graph, reuses cacheable work, and materializes the result.

## Install

```sh
moon add moonstone/ballad --tool
moon exec ballad --help
```

## Export a CLI

Create `partiture.lua` in a synchronized Moonstone project:

```lua
local ballad = require("ballad")

return ballad.partiture(function(p)
  local moonstone = p:use(ballad.plugins.moonstone)
  local layout = p:use(ballad.plugins.layout)

  local project = moonstone.project({ root = "." })
  local app = layout.exec(project, {
    name = project.name,
    entry = "src/main.lua",
    bin = project.name,
    interpreter = "lua",
  })

  p.sink.directory(app, { out = "dist" })
end)
```

```sh
moon sync
moon exec ballad play partiture.lua
```

```mermaid
flowchart LR
  Source[Moonstone project] --> Layout[layout.exec]
  Layout --> Sink[dist/]
```

## Why the graph matters

- Every source, transform, and sink is explicit and inspectable.
- Cacheable nodes reuse matching products across compatible partitures.
- Output manifests make release contents reviewable before publishing.
- Non-cacheable effects—such as publishing or starting a watcher—remain visible
  boundaries instead of hidden build behavior.

Use `moonstone.registry.package(...)` when the graph should also produce a
Moonstone Registry artifact. The repository contains deeper architecture,
plugin, and release documentation.
