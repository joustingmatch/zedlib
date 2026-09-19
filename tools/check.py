"""Run regression suites and exercise the consumer distribution files."""
from pathlib import Path
import subprocess
import sys
import build

ROOT = Path(__file__).resolve().parents[1]


def run(*args):
    subprocess.run(args, cwd=ROOT, check=True)


def distribution_test():
    content = (ROOT / "tests/JsonMock.luau").read_text(encoding="utf-8")
    content += (ROOT / "tests/UIMock.luau").read_text(encoding="utf-8")
    content += '\nlocal loaders = {}\n'
    for path in ["Library.lua", "addons/ThemeManager.lua", "addons/SaveManager.lua"]:
        source = (ROOT / path).read_text(encoding="utf-8")
        assert "require(script" not in source, path
        content += f'loaders["{path}"] = function()\n{source}\nend\n'
    content += '''
local requests = {}
function game:HttpGet(url)
    local base = "https://raw.githubusercontent.com/joustingmatch/zedlib/main/"
    assert(string.sub(url, 1, #base) == base, "Unexpected raw base URL")
    local path = string.sub(url, #base + 1)
    assert(loaders[path], "Unknown distribution path")
    table.insert(requests, path)
    return path
end
local function loadstring(path) return loaders[path] end
local function example()
'''
    content += (ROOT / "Example.lua").read_text(encoding="utf-8") + "\nend\n"
    content += (ROOT / "tests/Distribution.spec.luau").read_text(encoding="utf-8")
    output = ROOT / "tests/.distribution.luau"
    output.write_text(content, encoding="utf-8", newline="\n")
    run("luau", str(output))
    # Dependency and determinism checks apply to production outputs, not test bundles.
    for entry in ["src/Client.luau", "src/addons/ThemeManager.luau", "src/addons/SaveManager.luau"]:
        assert build.bundle(entry) == build.bundle(entry), entry
    core = build.bundle("src/Client.luau")
    assert "local ThemeManager =" not in core and "local SaveManager =" not in core
    assert "local ThemeManager =" not in build.bundle("src/addons/SaveManager.luau")


def package_test():
    """Execute unmodified ModuleScript sources using the package's actual tree."""
    content = (ROOT / "tests/JsonMock.luau").read_text(encoding="utf-8")
    content += (ROOT / "tests/UIMock.luau").read_text(encoding="utf-8")
    content += '\nlocal nodes = { [""] = {} }\nlocal require\n'
    files = [ROOT / "init.luau", ROOT / "Library.d.luau", *sorted((ROOT / "src").rglob("*.luau"))]
    modules = {}
    paths = {""}
    for file in files:
        relative = file.relative_to(ROOT)
        key = relative.parent.as_posix() if file.name == "init.luau" else relative.with_suffix("").as_posix()
        key = "" if key == "." else key
        modules[key] = file
        parts = key.split("/")
        paths.update("/".join(parts[:i]) for i in range(1, len(parts) + 1))
    for key in sorted(paths - {""}, key=lambda key: (key.count("/"), key)):
        parent, _, name = key.rpartition("/")
        content += f'nodes["{key}"] = {{ Parent = nodes["{parent}"] }}\nnodes["{parent}"]["{name}"] = nodes["{key}"]\n'
    content += '''
local cache = {}
require = function(node)
    assert(node and node.Load, "Missing package module")
    if cache[node] == nil then cache[node] = node.Load(node) end
    return cache[node]
end
'''
    for key, file in modules.items():
        content += f'nodes["{key}"].Load = function(script)\n{file.read_text(encoding="utf-8")}\nend\n'
    content += '''
local package = require(nodes[""])
assert(package.Types and package.ThemeManager and package.SaveManager)
local library = package.Library.new({ OwnershipKey = "package-check" }):Initialize():Mount()
local window = library:CreateWindow({ Title = "Package", Tabs = {} })
local settings = window:AddTab({ Name = "Settings" })
package.ThemeManager:SetLibrary(library)
package.SaveManager:SetLibrary(library)
package.SaveManager:IgnoreThemeSettings()
package.ThemeManager:ApplyToTab(settings)
package.SaveManager:BuildConfigSection(settings)
assert(settings:GetSubTab("Theme") and settings:GetSubTab("Config"))
assert(#library:Validate() == 0)
library:Unload()
assert(library.Unloaded)
print("PASS package entry point, source modules, types, and managers")
'''
    output = ROOT / "tests/.package.luau"
    output.write_text(content, encoding="utf-8", newline="\n")
    run("luau", str(output))


if __name__ == "__main__":
    run(sys.executable, "tools/build.py", "--check")
    for flag, filename in [
        ("test", "generated"), ("ui", "ui"), ("theme", "theme"),
        ("managers", "managers"), ("stress", "stress"), ("examples", "examples"),
    ]:
        run(sys.executable, "tools/test_bundle.py", "--" + flag)
        run("luau", f"tests/.{filename}.luau")
    distribution_test()
    package_test()
    print("All checks passed.")
