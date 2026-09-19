# Development

Edit `src/`. Root `Library.lua` and `addons/*.lua` are generated and committed for raw consumers.
`src/Client.luau` composes the core constructor and window implementation. Each addon is bundled from its own dependency graph.
The bundler resolves ModuleScript imports, emits dependencies once, rejects unresolved imports and cycles, and writes stable UTF-8 output without timestamps.

## Checks

Requires Python 3.10+, Luau CLI, and StyLua 2.5.2. `rokit.toml` pins the formatter.

```sh
stylua src tests Example.lua init.luau Library.d.luau
python tools/build.py
python tools/check.py
```

`python tools/build.py --check` checks bundle drift without modifying files.
`python tools/check.py` runs the maintained lifecycle, UI, theme, manager, stress, example, and distribution tests.
The distribution test runs the root example against all three generated bundles in a mock Roblox runtime. Also run the published example in a real client before release.

Commit source and generated files together. CI checks formatting, bundle consistency, and regressions.
There is no Wally manifest or Selene configuration because those workflows are not configured for this project.
No external image assets are required by the default interface.
