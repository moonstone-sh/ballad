# Ballad

> Documentation map: [`docs/README.md`](docs/README.md) · contributor guidance:
> [`AGENTS.md`](AGENTS.md)

Ballad exports Moonstone-managed Lua projects through a deterministic pipeline. A partiture declares explicit sources, plugin transforms, and sinks; Ballad core owns planning, execution, file materialization, file graphs, and artifacts.

## Usage

Ballad runs partitures. With no command, it defaults to `partiture.lua`:

```sh
moon sync
moon exec ballad --
```

You can also pass a partiture explicitly:

```sh
moon exec ballad -- play partiture.lua
moon exec ballad -- ./release.partiture.lua
```

### Initialize by convention

Generate a partiture and register a `package` script in `moonstone.toml` through
Moonstone's CLI:

```sh
moon exec ballad -- init --template executable
moon run package
```

Available templates are `executable`, `love2d`, and `registry`. Use
`--no-script` when only the file should be generated, `--script-name <name>` to
choose another entrypoint, and `--force-script` to replace a conflicting script.
Ballad reports the existing and requested commands when a conflict occurs; it
does not silently replace project intent.

The `registry` template uses source-tree conventions instead of enumerating
every provision:

```lua
local convention = ballad.conventions
local artifact = moonstone.registry.source_package(project, {
  collect = {
    lua_modules = {
      convention.tree("src", {
        prefix = "my_package",
        strip_prefix = "my_package/",
        root_module = "my_package.lua",
      }),
    },
    bins = {
      convention.file("bin/my-tool", "bin/my-tool"),
    },
  },
})
```

`source_package` infers the package name, version, kind, description, standard
source patterns, exclusions, and command materializer from the prepared
Moonstone project. Trees expand deterministically and reject missing roots,
empty selections, and duplicate provision names with collection-specific
diagnostics. `include`, `exclude`, `overrides`, and explicit `file` entries keep
exceptions visible without turning the partiture into a generated file list.

Native builds can declare host paths without embedding machine-specific values:

```lua
materialize = {
  command = "make",
  external_paths = {
    convention.external.include("sqlite"), -- SQLITE_INCDIR
    convention.external.library("sqlite"), -- SQLITE_LIBDIR
  },
}
```

Moonstone resolves those requirements in the target materialization environment
and reports the dependency, expected variable, and discovery attempts if it
cannot satisfy one.

### Deterministic controls

Ballad deliberately leaves argument parsing to normal Lua. Parse
`p.invocation.args` directly or use any Lua CLI library, then promote only the
values that affect the graph into named controls:

```lua
local mode = p.control.value("mode", parsed.mode, { source = "invocation" })
local release = mode:eq("release", { name = "release-selected" })

p.control.require("explicit-mode", mode:present(), {
  code = "missing_mode",
  subject = "--mode",
  message = "A build mode is required",
  expected = "--mode <mode>",
  actual = parsed.mode,
  hint = "Pass the option after the partiture argument delimiter.",
})

p.control.when(release, function()
  local artifact = make_release()
  p.sink.artifact(artifact, { out = "dist/release", product = "release" })
end)

p.control.unless(release, function()
  local layout = make_development_layout()
  p.sink.directory(layout, { out = "dist/dev", product = "development" })
end)
```

Both branches remain inspectable in `graph.json`. Only the selected branch is
reachable in the execution plan; disabled nodes cannot run effects or use task
caches. Control values, predicates, and requirements are included in graph and
export-report identity. Values must be serializable and must not contain
secrets.

`when` and `unless` are graph-construction scopes, not Lua flow-control
statements. Ballad invokes every branch callback while loading the partiture so
the complete graph remains inspectable. Keep callbacks declarative: filesystem
writes, subprocesses, network calls, and other effects belong in graph nodes.
Those nodes execute only when their branch is selected.

Control handles are immutable. `value:get()` returns a defensive copy for code
that needs to inspect a structured fact; changing that copy cannot alter the
recorded graph or cache identity. Values, explicitly named predicates, and
requirements share one name namespace. This makes reports and
`:assert_control(...)` testing lookups unambiguous.

Use `all`, `any`, and `not_` to combine predicates. Legacy `enabled = false`
remains supported, but named controls are preferred whenever a choice affects
release behavior.

### Testing partitures

`ballad.testing` is a Lua assertion library, not a test runner. The caller owns
fixtures, the current workspace, and environment isolation:

```lua
local testing = require("ballad.testing")
local subject = testing.load("partiture.lua", {
  args = { "release" },
})

subject:plan()
  :assert_control("mode", "release")
  :assert_product("release", true)
  :assert_product("development", false)

subject:execute()
  :assert_success()
  :assert_product("release")
  :assert_path("dist/release/package.toml")
```

Plans can also assert graph nodes and source-package provisions. Execution
results can assert structured diagnostic codes, which makes failure behavior
testable without parsing Lua stack traces.

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

### Windows exports

Core directory exports retain forward-slash virtual paths and deterministic file
graphs on every host. Runnable `layout.libexec`, application `layout.exec`,
tool `layout.exec`, and runnable `layout.flat` outputs include a sibling `.cmd`
launcher for PowerShell and `cmd.exe`; keep using the extensionless launcher on
POSIX. The Windows launchers prefer a bundled `bin/lua.exe` or
`bin/luajit.exe`, then `BALLAD_LUA`, then the configured interpreter.

Use structured native tasks on Windows:

```lua
p:native_task({ tool = "tool.exe", args = { "--out", "dist/result" }, cwd = "." })
```

