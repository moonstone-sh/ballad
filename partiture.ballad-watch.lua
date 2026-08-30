local ballad = require("ballad")

return ballad.partiture(function(p)
  local moonstone = p:use(ballad.plugins.moonstone)

  local executable = p:native_task({
    id = "build-ballad-watch-windows",
    tool = "zig",
    args = { "build", "-Dtarget=x86_64-windows-gnu", "-Doptimize=ReleaseSafe" },
    cwd = "native/ballad-watch",
    inputs = { "native/ballad-watch/build.zig", "native/ballad-watch/src/**" },
    outputs = { "native/ballad-watch/zig-out/bin/ballad-watch.exe" },
    cacheable = true,
    parallel_safe = false,
    description = "cross-build ballad-watch for x86_64-windows-gnu",
  })

  local artifact = moonstone.registry.helper({
    name = "moonstone/ballad-watch",
    version = "0.3.5",
    target = "x86_64-windows-gnu",
    executable = "ballad-watch",
    source_path = "native/ballad-watch/zig-out/bin/ballad-watch.exe",
    description = "Windows watcher helper for Ballad",
  })

  p.sink.artifact(artifact, { out = "dist/registry/ballad-watch" })
end)
