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

## Executable App Layout

Use `layout.exec` for a distributable app directory with a launcher under `bin/` and project/runtime files under `libexec/`:

```lua
local project = moonstone.project({ root = "." })
local app = layout.exec(project, {
  name = "meteorite",
  entry = "src/main.lua",
  bin = "meteorite",
  interpreter = "lua",
})

p.sink.directory(app, { out = "dist/meteorite", file_graph = true })
```

For Lua+Zig projects, run the Zig build as a native task before the sink or registry artifact so compiled Lua C modules exist in `.moonstone/env/lib/lua/<abi>/` and are copied into `libexec/<name>/lib/`.

## Native Tasks & Script Execution

Run Moonstone project scripts (`moon run <script>`) or arbitrary commands (`moon exec <cmd>`) with content-addressed input caching and output verification:

```lua
local project = moonstone.project({ root = "." })

-- Run `moon run build` when src/*.moon changes, outputting dist/src/main.lua
local build = moonstone:run("build", {
  inputs = { "src/*.moon" },
  outputs = { "dist/src/main.lua" },
})

p.sink.none(build)
```

See [docs/INPUTS_AND_OUTPUTS.md](docs/INPUTS_AND_OUTPUTS.md) for detailed documentation on `inputs`, `outputs`, caching, and terminal sinks (`p.sink.none`).

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

## Source-Built Registry Package

Use `registry.source_package` when a Moonstone package should publish source and let Moonstone materialize it with a build command:

```lua
local project = moonstone.project({ root = "." })
local source_artifact = registry.source_package(project, {
  name = "user/meteorite",
  version = project.version,
  kind = "lib",
  include = { "moonstone.toml", "build.zig", "src/**", "native/**", "README.md" },
  exclude = { ".moonstone/**", ".ballad/**", "zig-cache/**", "zig-out/**", ".git/**" },
  materialize = {
    type = "command",
    command = "zig build install-native",
    collect = {
      lua_modules = {
        { name = "meteorite.lua", path = "src/app.lua" },
      },
      lua_cmodules = {
        { name = "meteorite_native.so", path = ".moonstone/env/lib/lua/${lua_abi}/meteorite_native.so" },
      },
    },
  },
})

p.sink.artifact(source_artifact, { out = "dist/registry/meteorite" })
```

The source archive is emitted as `name-version-source.tar.zst`; `zstd` must be available in `PATH`.
