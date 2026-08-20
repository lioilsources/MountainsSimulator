# MountainsSimulator — poznámky pro Claude Code

Roblox hra: létání nad reálným terénem pěti pohoří. Terén se předpočítá
offline Go toolem do heightmap, Studio je importuje. Letový model vychází
z `../DoggioFight/roblox` (Luanti hra DoggioWars a její Roblox port) — když
řešíš "feel" letu, koukej tam.

## Zdroje pravdy

- **`.lua` soubory v `roblox/`**, ne `.rbxlx`. Place je generovaný artefakt;
  po úpravě zdrojáků spusť `roblox/build.sh`.
- **Sidecar JSONy v `terrain-fetch/out/`** nesou herní měřítka.
  `roblox/Mountains.lua` a `roblox/IMPORT.md` jsou z nich **generované** —
  needituj je ručně, přegeneruj:
  ```bash
  cd terrain-fetch && ./terrain-fetch --emit-lua ../roblox/Mountains.lua \
                   && ./terrain-fetch --emit-import-md ../roblox/IMPORT.md
  ```
  Když se přegeneruje heightmapa, musí se přegenerovat i tohle — jinak hra
  počítá výšky proti jiné normalizaci, než jakou má naimportované PNG.

## Konvence

- **Luau bez Luau-only syntaxe.** Žádné `+=`, `continue` ani typové anotace —
  DoggioWars to drží tak, aby skripty přeložil i LuaJIT a šly testovat
  headless. Kontrola: `luajit -e 'assert(loadfile("soubor.lua"))'`.
- **Go bez externích závislostí.** Vlastní worker pool i resample; důvod je
  v `TERRAIN_PLAN.md` (resample musí běžet ve float32 metrech, ne přes
  `image.Image`).
- **Colormapa nesmí mít gradienty.** Importér snapuje na nejbližší
  `Terrain.MaterialColors`; míchaná barva spadne na cizí materiál.
- Uživatelské texty v Lua souborech jsou bez diakritiky (Roblox fonty).

## Co je ruční krok

Import heightmapy v Terrain Editoru. Nejde skriptovat — `Terrain:WriteVoxels()`
by na arénu 16k×14k studů znamenal miliardy voxelů. Čísla pro dialog vypíše
`arena-setup.server.lua` do Output, když terén chybí.

## Cache

Dlaždice: `~/.cache/terrain-fetch` → symlink na `/Volumes/YOTTA/Caches/terrain-fetch`
(boot SSD je malý). Dlaždice jsou neměnné, cache se nikdy neinvaliduje.
