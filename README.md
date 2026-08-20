# MountainsSimulator ⛰️

**Létání nad reálnými horami v Robloxu.** Pět pohoří z pěti kontinentů,
postavených z opravdových výškových dat — Mont Blanc, Everest, Kilimandžáro,
Aconcagua, Skalisté hory. Letový model je převzatý z
[DoggioWars](https://github.com/lioilsources/DoggioWars): myš míří, letadlo se
za zaměřovačem dotáčí, plyn drží nastavenou rychlost, strmhlav zrychluje.

Celá pipeline je **offline**: žádný runtime server, žádné `HttpService`. Terén
se předpočítá lokálně do heightmap a naimportuje do Studia.

```
AWS Terrain Tiles ──> terrain-fetch (Go) ──> 16bit PNG + sidecar JSON
                                                    │
                                          ┌─────────┴─────────┐
                                          ▼                   ▼
                              Terrain Editor Import      Mountains.lua
                                  (ruční krok)         (herní konstanty)
```

## Co už funguje

- **`terrain-fetch`** — stáhne dlaždice, dekóduje terrarium na metry, slepí,
  ořízne na bbox, resampluje ve float32 a znormalizuje na 16bit PNG. K tomu
  colormapu pro materiály, hillshade náhled a sidecar JSON s herními
  konstantami.
- **6 presetů** — pět kontinentálních pohoří a Beskydy jako rychlý test.
  Všechny dominanty vycházejí do 1 % skutečné výšky (Mont Blanc 4790/4810,
  Everest 8753/8849, Kilimandžáro 5887/5895, Aconcagua 6940/6961, Longs Peak
  4349/4346 — rozdíl je rozlišení SRTM, ne chyba pipeline).
- **Roblox scaffolding** — letový model, setup arény s fogem per pohoří,
  lobby s `TeleportService`, a `build.sh`, který z `.lua` zdrojáků složí
  `.rbxlx`.

## Rychlý start

```bash
cd terrain-fetch
go build -o terrain-fetch .
./terrain-fetch --list
./terrain-fetch --preset beskydy      # ~40 dlaždic, pár sekund
open out/beskydy-preview.png          # hillshade: sedí výřez?
```

Pak vygeneruj herní konstanty a slož place:

```bash
./terrain-fetch --emit-lua ../roblox/Mountains.lua
./terrain-fetch --emit-import-md ../roblox/IMPORT.md
cd ../roblox && ./build.sh beskydy
```

Otevři `roblox/MountainsSimulator.rbxlx` ve Studiu, naimportuj heightmapu podle
[`roblox/IMPORT.md`](roblox/IMPORT.md) a stiskni Play. Dokud terén nenaimportuješ,
server to při startu vypíše do Output i s čísly, která má import dostat.

## Struktura

```
terrain-fetch/       Go tool (vlastní modul, jde vyčlenit do vlastního repa)
  presets.go         tabulka pohoří — bbox, zoom, svislé měřítko, paleta
  tiles.go           slippy math, Web Mercator, volba zoomu
  fetch.go           stahování s cache a retry
  mosaic.go          terrarium dekódování, mozaika, ořez, resample
  colormap.go        klasifikace materiálů z výšky a sklonu
  preview.go         hillshade náhled
  output.go          16bit PNG + sidecar JSON
  emitlua.go         sidecar -> Mountains.lua a IMPORT.md
  out/               výstupy (PNG v .gitignore, JSON se commituje)

roblox/              Studio strana; zdrojem pravdy jsou .lua, .rbxlx je artefakt
  Mountains.lua      GENEROVANÉ konstanty ze sidecarů
  IMPORT.md          GENEROVANÝ tahák na import
  build.sh           .lua -> MountainsSimulator.rbxlx + MountainsLobby.rbxlx
```

Podrobný plán, včetně odchylek zjištěných při implementaci, je
v [`TERRAIN_PLAN.md`](TERRAIN_PLAN.md).

## Data a atribuce

Výšková data: **AWS Terrain Tiles (Mapzen)**, terrarium encoding — složeno ze
SRTM (NASA/USGS), 3DEP (USGS), EU-DEM (EEA) a GMTED2010. Atribuce je povinná
a patří do popisu hry; přesný řetězec nese každý sidecar JSON v poli
`attribution`.

## Licence

Kód a dokumentace **MIT**. Výšková data mají licenci svých zdrojů (viz výše).
