"""Bundle local modules into a network-free loadstring-compatible Luau chunk."""
from pathlib import Path
import argparse

ROOT = Path(__file__).resolve().parents[1]
# Order is evaluation order: ColorUtils and Theme come first because Types
# re-exports Theme's type definitions rather than restating them.
CORE_MODULES = [
    ("ColorUtilsModule", "src/core/ColorUtils.luau"),
    ("ThemeModule", "src/core/Theme.luau"),
    ("TypesModule", "src/Types.luau"),
    ("ResourcesModule", "src/core/ResourceTracker.luau"),
    ("PersistenceModule", "src/core/Persistence.luau"),
    ("ThemeDataModule", "src/core/ThemeData.luau"),
    ("RuntimeModule", "src/core/Runtime.luau"),
    ("LibraryModule", "src/Library.luau"),
]
UI_MODULES = [
    ("MetricsModule", "src/ui/Metrics.luau"),
    ("TokensModule", "src/ui/Tokens.luau"),
    ("TypographyModule", "src/ui/Typography.luau"),
    ("MaterialsModule", "src/ui/Materials.luau"),
    ("PopupModule", "src/ui/Popup.luau"),
    ("ControlsModule", "src/ui/Controls.luau"),
    ("ElementModule", "src/ui/Element.luau"),
    ("LabelModule", "src/ui/Label.luau"),
    ("DividerModule", "src/ui/Divider.luau"),
    ("ButtonModule", "src/ui/Button.luau"),
    ("DropdownModule", "src/ui/Dropdown.luau"),
    ("InputModule", "src/ui/Input.luau"),
    ("ValueControlModule", "src/ui/ValueControl.luau"),
    ("ToggleModule", "src/ui/Toggle.luau"),
    ("SliderModule", "src/ui/Slider.luau"),
    ("ContextMenuModule", "src/ui/ContextMenu.luau"),
    ("KeyPickerModule", "src/ui/KeyPicker.luau"),
    ("ColorPickerModule", "src/ui/ColorPicker.luau"),
    ("ContainerModule", "src/ui/Container.luau"),
    ("UXModule", "src/ui/UX.luau"),
    ("GroupboxModule", "src/ui/Groupbox.luau"),
    ("ShellModule", "src/ui/Shell.luau"),
]
IMPORTS = {
    "require(script.Parent.Parent.core.ThemeData)": "ThemeDataModule",
    "require(script.Parent.ValueControl)": "ValueControlModule",
    "require(script.Parent.Toggle)": "ToggleModule",
    "require(script.Parent.Slider)": "SliderModule",
    "require(script.Parent.ContextMenu)": "ContextMenuModule",
    "require(script.Parent.KeyPicker)": "KeyPickerModule",
    "require(script.Parent.ColorPicker)": "ColorPickerModule",
    "require(script.Parent.Container)": "ContainerModule",
    "require(script.Parent.UX)": "UXModule",

    "require(script.Parent.Parent.Types)": "TypesModule",
    "require(script.Parent.Types)": "TypesModule",
    "require(script.Parent.core.ResourceTracker)": "ResourcesModule",
    "require(script.Parent.core.Runtime)": "RuntimeModule",
    "require(script.Parent.Persistence)": "PersistenceModule",
    "require(script.Parent.core.Persistence)": "PersistenceModule",
    "require(script.Parent.Parent.core.Persistence)": "PersistenceModule",
    "require(script.Parent.core.ColorUtils)": "ColorUtilsModule",
    "require(script.Parent.core.Theme)": "ThemeModule",
    "require(script.Parent.Parent.core.Theme)": "ThemeModule",
    "require(script.Parent.ColorUtils)": "ColorUtilsModule",
    "require(script.Parent.Metrics)": "MetricsModule",
    "require(script.Parent.Tokens)": "TokensModule",
    "require(script.Parent.Typography)": "TypographyModule",
    "require(script.Parent.Materials)": "MaterialsModule",
    "require(script.Parent.Popup)": "PopupModule",
    "require(script.Parent.Controls)": "ControlsModule",
    "require(script.Parent.Element)": "ElementModule",
    "require(script.Parent.Label)": "LabelModule",
    "require(script.Parent.Divider)": "DividerModule",
    "require(script.Parent.Button)": "ButtonModule",
    "require(script.Parent.Dropdown)": "DropdownModule",
    "require(script.Parent.Input)": "InputModule",
    "require(script.Parent.Groupbox)": "GroupboxModule",
    "require(script.Parent.Shell)": "ShellModule",

    "require(script.Parent.ThemeManager)": "ThemeManagerModule",
    "require(script.Parent.Parent)": "ZedlibModule",
    "require(script.Parent.Parent.core.Persistence)": "PersistenceModule",
}

EXAMPLE_MODULES = [
    ("MinimalExample", "src/examples/Minimal.luau"),
    ("ManagersExample", "src/examples/Managers.luau"),
    ("FullExample", "src/examples/Full.luau"),
]

ADDON_MODULES = [
    ("ThemeManagerModule", "src/addons/ThemeManager.luau"),
    ("SaveManagerModule", "src/addons/SaveManager.luau"),
]

