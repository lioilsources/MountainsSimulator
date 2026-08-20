# roblox/ — Studio strana

Zdrojem pravdy jsou `.lua` soubory. `.rbxlx` je generovaný artefakt —
po úpravě zdrojáků spusť `./build.sh`.

```bash
./build.sh            # aréna beskydy (testovací výřez) + lobby
./build.sh everest    # aréna everest + lobby
```

Vznikne `MountainsSimulator.rbxlx` (jedna aréna) a `MountainsLobby.rbxlx`
(výběr kontinentu). Otevři je ve Studiu přes File → Open from File.

## Soubory

| Soubor | Co dělá |
|---|---|
| `flight-controller.client.lua` | letový model, kamera, HUD s výškoměrem |
| `arena-setup.server.lua` | fog a osvětlení per pohoří, kontrola importu terénu |
| `lobby.client.lua` | výběr kontinentu → `TeleportService` |
| `Mountains.lua` | **generované** konstanty ze sidecarů |
| `IMPORT.md` | **generovaný** tahák na import terénu |
| `build.sh` | složí `.rbxlx` z výše uvedeného |

## Postup pro novou arénu

1. `cd ../terrain-fetch && ./terrain-fetch --preset <klic>`
2. Přegeneruj konstanty: `./terrain-fetch --emit-lua ../roblox/Mountains.lua`
3. `cd ../roblox && ./build.sh <klic>`
4. Ve Studiu naimportuj heightmapu podle [`IMPORT.md`](IMPORT.md).
5. Play. Když terén chybí, server vypíše do Output přesná čísla pro import.

## Ovládání

| Vstup | Akce |
|---|---|
| myš | zaměřovač — letadlo se za ním dotáčí |
| W / S | plyn / brzda (rychlost drží) |
| A / D | vybočení |
| Space / LeftShift | nos nahoru / dolů |
| pravé tlačítko | boost (stojí 25 z metru) |
| V | kamera chase / first-person |
| R | respawn |

Skimming nízko nad terénem nabíjí boost, náraz nad 15 m/s sebere rychlost.

## Varianta A: pět Places

Podle `TERRAIN_PLAN.md` je každé pohoří vlastní Place v jednom Experience.
Postup: publikuj `MountainsSimulator.rbxlx` postavené s `./build.sh <klic>`
pro každé pohoří zvlášť, pak doplň `placeId` k příslušným arénám. Ty ale
nepiš do `Mountains.lua` (přegeneruje se) — přidej je do `presets.go`
k presetu, ať projdou přes sidecar. Dokud je `placeId = 0`, lobby to místo
teleportu jen napíše.
