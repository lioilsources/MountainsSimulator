package main

import (
	"fmt"
	"image"
	"image/color"
	"image/png"
	"math"
	"os"
	"sort"
)

// Terrain material colours, taken from Roblox Studio's own
// PlatformContent/pc/terrain/materials.json ("base_color"). These are the
// defaults of Terrain.MaterialColors, which is what the Terrain Editor's
// colormap import matches pixels against — so a colormap painted in exactly
// these RGBs imports without touching any Studio setting.
//
// The 2022 material set renders differently (Snow is pure white there), but
// MaterialColors keeps these legacy values, so match against these.
var materialColors = map[string][3]uint8{
	"Grass":      {106, 127, 63},
	"LeafyGrass": {115, 132, 74},
	"Ground":     {102, 92, 59},
	"Mud":        {58, 46, 36},
	"Sand":       {143, 126, 95},
	"Sandstone":  {137, 90, 71},
	"Limestone":  {206, 173, 148},
	"Rock":       {102, 108, 111},
	"Slate":      {63, 127, 107},
	"Basalt":     {30, 30, 37},
	"Snow":       {195, 199, 218},
	"Glacier":    {101, 176, 234},
	"Salt":       {198, 189, 181},
}

// band assigns a material to everything below TopM metres.
type band struct {
	TopM     float64
	Material string
}

// palette is a set of elevation bands plus the material that steep faces get
// regardless of height — bare rock holds neither soil nor snow.
type palette struct {
	Bands     []band
	SteepMat  string
	SteepDeg  float64
	SteepMinM float64 // below this elevation the steep rule is off (valley walls stay green)
}

var palettes = map[string]palette{
	// Alps, and anything else temperate — also used for the Beskydy test crop,
	// where the whole range stays inside the first two bands.
	"alpine": {
		Bands: []band{
			{800, "LeafyGrass"}, {1600, "Grass"}, {2300, "Ground"},
			{2900, "Rock"}, {3800, "Snow"}, {math.Inf(1), "Glacier"},
		},
		SteepMat: "Rock", SteepDeg: 38, SteepMinM: 400,
	},
	// No Glacier band up top: ice on the summits would read as blue caps,
	// while the Khumbu icefields actually sit in the valleys below.
	"himalaya": {
		Bands: []band{
			{3600, "Ground"}, {4900, "Rock"}, {math.Inf(1), "Snow"},
		},
		SteepMat: "Rock", SteepDeg: 42, SteepMinM: 0,
	},
	// Kilimanjaro's climate belts: savanna, montane forest, moorland and the
	// volcanic alpine desert, then the summit icecap. Kept to few, wide bands
	// on purpose — a symmetric cone turns every extra band into a contour ring.
	"savanna": {
		Bands: []band{
			{1600, "Sand"}, {3000, "LeafyGrass"}, {4300, "Ground"},
			{5400, "Rock"}, {math.Inf(1), "Snow"},
		},
		SteepMat: "Rock", SteepDeg: 40, SteepMinM: 3000,
	},
	// Mud rather than Sandstone at the bottom: only the valley floors fall in
	// that band, so a red material traced the drainage network in bright veins.
	"andes": {
		Bands: []band{
			{3000, "Mud"}, {4200, "Ground"}, {5200, "Rock"},
			{6200, "Snow"}, {math.Inf(1), "Glacier"},
		},
		SteepMat: "Rock", SteepDeg: 40, SteepMinM: 0,
	},
	"rockies": {
		Bands: []band{
			{2500, "LeafyGrass"}, {3400, "Grass"}, {3900, "Rock"},
			{math.Inf(1), "Snow"},
		},
		SteepMat: "Rock", SteepDeg: 38, SteepMinM: 1500,
	},
}

// MaterialUse records what a colormap actually painted, for the sidecar.
type MaterialUse struct {
	Material string  `json:"material"`
	RGB      [3]int  `json:"rgb"`
	Percent  float64 `json:"percent"`
}

// writeColormap paints a material map from elevation and slope. Every pixel
// gets one material's exact RGB — no gradients, no dithering, because the
// importer snaps each pixel to the nearest MaterialColors entry and a blended
// colour would land on some third material.
func writeColormap(path string, g *Grid, paletteName string, metersPerPx float64) ([]MaterialUse, error) {
	p, ok := palettes[paletteName]
	if !ok {
		return nil, fmt.Errorf("unknown palette %q", paletteName)
	}
	steepSlope := math.Tan(p.SteepDeg * math.Pi / 180)

	img := image.NewRGBA(image.Rect(0, 0, g.W, g.H))
	counts := map[string]int{}

	for y := 0; y < g.H; y++ {
		for x := 0; x < g.W; x++ {
			elev := float64(g.at(x, y))

			mat := p.Bands[len(p.Bands)-1].Material
			for _, b := range p.Bands {
				if elev < b.TopM {
					mat = b.Material
					break
				}
			}

			if elev >= p.SteepMinM && slopeAt(g, x, y, metersPerPx) > steepSlope {
				mat = p.SteepMat
			}

			c := materialColors[mat]
			img.SetRGBA(x, y, color.RGBA{R: c[0], G: c[1], B: c[2], A: 255})
			counts[mat]++
		}
	}

	f, err := os.Create(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	enc := png.Encoder{CompressionLevel: png.BestCompression}
	if err := enc.Encode(f, img); err != nil {
		return nil, err
	}

	total := float64(g.W * g.H)
	used := make([]MaterialUse, 0, len(counts))
	for m, n := range counts {
		c := materialColors[m]
		used = append(used, MaterialUse{
			Material: m,
			RGB:      [3]int{int(c[0]), int(c[1]), int(c[2])},
			Percent:  round1(float64(n) / total * 100),
		})
	}
	sort.Slice(used, func(i, j int) bool { return used[i].Percent > used[j].Percent })
	return used, nil
}

// slopeAt is the gradient magnitude (rise over run) by central differences.
func slopeAt(g *Grid, x, y int, metersPerPx float64) float64 {
	dx := float64(g.clampedAt(x+1, y)-g.clampedAt(x-1, y)) / (2 * metersPerPx)
	dy := float64(g.clampedAt(x, y+1)-g.clampedAt(x, y-1)) / (2 * metersPerPx)
	return math.Hypot(dx, dy)
}
