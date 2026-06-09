#!/usr/bin/env python3
import argparse
import gzip
import hashlib
import io
import os
import shutil
import subprocess
import tarfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def b3_bytes(value: bytes) -> str:
    result = subprocess.run(
        ["b3sum", "--no-names"], input=value, check=True, capture_output=True
    )
    return "b3:" + result.stdout.decode().strip()


def b3_file(path: Path) -> str:
    result = subprocess.run(
        ["b3sum", "--no-names", str(path)], check=True, capture_output=True
    )
    return "b3:" + result.stdout.decode().strip()


def launcher() -> bytes:
    return b"""#!/usr/bin/env sh
set -eu

self=$0
while [ -L "$self" ]; do
  directory=$(CDPATH= cd -P -- "$(dirname -- "$self")" && pwd)
  target=$(readlink "$self")
  case "$target" in
    /*) self=$target ;;
    *) self=$directory/$target ;;
  esac
done

root=$(CDPATH= cd -P -- "$(dirname -- "$self")/.." && pwd)
exec lua "$root/libexec/ballad/src/main.lua" "$@"
"""


def add_bytes(archive: tarfile.TarFile, name: str, content: bytes, mode: int) -> None:
    info = tarfile.TarInfo(name)
    info.size = len(content)
    info.mode = mode
    info.mtime = 0
    info.uid = 0
    info.gid = 0
    info.uname = ""
    info.gname = ""
    archive.addfile(info, io.BytesIO(content))


def build_archive(path: Path) -> None:
    payloads = [("bin/ballad", launcher(), 0o755)]
    for source in sorted((ROOT / "src").rglob("*.lua")):
        relative = source.relative_to(ROOT).as_posix()
        payloads.append((f"libexec/ballad/{relative}", source.read_bytes(), 0o644))

    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w") as archive:
        for name, content, mode in payloads:
            add_bytes(archive, name, content, mode)

    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("wb") as output:
        with gzip.GzipFile(
            filename="", mode="wb", fileobj=output, compresslevel=9, mtime=0
        ) as compressed:
            compressed.write(buffer.getvalue())


def descriptor(
    package_name: str, version: str, blob_hash: str, blob_bytes: int, recipe_hash: str
) -> str:
    digest = blob_hash.removeprefix("b3:")
    url = f"blobs/b3/{digest[:2]}/{digest[2:4]}/{digest}.tar.gz"
    return f'''[package]
name = "{package_name}"
version = "{version}"
kind = "bin"
description = "Export Moonstone-managed Lua projects into portable runtime layouts"

[[dependencies]]
role = "lib"
resolver = "rocks"
name = "dkjson"
constraint = "^2.9-1"

[[artifacts]]
id = "bin-any"
kind = "bin"
target = "any"
lua_abi = "any"
format = "tar.gz"
url = "{url}"
hash = "{blob_hash}"
recipe_hash = "{recipe_hash}"
bytes = {blob_bytes}

[artifacts.materialize]
type = "archive"
strip_components = 0

[[artifacts.provides]]
kind = "bin"
name = "ballad"
path = "bin/ballad"
'''


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Build an upload-ready Moonstone registry artifact for Ballad."
    )
    parser.add_argument(
        "--package-name",
        default=os.environ.get("BALLAD_PACKAGE_NAME", "@moonstone/ballad"),
    )
    parser.add_argument("--version", default="0.1.2")
    parser.add_argument("--output-dir", default="dist/registry")
    args = parser.parse_args()

    output = ROOT / args.output_dir / f"ballad-{args.version}"
    if output.exists():
        shutil.rmtree(output)
    output.mkdir(parents=True)

    blob = output / f"ballad-{args.version}-any.tar.gz"
    build_archive(blob)
    blob_hash = b3_file(blob)
    blob_bytes = blob.stat().st_size
    recipe = b3_bytes(
        (
            "schema=moonstone.recipe.v0\n"
            "kind=prebuilt-artifact\n"
            f"name={args.package_name}\n"
            f"version={args.version}\n"
            "materializer=archive\n"
            "target=any\n"
            "provides=bin:ballad:bin/ballad\n"
        ).encode()
    )

    package_toml = output / "package.toml"
    package_toml.write_text(
        descriptor(args.package_name, args.version, blob_hash, blob_bytes, recipe)
    )
    (output / "SHA256SUMS").write_text(
        f"{hashlib.sha256(blob.read_bytes()).hexdigest()}  {blob.name}\n"
    )
    (output / "publish.sh").write_text(f"""#!/usr/bin/env sh
set -eu
: "${{MOONSTONE_TOKEN:?Set MOONSTONE_TOKEN to a write:registry API token}}"
curl --fail-with-body \\
  -H "Authorization: Bearer $MOONSTONE_TOKEN" \\
  -F descriptor=@"$(dirname "$0")/package.toml" \\
  -F blob=@"$(dirname "$0")/{blob.name}" \\
  "${{MOONSTONE_PUBLISH_URL:-https://moonstone.sh/api/registry/v0/publish}}"
""")
    (output / "publish.sh").chmod(0o755)

    print(f"Built {package_toml.relative_to(ROOT)}")
    print(f"Blob: {blob.relative_to(ROOT)}")
    print(f"Hash: {blob_hash}")
    print(f"Bytes: {blob_bytes}")
    print(f"Package: {args.package_name}@{args.version}")


if __name__ == "__main__":
    main()
