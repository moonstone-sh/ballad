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
moon exec ballad play partiture.lua
moon exec ballad ./release.partiture.lua
```

## Partiture API

Plugins provide transforms only. Use `p.sink.*` for terminal outputs; every partiture must declare at least one explicit sink.

```lua
  local ballad = require("ballad")

return ballad.partiture(function(p)
  local moonstone = p:use(ballad.plugins.moonstone)
  local layout = p:use(ballad.plugins.layout)

  local project = moonstone.project({ root = "." })
  local app = layout.libexec(project, {
    name = "ballad",
    entry = "src/main.lua",
    bin = "ballad",
    interpreter = "luajit",
  })

  local artifact = moonstone.registry.package(app, {
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

## Executable Tool Export

`moonstone.tool` introduces a synchronized Moonstone executable scope as graph
assets. It works for native Moonstone packages and `rocks:` tools alike, and
preserves the tool executable, Lua modules, native modules, and dependent
executables selected by Moonstone.

```lua
local project = moonstone.project({ root = "." })
local tool = moonstone.tool(project, { name = "cyan" })
local export = layout.exec(tool, { name = "cyan" })

p.sink.directory(export, { out = "dist/cyan", file_graph = true })
```

Run `moon sync` before evaluating the partiture. Moonstone owns resolution and
ABI selection; Ballad consumes the resulting private tool scope as sources for
the exported executable.

## Orbit Exports

Moonstone orbits stay independent projects. The root partiture explicitly maps
an orbit to a child partiture; Ballad never infers that every orbit should be
exported or published.

```lua
local ballad = require("ballad")

return ballad.partiture(function(p)
  local moonstone = p:use(ballad.plugins.moonstone)

  local service = moonstone.orbit({
    name = "basic-service",
    partiture = "partiture.lua",
    sync = "locked",
    inputs = {
      "moonstone.toml",
      "moonstone.lock",
      "partiture.lua",
      "src/**",
    },
  })

  p.sink.directory(service, { out = "dist/examples/basic-service", file_graph = true })
end)
```

`moonstone.orbit` resolves the member through Moonstone, synchronizes it when
requested, and executes `ballad play` through `moon orbit exec`. That preserves
the child working directory, interpreter, tool closure, and native-module ABI
scope. The child partiture owns its explicit sinks; Ballad writes a temporary
report and imports every materialized child sink into the parent graph with
orbit provenance.

When a source-tree recipe needs an additional **pure-Lua** plugin, declare its
parent-contained root explicitly with `lua_paths` and include that source in
the node inputs. Ballad passes those roots to the child `ballad play` process;
it does not merge sibling tool scopes or native modules across interpreter
boundaries.

Use `sync = "locked"` for reproducible exports. It requires the child lockfile
to be current. `sync = "update"` is for intentionally lockless examples and
development projects; it refreshes the child environment and is non-cacheable
by default. `sync = "never"` requires a previously synchronized child.

Orbit imports never create a registry package on their own. A child partiture
may publish an artifact explicitly, or the parent may explicitly package the
imported assets. This keeps project closure and release policy separate.

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

When a layout consumes files generated by a build task, declare that dependency
and select only the runtime closure explicitly:

```lua
local app = layout.libexec(project, {
  entry = "build/src/main.lua",
  include = { "build/src/**" },
  lua_paths = { "lua", "build/src" },
  packages = { "argparse" },
  depends_on = build,
})
```

`depends_on` makes Ballad wait for the generated outputs before reading them.
`include` selects project files, `lua_paths` configures the launcher's module
roots, and `packages` restricts projected Lua/C modules to the named runtime
package closure.

See [docs/INPUTS_AND_OUTPUTS.md](docs/INPUTS_AND_OUTPUTS.md) for detailed documentation on `inputs`, `outputs`, caching, and terminal sinks (`p.sink.none`).

## Development Watchers

`ballad.plugins.watcher` is an opt-in, portable polling supervisor for
partitures that need a long-running development loop. It owns the file
snapshot, debounce, ordered reaction execution, and a POSIX shell trap that
invokes the configured cleanup action on `INT`, `TERM`, or `HUP`.

```lua
local watcher = p:use(ballad.plugins.watcher)

local application = p.source.files({ "**/*.lua" }, { root = "src" })
local assets = p.source.directory("assets")
local build_config = p.source.files({ "build.zig" }, { root = "." })
local session = watcher.watch({
  initial = {
    label = "bootstrap",
    outputs = { "dist/server" },
    effect = "scripts/guard.sh handoff && moon run build",
  },
  reactions = {
    {
      label = "application",
      watch = { application, assets, build_config },
      outputs = { "dist/server" },
      effect = "moon run build",
    },
  },
  options = {
    cleanup = "scripts/guard.sh cleanup || true",
    interval = 0.5,
    debounce = 0.15,
  },
})

p.sink.none(session)
```

`initial` runs once when the watcher begins. Each reaction is declared in order.
`watch` accepts source node handles and defines both the source surface and the
watcher node's graph inputs. Ballad derives polling patterns from those source
nodes, so the graph and daemon subscribe to the same closure. `outputs` records
the refreshed surface in session metadata. `effect` is a shell command,
intentionally declarative so a watcher session can be planned, logged, and
supervised deterministically. Reactions run only after their debounced snapshot
changes. Use top-level `depends_on` only for genuine task ordering; it does not
mean “rerun when this source changes.”
Use `options = { once = true }` for an inspectable, non-daemon refresh in CI or
smoke tests.

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

The release process is maintained with Moonstone's repository release tooling;
see that repository's release documentation for the current packaging command.

## Source-Built Registry Package

Use `moonstone.registry.source_package` when a Moonstone package should publish source and let Moonstone materialize it with a build command:

```lua
local project = moonstone.project({ root = "." })
local source_artifact = moonstone.registry.source_package(project, {
  name = "user/meteorite",
  version = project.version,
  kind = "lib",
  include = {
    "moonstone.toml",
    "build.zig",
    "src/**",
    "native/**",
    "README.md",
    "REGISTRY_README.md",
  },
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

### Repository and Registry READMEs

Keep `README.md` for people visiting the source repository: architecture,
contributor workflow, benchmarks, and development notes. Add
`REGISTRY_README.md` for the install-and-use guide shown to package consumers.

For every registry package shape, Ballad resolves README content in this order:

1. `readme_content` passed to the package call.
2. An explicit `readme = "..."` path passed to the package call.
3. A `readme` path declared in `[package]` in `moonstone.toml`.
4. `REGISTRY_README.md` at the project root.
5. `README.md` at the project root.

The generated descriptor records `readme = "README.md"` as a compact sidecar
pointer. Ballad writes the selected Markdown into that sidecar and uploads it
separately through the registry protocol, so a package descriptor never embeds
a large user-facing document.

The source archive is emitted as `name-version-source.tar.zst`; `zstd` must be available in `PATH`.
