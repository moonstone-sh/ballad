"""Public-command target switching, child exports, and cache reuse on each host."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[1]
moon = os.environ.get('MOONSTONE_BIN') or os.environ.get('MOONSTONE_CLI') or shutil.which('moon')
assert moon
with tempfile.TemporaryDirectory(prefix='ballad flavors ') as temporary:
    root = Path(temporary).resolve()
    child = root/'child'
    tools = root/'forbidden shell'
    tools.mkdir()
    (tools/'sh').write_text('#!/bin/sh\nexit 99\n')
    (tools/'sh').chmod(0o755)
    (tools/'sh.cmd').write_text('@exit /b 99\n')
    def run(project, *args, target=None, failure=False):
        env = dict(os.environ)
        if target:
            env['MOONSTONE_TARGET'] = target
            env['PATH'] = str(tools)+os.pathsep+env['PATH']
        result = subprocess.run([moon, '-C', str(project), *args], env=env, capture_output=True, text=True, timeout=180)
        assert (result.returncode != 0) == failure, (args, result.stdout, result.stderr)
        return result.stdout + result.stderr
    for project in (root, child):
        run(root, 'init', str(project), '--name', 'flavor-fixture', '--interpreter', 'lua@5.4', '--no-sync', '--no-git')
        run(project, 'add', 'path:'+repo.as_posix(), '--tool', '--no-sync')
    run(root, 'orbit', 'add', '--name', 'child', '--path', 'child')
    (child/'partiture.lua').write_text('''local ballad = require("ballad")
local graph = require("ballad.graph")
return ballad.partiture(function(p)
  local fixture = p:use({ name="fixture.flavor", version="1", methods={
    generate={inputs={},outputs={"asset_set"},role="source",cacheable=true},
  }, generate=function(ctx)
    local target=assert(ballad.flavor.target()).id
    local file=assert(io.open("executions.log","a")); file:write(target,"\\n"); file:close()
    local assets=graph.AssetSet.new()
    assets:add(ctx.graph:add_asset({kind="generated",virtual_path="flavor.txt",content=target}))
    return assets
  end })
  p.sink.directory(fixture.generate(),{out="dist",product="release"})
end)
''')
    (root/'parent.lua').write_text('''local ballad=require("ballad")
return ballad.partiture(function(p)
  local moonstone=p:use(ballad.plugins.moonstone)
  local child=moonstone.orbit("child"):partiture("partiture.lua"):run({sync="locked"}):product("release")
  p.sink.directory(child,{out="release"})
end)
''')
    run(root, 'sync')
    run(child, 'sync')
    a, b = 'lua54-x86_64-windows', 'lua54-x86_64-linux'
    for target in (a, a, b, b, a):
        run(root, 'exec', '--', 'ballad', 'play', 'parent.lua', target=target)
        assert (root/'release/orbits/child/dist/flavor.txt').read_text() == target
    assert (child/'executions.log').read_text().splitlines() == [a,b], 'node cache did not reuse stable target work'
    invalid = run(root, 'exec', '--', 'ballad', 'play', 'parent.lua', target='lua54-bogus-linux', failure=True)
    assert 'invalid MOONSTONE_TARGET' in invalid
    before = (child/'executions.log').read_text()
    with (child/'moonstone.toml').open('a') as manifest:
        manifest.write('\n[[dependencies]]\nname = "fixture/unsynchronized"\nconstraint = "^99.0.0"\n')
    run(root, 'exec', '--', 'ballad', 'play', 'parent.lua', target=a, failure=True)
    assert (child/'executions.log').read_text() == before, 'failed sync ran the child export'
print('PASS: native orbit exports and A/A/B/B/A target cache isolation and reuse')
