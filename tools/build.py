"""Build standalone distribution files from the ModuleScript dependency graph."""
from pathlib import Path
import argparse
import re

ROOT = Path(__file__).resolve().parents[1]
IMPORT = re.compile(r"require\((script(?:\.[A-Za-z_][A-Za-z_0-9]*)+)\)")
HEADER = "-- Generated distribution file.\n-- Edit the source modules, not this file.\n"


def resolve(owner: Path, expression: str) -> Path:
    node = owner.parent if owner.name == "init.luau" else owner.with_suffix("")
    for part in expression.split(".")[1:]:
        node = node.parent if part == "Parent" else node / part
    candidate = node.with_suffix(".luau")
    if not candidate.is_file():
        candidate = node / "init.luau"
    if not candidate.is_file() or not candidate.is_relative_to(ROOT / "src"):
        raise ValueError(f"Unresolved import in {owner}: {expression}")
    return candidate


def bundle(entry: str) -> str:
    emitted = {}
    visiting = set()
    chunks = [HEADER]

    def visit(path: Path) -> str:
        if path in visiting:
            raise ValueError(f"Circular module dependency: {path}")
        if path in emitted:
            return emitted[path]
        visiting.add(path)
        source = path.read_text(encoding="utf-8")
        source = IMPORT.sub(lambda match: visit(resolve(path, match[1])), source)
        if re.search(r"\brequire\s*\(", source):
            raise ValueError(f"Unsupported require in {path}")
        name = "Module" + str(len(emitted) + 1)
        emitted[path] = name
        visiting.remove(path)
        chunks.append(f"local {name} = (function()\n{source.rstrip()}\nend)()\n")
        return name

    result = visit(ROOT / entry)
    chunks.append(f"return {result}\n")
    return "\n".join(chunks)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Fail if committed bundles have drifted")
    args = parser.parse_args()
    stale = []
    for output, entry in {
        "Library.lua": "src/Client.luau",
        "addons/ThemeManager.lua": "src/addons/ThemeManager.luau",
        "addons/SaveManager.lua": "src/addons/SaveManager.luau",
    }.items():
        target = ROOT / output
        content = bundle(entry).encode("utf-8")
        if args.check:
            if not target.exists() or target.read_bytes() != content:
                stale.append(output)
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(content)
    if stale:
        raise SystemExit("Stale bundles: " + ", ".join(stale) + ". Run python tools/build.py.")
    print("Distribution bundles match source." if args.check else "Built Library.lua and addons.")


if __name__ == "__main__":
    main()
