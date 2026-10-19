# Windows host contract

Ballad uses Lua 5.4 as its tool runtime. An exported application's runtime is
independent: a partiture can still select LuaJIT or another runtime available
for its target. Running Ballad does not require a Windows LuaJIT artifact.

Moonstone selects `ballad.platform@windows.lua` during dependency projection.
Source checkouts install `moonstone.variants` before loading host modules.
ZIP checksums reuse the Lua 5.4 and LuaJIT variants from `ballad.crc32`;
the untagged implementation remains parseable on Lua 5.1.

The native Windows x64 workflow exercises real dependency installation,
structured tasks and their captured exit status, directory operations,
replacement of existing files, self-export, and a relocated `.cmd` launcher.
The separate watcher workflow builds and runs `ballad-watch.exe`. Orbit exports
use structured Moonstone sync/exec tasks. Directory containment uses physical
Windows paths, including junction resolution. The native orbit test switches
between Windows and Linux target flavors and verifies cache isolation/reuse.

Use structured native tasks with `tool`, `args`, `cwd` and `env`. The current
synchronous cmd boundary rejects expansion characters and ambiguous quoting
with a diagnostic. It does not promise arbitrary shell syntax is portable.
Parallel native tasks remain sequential on Windows. Plugins that invoke
external programs still need a working Windows version of each program.

`registry.package` and `registry.source_package` create canonical `.tar.gz`
artifacts through Moonstone. `registry.runtime` and the generated `publish.sh`
remain POSIX tooling. Publish a prepared descriptor/artifact with Moonstone's
registry CLI on Windows rather than attempting to execute that shell script.

Certification covers the declared x64 scenarios. Fancy terminal hosts, native
C-module toolchains, Windows ARM64 and complete non-ASCII filesystem behavior
need their own tests. The Lua distribution's CRT argument/environment encoding
is a runtime concern; UTF-8 Lua strings alone do not certify those boundaries.

These changes require the companion Moonstone source-materialization and
canonical-archive fixes. Package releases must publish the portable Ballad
runtime metadata before dependent tools switch their Windows install path.