Ballad runs those tasks with a child-local working directory and environment.
Lua 5.1/LuaJIT has no portable `CreateProcessW` binding, so values containing
`cmd.exe` metacharacters (including quotes, `%`, `&`, and `|`) are rejected
instead of allowing command interpretation; use a helper file for that
boundary. `cmd` shell strings and background native tasks are not Windows
features. Watchers use a separately provisioned native helper described below.
With `--jobs > 1`, native tasks run sequentially on Windows rather than being
backgrounded.

Ballad's CI validates Windows path and launcher serialization, not execution on
a native Windows runner.

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

  local service = moonstone.orbit("basic-service")
    :partiture("partiture.lua")
    :run({
    sync = "locked",
    inputs = {
      "moonstone.toml",
      "moonstone.lock",
      "partiture.lua",
      "src/**",
    },
  })

  p.sink.directory(service.product("release"), {
    out = "dist/examples/basic-service",
    file_graph = true,
  })
end)
```

`moonstone.orbit("name")` only addresses an immediate child. Its
`:partiture(path):run(opts)` invocation resolves the member through Moonstone,
synchronizes it when requested, and executes `ballad play` through `moon orbit exec`. That preserves
the child working directory, interpreter, tool closure, and native-module ABI
scope. The returned handle is a **product catalog**, not an asset set: select a
child-declared product before any parent sink, layout, or package can consume it.

The child names release-worthy sinks explicitly:

```lua
p.sink.directory(release, {
  out = "dist/release",
  product = "release",
})
```

Then a parent can compose only those products it deliberately ships:

```lua
local api = moonstone.orbit("api"):partiture("release.lua"):run({
  sync = "locked",
  args = { "--profile", "production" },
})
local worker = moonstone.orbit("worker"):partiture("release.lua"):run({
  sync = "locked",
  args = { "--profile", "production" },
})

local layout = p:use(ballad.plugins.layout)
local suite = layout.directory({
  { from = api.product("release"), to = "api" },
  { from = worker.product("release"), to = "worker" },
})

local package = moonstone.registry.package(suite, {
  name = "acme/platform-suite",
  version = "1.0.0",
})
p.sink.artifact(package, { out = "dist/registry/platform-suite" })
```

An unselected orbit handle is rejected. Unnamed child sinks are not export
products, and nested orbits remain child-owned: the parent receives only the
materialized products reported by its immediate child. Ballad never flattens
locks, runtimes, tools, or native module scopes across those boundaries.

Each invocation writes a child-local `.ballad/exports/<fingerprint>.json`
report. It records the invocation arguments, final graph fingerprint, observed
source closure, and named products. A later matching invocation folds that
observed closure back into its cache inputs, so source-domain changes invalidate
the child export without making its runtime or tool scope part of the parent.

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
may publish an artifact explicitly, or the parent may explicitly package a
selected composed product. This keeps project closure and release policy
separate.

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

On POSIX, Ballad generates the existing `sh` polling supervisor using `find`
and `stat`. On Windows, it writes a deterministic `ballad:watcher:v1` manifest
and resolves an already-provisioned `ballad-watch` helper through
`moon tool resolve ballad-watch --json`. Windows watcher declarations must use
`run = p.task.native({ id = ..., tool = ..., args = ... })`; raw `before`,
`effect`/`command`, and `options.cleanup` shell fields are rejected and never
sent to `cmd.exe`. The helper is not bundled with this Ballad source package.
Add a compatible Moonstone **helper** provision and run `moon sync`; see
[docs/WINDOWS_WATCHER_HELPER.md](docs/WINDOWS_WATCHER_HELPER.md) for the exact
protocol.

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
local convention = ballad.conventions
local source_artifact = moonstone.registry.source_package(project, {
  include_add = { "native/**" },
  materialize = {
    command = "zig build install-native",
    external_paths = {
      convention.external.include("sqlite"),
      convention.external.library("sqlite"),
    },
    ldflags = { "-L$(SQLITE_LIBDIR)" },
  },
  collect = {
    lua_modules = {
      convention.tree("src", {
        prefix = "meteorite",
        overrides = { ["app.lua"] = "meteorite.lua" },
      }),
    },
    lua_cmodules = {
      convention.file("meteorite_native.so", ".moonstone/env/lib/lua/${lua_abi}/meteorite_native.so"),
    },
  },
})

p.sink.artifact(source_artifact, { out = "dist/registry/meteorite" })
```

When the build genuinely depends on host-provided development files, declare
that boundary in the materialization contract. Do not rely on an undocumented
environment variable inside the build command:

```lua
materialize = {
  command = "make",
  external_paths = {
    convention.external.include("sqlite"),
    convention.external.library("sqlite"),
  },
  ldflags = { "-L$(SQLITE_LIBDIR)" },
  -- input/output declarations omitted
}
```

Ballad validates and canonicalizes these requirements and includes the complete
materialization contract in the source-package recipe hash. Moonstone resolves
the variables only when the final build environment exists. Prefer ordinary
Moonstone build dependencies when they can provide the required files.

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

Registry `package` artifacts and source packages default to `tar.gz`. Ballad selects
and stages the closure, entry names, and portable `0644`/`0755` modes, then calls
Moonstone's versioned `moon artifact create --json` contract for canonical archive
bytes, digest, and size. This route does not require host `tar`, `zstd`, or
`b3sum`, including on Windows. Set `moon = "/path/to/moon"` when the CLI is not
on `PATH`; an older or missing CLI produces a diagnostic naming required contract
`moonstone:artifact-create:v1`.

`format = "tar.zst"` remains a POSIX-only legacy source-package route for
existing consumers. It requires `tar`, `zstd`, and `b3sum`; Moonstone's first
artifact-create milestone does not produce tar.zst, so Ballad rejects that format
on Windows with an explicit diagnostic. Ballad still only emits a `publish.sh`
helper and descriptor; registry publication remains outside this export step.
