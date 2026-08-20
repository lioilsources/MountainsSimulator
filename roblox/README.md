# roblox/ — Studio strana

Zdrojem pravdy jsou `.lua` soubory. `.rbxlx` je generovaný artefakt —
po úpravě zdrojáků spusť `./build.sh`.

```bash
./build.sh            # aréna beskydy (testovací výřez) + lobby
./build.sh everest    # aréna everest + lobby
```

Vznikne `MountainsSimulator-<aréna>.rbxlx` a `MountainsLobby.rbxlx` (výběr
kontinentu). Otevři je ve Studiu přes File → Open from File. Po importu
terénu place ulož (Cmd+S) — build.sh ho pak odmítne přepsat, dokud ho
nesmažeš nebo nepřejmenuješ; soubory s terénem jsou v .gitignore.

## Soubory

| Soubor | Co dělá |
|---|---|
| `flight-controller.client.lua` | letový model, kamera, HUD s výškoměrem |
| `arena-setup.server.lua` | fog a osvětlení per pohoří, kontrola importu terénu |
| `lobby.client.lua` | výběr kontinentu → `TeleportService` |
| `Mountains.lua` | **generované** konstanty, POI vrcholů a mapový rastr ze sidecarů |
| `update-place.py` | vymění skripty v uloženém place, terén nechá být |
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
| M | mapa arény s vrcholy (POI) |
| V | kamera chase / first-person |
| R | respawn |

Skimming nízko nad terénem nabíjí boost, náraz nad 15 m/s sebere rychlost.
Kompas nahoře ukazuje kurz a vrcholy v okolí; když míříš na některý
(±10°), vypíše jeho jméno, výšku a vzdálenost v reálných km.

## Aktualizace uloženého place

Place s naimportovaným terénem má stovky MB — build.sh ho odmítá přepsat.
Když se změní `.lua` zdrojáky nebo `Mountains.lua`:

```bash
./update-place.py MountainsSimulator-beskydy.rbxlx
```

Vymění jen zdrojáky skriptů (podle jména), terén nechá být, arénu v
ArenaSetup zachová a vyrobí zálohu `.bak`. Place nesmí být zrovna otevřený
ve Studiu. Kdyby v budoucnu přibyl **nový** skript (ne jen změna
existujícího), updater ho nepřidá — musel by se vložit ve Studiu ručně,
nebo znovu postavit place a přeimportovat terén.

## Varianta A: pět Places

Podle `TERRAIN_PLAN.md` je každé pohoří vlastní Place v jednom Experience.
Postup: publikuj `MountainsSimulator.rbxlx` postavené s `./build.sh <klic>`
pro každé pohoří zvlášť, pak doplň `placeId` k příslušným arénám. Ty ale
nepiš do `Mountains.lua` (přegeneruje se) — přidej je do `presets.go`
k presetu, ať projdou přes sidecar. Dokud je `placeId = 0`, lobby to místo
teleportu jen napíše.
