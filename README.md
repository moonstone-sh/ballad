# Ballad

Ballad exports Moonstone-managed Lua projects through a deterministic pipeline. A partiture declares explicit sources, plugin transforms, and sinks; Ballad core owns planning, execution, file materialization, file graphs, and artifacts.

## Usage

Ballad runs partitures. With no command, it defaults to `partiture.lua`:

```sh
moon sync
moon exec ballad
```

You can also pass a partiture explicitly:

```sh
moon exec ballad -- play partiture.lua
moon exec ballad -- ./release.partiture.lua
```

## Partiture API

Plugins provide transforms only. Use `p.sink.*` for terminal outputs; every partiture must declare at least one explicit sink.

```lua
local ballad = require("ballad")

return ballad.partiture(function(p)
  local moonstone = p:use(ballad.plugins.moonstone)
  local layout = p:use(ballad.plugins.layout)
  local registry = p:use(ballad.plugins.registry)

  local project = moonstone.project({ root = "." })
  local app = layout.libexec(project, {
    name = "ballad",
    entry = "src/main.lua",
    bin = "ballad",
    interpreter = "luajit",
  })

  local artifact = registry.package(app, {
    name = project.registry_name or "moonstone/ballad",
    version = project.version,
    target = "any",
    runtime = project.runtime_spec,
    lua_abi = project.lua_abi,
  })

  p.sink.directory(app, { out = "dist/ballad", file_graph = true })
  p.sink.artifact(artifact, { out = "dist/ballad/registry-artifact" })
end)
```

Core namespaces:

- `p.source.directory(path, opts)` introduces files from a directory.
- `p.source.files(patterns, opts)` introduces files matching glob-style patterns.
- `p.source.stdin(opts)` introduces stdin as a generated asset.
- `p.sink.directory(input, opts)` writes an asset set to a directory.
- `p.sink.stdout(input, opts)` prints graph data to stdout.
- `p.sink.file_graph(input, opts)` writes file graph JSON.
- `p.sink.artifact(input, opts)` writes a single artifact output.

## LÖVE Example

```lua
local ballad = require("ballad")

return ballad.partiture(function(p)
  local moonstone = p:use(ballad.plugins.moonstone)
  local love = p:use(ballad.plugins.love)

  local project = moonstone.project({ root = "." })
  local app = love.layout(project, {
    main = "main.lua",
    conf = "conf.lua",
    include = { "main.lua", "conf.lua", "src/**", "assets/**" },
  })

  p.sink.directory(app, { out = "dist/love-root", file_graph = true })
  p.sink.artifact(love.pack(app, { name = project.name }), {
    out = "dist/" .. project.name .. ".love",
  })
end)
```

## Moonstone Registry Package

Ballad is distributed as a portable Moonstone `bin` package. The artifact contains a `ballad` launcher and the Lua implementation under `libexec/`; it declares `rocks:dkjson` as a transitive library dependency.

Build an upload-ready production bundle for `@moonstone/ballad`:

```sh
./release-tools/build-registry-artifact.py
```