UI_EXPORT = (
    "local UIModule = {\n"
    "    Metrics = MetricsModule,\n"
    "    Tokens = TokensModule,\n"
    "    Typography = TypographyModule,\n"
    "    Materials = MaterialsModule,\n"
    "    Popup = PopupModule,\n"
    "    Controls = ControlsModule,\n"
    "    Element = ElementModule,\n"
    "    Label = LabelModule,\n"
    "    Divider = DividerModule,\n"
    "    Button = ButtonModule,\n"
    "    Dropdown = DropdownModule,\n"
    "    Input = InputModule,\n"
    "    ValueControl = ValueControlModule,\n"
    "    Toggle = ToggleModule,\n"
    "    Slider = SliderModule,\n"
    "    ContextMenu = ContextMenuModule,\n"
    "    KeyPicker = KeyPickerModule,\n"
    "    ColorPicker = ColorPickerModule,\n"
    "    Container = ContainerModule,\n"
    "    UX = UXModule,\n"
    "    Groupbox = GroupboxModule,\n"
    "    Shell = ShellModule,\n"
    "    Create = ShellModule.new,\n"
    "}\n"
)


def bundle(modules) -> str:
    chunks = ["-- Generated by tools/build.py; edit src/ instead.\n"]
    for name, path in modules:
        source = (ROOT / path).read_text(encoding="utf-8")
        for original, replacement in IMPORTS.items():
            source = source.replace(original, replacement)
        chunks.append(f"local {name} = (function()\n{source}\nend)()\n")
    return "\n".join(chunks)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--test", action="store_true")
    parser.add_argument("--ui", action="store_true")
    parser.add_argument("--theme", action="store_true")
    parser.add_argument("--managers", action="store_true")
    parser.add_argument("--stress", action="store_true")
    parser.add_argument("--examples", action="store_true")
    args = parser.parse_args()
    if args.managers:
        output = ROOT / "tests/.managers.luau"
        content = (ROOT / "tests/JsonMock.luau").read_text(encoding="utf-8") + (ROOT / "tests/UIMock.luau").read_text(encoding="utf-8")
        content += "\n" + bundle(CORE_MODULES + UI_MODULES)
        content += "\n" + UI_EXPORT
        content += bundle(ADDON_MODULES)
        content += (ROOT / "tests/Managers.spec.luau").read_text(encoding="utf-8")
    elif args.examples:
        output = ROOT / "tests/.examples.luau"
        content = (ROOT / "tests/JsonMock.luau").read_text(encoding="utf-8") + (ROOT / "tests/UIMock.luau").read_text(encoding="utf-8")
        content += "\n" + bundle(CORE_MODULES + UI_MODULES)
        content += "\n" + UI_EXPORT
        content += bundle(ADDON_MODULES)
        content += (
            "\nlocal ZedlibModule = {\n"
            "    Library = LibraryModule,\n"
            "    Types = TypesModule,\n"
            "    UI = UIModule,\n"
            "    ThemeManager = ThemeManagerModule,\n"
            "    SaveManager = SaveManagerModule,\n"
            "}\n"
        )
        content += bundle(EXAMPLE_MODULES)
        content += (ROOT / "tests/Examples.spec.luau").read_text(encoding="utf-8")
    elif args.stress:
        output = ROOT / "tests/.stress.luau"
        content = (ROOT / "tests/JsonMock.luau").read_text(encoding="utf-8") + (ROOT / "tests/UIMock.luau").read_text(encoding="utf-8")
        content += "\n" + bundle(CORE_MODULES + UI_MODULES)
        content += "\n" + UI_EXPORT
        content += bundle(ADDON_MODULES)
        content += (ROOT / "tests/Stress.spec.luau").read_text(encoding="utf-8")
    elif args.theme:
        output = ROOT / "tests/.theme.luau"
        content = (ROOT / "tests/JsonMock.luau").read_text(encoding="utf-8") + (ROOT / "tests/UIMock.luau").read_text(encoding="utf-8")
        content += "\n" + bundle(CORE_MODULES + UI_MODULES)
        content += "\n" + UI_EXPORT
        content += (ROOT / "tests/Theme.spec.luau").read_text(encoding="utf-8")
    elif args.ui:
        output = ROOT / "tests/.ui.luau"
        content = (ROOT / "tests/JsonMock.luau").read_text(encoding="utf-8") + (ROOT / "tests/UIMock.luau").read_text(encoding="utf-8")
        content += "\n" + bundle(CORE_MODULES + UI_MODULES)
        content += "\n" + UI_EXPORT
        content += (ROOT / "tests/UI.spec.luau").read_text(encoding="utf-8")
        content += (ROOT / "tests/CoreUI.spec.luau").read_text(encoding="utf-8")
        content += (ROOT / "tests/Shell.spec.luau").read_text(encoding="utf-8")
    elif args.test:
        output = ROOT / "tests/.generated.luau"
        content = (ROOT / "tests/RobloxMock.luau").read_text(encoding="utf-8")
        content += "\nlocal function loadModules()\n" + bundle(CORE_MODULES)
        content += "\nreturn LibraryModule, ResourcesModule\nend\n"
        content += "local LibraryModule, ResourcesModule = loadModules()\n"
        content += (ROOT / "tests/Foundation.spec.luau").read_text(encoding="utf-8")
    else:
        parser.error("Choose a test suite flag")
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(content, encoding="utf-8")
    print(output)
