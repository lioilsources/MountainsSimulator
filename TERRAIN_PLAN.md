# TERRAIN_PLAN.md — Reálná pohoří v Roblox portu DoggioWars (offline verze)

## Cíl

Létání nad reálným terénem 5 pohoří z 5 kontinentů, plně offline — bez runtime
serveru. Terén se generuje z reálných výškových dat (DEM), nikoli z
OpenStreetMap (OSM elevaci neobsahuje).

## Klíčové rozhodnutí: výřezy, ne celá pohoří

Ano, vždy jen **výřez ~30–50 km kolem ikonického vrcholu**. Důvody:

- Celé Andy měří ~7000 km, Himaláje ~2400 km — to nedává smysl ani datově, ani herně.
- Roblox terén je prakticky omezen na ~±32k studů od originu; při rozumném
  měřítku se do toho vejde právě těch 30–50 km.
- Heightmap limit 4096×4096 px: výřez 40 km → ~10 m/px, což je krásný detail.
  Celé pohoří by znamenalo stovky m/px = rozmazaná placka.
- Hráč stejně pozná pohoří podle dominanty (Everest, Mont Blanc, kužel
  Kilimandžára), ne podle rozlohy.

Výřez volit tak, aby dominanta byla zhruba uprostřed a v záběru byl
charakteristický reliéf (hřebeny, údolí, ledovce).

## 5 pohoří / 5 kontinentů

| # | Kontinent | Pohoří (dominanta) | bbox (lat_min, lon_min, lat_max, lon_max) | zoom | relief |
|---|---|---|---|---|---|
| 1 | Evropa | Alpy (Mont Blanc, 4810 m) | 45.70, 6.60, 46.05, 7.10 | 12 | ~3800 m |
| 2 | Asie | Himaláje (Everest, 8849 m) | 27.80, 86.60, 28.10, 87.10 | 12 | ~4500 m |
| 3 | Afrika | Kilimandžáro (5895 m) | -3.25, 37.20, -2.95, 37.55 | 12 | ~4900 m |
| 4 | J. Amerika | Andy (Aconcagua, 6961 m) | -33.00, -70.20, -32.50, -69.70 | 12 | ~4000 m |
| 5 | S. Amerika | Skalisté hory (Longs Peak, 4346 m) | 40.10, -105.80, 40.45, -105.40 | 12 | ~2000 m |

Bonus/test preset (mimo pětku): Beskydy `49.35, 18.20, 49.65, 18.75` — malý
relief, rychlá iterace pipeline, domácí půda.

## Architektura (offline)

```
[AWS Terrain Tiles (Mapzen)]
        │  terrain-RGB PNG dlaždice (z/x/y)
        ▼
[Go tool: terrain-fetch]           ← běží lokálně, cache na NAS
        │  dekódování, mozaika, ořez, resample, normalizace
        ▼
[5× heightmap PNG 16-bit + sidecar JSON]
        │
        ▼
[Roblox Studio → Terrain Editor → Import]
        │  každé pohoří jako samostatná "aréna"
        ▼
[Hra: výběr pohoří = teleport / load Place]
```

Žádný Go server, žádné HttpService. Vše předpočítané v build-time.

## Fáze 1 — Go tool `terrain-fetch`

Repo: `lioilsources/terrain-fetch`.

### Zdroj dat

AWS Terrain Tiles (Mapzen), formát **terrarium**:

```
https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{z}/{x}/{y}.png
```

Dekódování výšky v metrech:

```go
height := float64(r)*256 + float64(g) + float64(b)/256 - 32768
```

### CLI

```bash
terrain-fetch \
  --preset everest \        # nebo --bbox lat0,lon0,lat1,lon1
  --zoom 12 \
  --out everest.png \
  --size 4096 \
  --scale auto
```

### Kroky implementace

1. `bbox → seznam dlaždic` (Slippy map tile math).
2. Paralelní stahování (`errgroup`, ~8 workerů, retry s backoff).
3. Cache dlaždic: `~/.cache/terrain-fetch/{z}/{x}/{y}.png`, dlouhodobě NAS.
4. Mozaika do `image.Gray16`.
5. Ořez na přesný bbox.
6. Resample na cíl (max 4096×4096, `x/image/draw` CatmullRom).
7. Normalizace: relief `min..max` → `0..65535`, metadata do sidecar JSON.
8. Presety pohoří zabudované v toolu (tabulka výše jako Go mapa).

### Sidecar metadata (příklad)

```json
{
  "name": "Everest",
  "continent": "Asia",
  "bbox": [27.80, 86.60, 28.10, 87.10],
  "min_elevation_m": 4300,
  "max_elevation_m": 8849,
  "width_px": 4096,
  "height_px": 2458,
  "meters_per_pixel": 12.0
}
```

## Fáze 2 — Import do Studia

### Vertikální měřítko

Reálné výšky 1:1 nefungují. Škálovat jen **relief nad min_elevation** (base
level odečíst):

| Pohoří | relief | doporučené study/m | výška terénu ve hře |
|---|---|---|---|
| Skalisté hory | ~2000 m | 0.20 | ~400 studů |
| Alpy | ~3800 m | 0.12 | ~450 studů |
| Andy | ~4000 m | 0.12 | ~480 studů |
| Himaláje | ~4500 m | 0.10 | ~450 studů |
| Kilimandžáro | ~4900 m | 0.10 | ~490 studů |

Cíl: všechny arény mají podobnou herní výšku (~400–500 studů), ale zachovávají
charakter reliéfu. Konstanty do sidecar JSON, ať jsou verzované.

### Horizontální měřítko

