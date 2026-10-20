# Lua flavors

Moonstone lets a package ship one file per Lua flavor for the same module:
`lexer@lua54.lua`, `lexer@luajit.lua`, `fs@lua51@windows.lua`, usually beside
an untagged `lexer.lua` fallback. `moon sync` projects the matching file as
`lexer.lua` in each consumer's environment. The rule is Moonstone's (spec:
Moonstone's `docs/PROJECT_ENVIRONMENT.md`, "Flavors"; Lua implementation:
`moonstone.variants`). This note covers what Ballad does with such files and
the one place Ballad itself uses them.

## Variant files in a build

- **Discovery and sinks copy them verbatim.** `layout.*`, `conventions.tree`,
  the directory sink and `moonstone.registry.*` treat `foo@lua54.lua` as an
  ordinary file. Selection is the consumer's `moon sync`, not Ballad's.
- **Module names drop the tags.** `ballad.path.module_name`, the dependency
  scanner behind the `nvim` plugin (`deps.build_internal_modules`), and the
  export filters of `layout` and `love` map `pkg/fs@lua54.lua` to module
  `pkg.fs`. Without this, a package that ships only variants of a module
  would see its own `require("pkg.fs")` reported as an unknown dependency.
- **`ballad.flavor`** (also `require("ballad").flavor`) exposes the pieces a
  plugin needs:
  - `parse(file_name)`: variant parts, nil for an ordinary file, false for a
    malformed one (`lexer@linux@lua54.lua`).
  - `module_file(path)`: `src/foo@lua54.lua` becomes `src/foo.lua`.
  - `parse_id(id)`: `"luajit-x86_64-linux"` becomes `{ family, level, os, arch }`.
  - `target()`: the flavor being built for, from `MOONSTONE_TARGET`, then the
    environment's `moonstone.target`, else nil.

  It defers to `moonstone.variants` when the environment provides it and
  otherwise uses a built-in copy of the same rule, so it works with Moonstone
  releases that predate flavors and outside Moonstone.

The watcher's glob validation (`^[%w%._%-%*/%?]+$`) rejects `@`, so a watch
cannot name a variant explicitly (`src/**/*@lua54.lua`). `src/**/*.lua` still
matches variant files, which is what a watch normally wants.

## Ballad's own variants

`src/ballad/crc32.lua` (the zip writer's checksum) selects its implementation by Lua flavor: LuaJIT has the `bit` library,
Lua 5.3+ has integer operators that older parsers cannot read, and PUC 5.1 has
neither. It ships as:

| file | used on |
|---|---|
| `crc32.lua` | fallback: picks `bit`, `bit32`, native operators (compiled from a string) or arithmetic at load time; runs everywhere |
| `crc32@luajit.lua` | LuaJIT: `bit` directly |
| `crc32@lua54.lua` | Lua 5.4: native operators directly |

All three return the same unsigned value, and the archive bytes are identical
to the previous `bit`-only writer (`tests/test_flavors.sh` checks the
checksums on every Lua on `PATH`). The rest of `archive.lua` is plain
arithmetic. As a result `love` packing also works when Ballad runs on PUC Lua
5.4 or 5.5, not only on LuaJIT.

Ballad installs Moonstone's source searcher before loading platform modules,
so checkouts and libexec tools select the host implementation too. Tagged
sources ship in the package; Moonstone 0.7 or later is required for the
Windows artifact request and current command contracts.

Host OS behavior uses `platform.lua` and `platform@windows.lua`. This is
independent of a release target: a macOS host exporting a Windows release
still runs macOS subprocesses. The tool runtime is Lua 5.4 on every host.
See [Windows support](WINDOWS.md) for the tested boundary.

## Requests for plugins that specialize per flavor (Quaver)

Ballad runs plugins in its own process, and native actions inherit its
environment, so `MOONSTONE_TARGET` already reaches both. Quaver's Ballad
adapter reads `MOONSTONE_TARGET` itself and selects files with the canonical
`moonstone.variants.parse`/`select` (see Quaver's
`docs/MOONSTONE_FLAVORS.md`, "Quaver implementation status"). That is the
right split. Ballad does not select variants, and `ballad.flavor` is not a
second selection rule. Its `parse` defers to `moonstone.variants` when present.
Ballad includes `ballad.cache.build_context()` in every pipeline-node and
native-task cache key. It records the resolved target separately from the host
and its runtime. Plugins no longer need to repeat the target in options just
to make caching correct. Other environment-dependent inputs still belong in
explicit options or native-task `env` declarations. An invalid explicit
`MOONSTONE_TARGET` is an error, rather than an unknown-target cache entry.

Export reports record the same context. Orbit exports use sequential structured
Moonstone sync and exec tasks on each host; synchronization failures stop the
export. A shared report is invalidated when its target changes, so returning
to a previous target cannot reuse the other target's materialized files.

Choose export recipes using `ballad.flavor.target()`. Keep host commands in
host flavor modules: a Windows target exported on macOS still runs macOS tools.
Tagged Lua files remain source variants selected by Moonstone, not a declaration
that a native binary has been cross-compiled.

Inventory note for Quaver: Ballad sinks and source sets pass `foo@lua54.lua`
through under its tagged path. Module names derived by Ballad drop the tags.