Výřez 40 km na 4096 px → při 1 px = 1 voxel (4 study) vyjde aréna ~16k studů.
Přelet při rychlosti letadla DoggioWars naladit na ~2–4 min z kraje na kraj;
případně resample na 2048 px (aréna 8k studů).

### Struktura hry — dvě varianty

**Varianta A (doporučená): 5 samostatných Places + TeleportService**
- Každé pohoří = vlastní Place v rámci jednoho Experience.
- Lobby s výběrem kontinentu → `TeleportService:Teleport(placeId)`.
- Výhody: žádné limity velikosti terénu, čisté oddělení, nezávislé ladění
  materiálů/skyboxu per pohoří.

**Varianta B: vše v jednom Place, arény vedle sebe**
- 5 arén rozmístěných v gridu s odstupem, hráč se přemisťuje spawn pointy.
- Výhody: jednodušší správa. Nevýhody: blíž limitům terénu, delší load,
  StreamingEnabled nutný.

Začít Variantou A.

### Colormap / materiály

- Generovat colormap PNG v `terrain-fetch` z výšky + sklonu (druhý výstup vedle
  heightmapy).
- Palety per pohoří: Kilimandžáro savana→les→alpinská poušť→ledovec; Himaláje
  skála→sníh od ~6000 m; Skalisté les→skála.
- Import materiálů řešit v Terrain Editoru (colormap → material map), doladit
  ručně.

## Fáze 3 — Polish

- Skybox + fog per pohoří (hustý opar v Andách, čisté nebe Kilimandžáro).
- Atribuce dat v popisu hry (Mapzen/AWS Terrain Tiles: SRTM/NASA aj. —
  licenčně povinné).
- OSM vektory jako dekorace (řeky, ledovce) — volitelný bonus, tady už OSM
  dává smysl.

## Poznámka: kdyby později bylo potřeba runtime generování

Offline přístup záměrně vynechává server. Kdyby v budoucnu byl potřeba
neomezený katalog pohoří nebo streaming větších oblastí, lze doplnit Go
endpoint (`terrain.ol1n.com`) servírující výškové chunky pro
`Terrain:WriteVoxels()` — návrh je v git historii tohoto plánu.

## Pořadí prací (handoff pro Claude Code)

1. [x] `terrain-fetch`: tile math + downloader + cache
2. [x] Dekódování terrarium → `image.Gray16` mozaika
3. [x] Ořez + resample + normalizace + sidecar JSON + presety
4. [~] Test preset Beskydy → PNG → import do Studia, test letu, kalibrace
       měřítek — PNG hotová a ověřená hillshadem, import do Studia je ruční
       krok (viz `roblox/IMPORT.md`)
5. [x] Colormap generátor (výška + sklon, palety per pohoří)
6. [x] Vygenerovat 5 kontinentálních presetů
7. [~] 5 Places + lobby + TeleportService — scaffolding hotové
       (`roblox/build.sh` staví arénu i lobby), `placeId` se doplní po
       publikaci
8. [ ] Materiály, skybox, atribuce — skybox/fog per pohoří hotové
       v `arena-setup.server.lua`, atribuce v sidecarech

## Odchylky od plánu (a proč)

Zjištěné až při implementaci; plán výše je ponechán v původním znění.

**`--zoom 12` a `--size 4096` si odporují.** Při zoomu 12 má výřez nativně
~1000–1600 px, ne 4096. Upsample na 4096 by nepřidal žádný detail, jen
velikost souboru — a zdrojová data (SRTM 30 m) stejně na víc nemají. Zoom 12
vychází na 25–38 m/px, což zdroji odpovídá přesně. `--size` proto neznamená
cílovou velikost, ale **strop**; výchozí `0` = nativní rozlišení. Vyšší detail
se získá vyšším `--zoom`, ne větším `--size`.

**Žádné externí Go závislosti.** Místo `errgroup` je vlastní worker pool
(pár řádků) a místo `x/image/draw` vlastní separabilní Catmull-Rom resample.
Důvod není purismus: `x/image/draw` pracuje nad `image.Image`, což by výšky
kvantizovalo do 16 bitů **před** resamplem. Vlastní resample počítá ve
`float32` v metrech a při zmenšování rozšiřuje jádro (plnohodnotný
antialiasing) — bez toho se hřebeny rozpadají na aliasované špičky.

**Colormapa je tvrdá klasifikace, ne gradient.** Importér páruje každý pixel
na nejbližší barvu z `Terrain.MaterialColors`; míchaná barva mezi dvěma
materiály by spadla na nějaký třetí. Přesné výchozí RGB jsou vytažené ze
Studia (`PlatformContent/pc/terrain/materials.json`).

**Cache dlaždic je na YOTTA**, `~/.cache/terrain-fetch` je symlink — boot SSD
má volných jen ~46 GB.

**Převýšení — pravidlo „všechny arény ~450 studů" zrušeno (2026-08-20).**
Konstanty study/m z plánu výše dávaly převýšení 0.24–0.41: hory vycházely
2,5–4× placatější než ve skutečnosti a létalo se nad planinou. Rozhodnutí:
jednotná svislá konstanta **0.68 studu/m** pro všechny arény (v `presets.go`
jako `verticalStudsPerMeter`), zvolená z řezu Mont Blancem jako „filmová" —
~1.6× převýšení. Důsledky: arény mají 704–3946 studů výšky, převýšení
1.4–2.0× podle vodorovného měřítka arény, a protože je konstanta sdílená,
zůstává pravdivý poměr mezi pohořími — Everest (3946) opravdu ční nad
Skalisté hory (1601). Letadlo se neškáluje: je to herní model, ne reference
skutečnosti; rychlost si hráč volí plynem od kochání po slalom.
