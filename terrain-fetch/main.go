// terrain-fetch builds Roblox-ready heightmaps of real mountains from AWS
// Terrain Tiles (Mapzen terrarium). See TERRAIN_PLAN.md in the parent repo.
package main

import (
	"flag"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

const (
	// maxSourceZoom is where AWS Terrain Tiles stop; asking for more just
	// resamples the same data.
	maxSourceZoom = 15
	attribution   = "Elevation: AWS Terrain Tiles (Mapzen) — SRTM (NASA/USGS), " +
		"3DEP (USGS), EU-DEM (EEA), GMTED2010. Public domain / CC-BY as per source."
	sourceName = "AWS Terrain Tiles, terrarium encoding"
)

func main() {
	var (
		presetKey  = flag.String("preset", "", "mountain preset ("+strings.Join(presetKeys(), ", ")+")")
		bboxArg    = flag.String("bbox", "", "explicit bbox: lat_min,lon_min,lat_max,lon_max")
		name       = flag.String("name", "", "display name for a --bbox run")
		zoom       = flag.Int("zoom", 0, "tile zoom; 0 = the preset's zoom, or auto for a --bbox run")
		size       = flag.Int("size", 0, "cap the longest output edge in px; 0 = native tile resolution")
		out        = flag.String("out", "", "heightmap path; default <outdir>/<preset>.png")
		outDir     = flag.String("outdir", "out", "output directory")
		cacheDir   = flag.String("cache", defaultCacheDir(), "tile cache directory")
		urlTmpl    = flag.String("url", defaultTileURL, "tile URL template with {z}/{x}/{y}")
		workers    = flag.Int("workers", 8, "parallel tile downloads")
		retries    = flag.Int("retries", 4, "retries per tile, with exponential backoff")
		arenaStuds = flag.Float64("arena-studs", 16384, "in-game arena width in studs")
		studsY     = flag.Float64("studs-per-meter-y", 0, "vertical scale; 0 = the preset's constant")
		colormap   = flag.Bool("colormap", true, "also write a colormap PNG for material painting")
		preview    = flag.Bool("preview", true, "also write a hillshaded preview PNG for eyeballing the crop")
		list       = flag.Bool("list", false, "list presets and exit")
		emitLuaOut = flag.String("emit-lua", "", "write a Luau constants module from the sidecars in --outdir, then exit")
		emitMDOut  = flag.String("emit-import-md", "", "write the Studio import cheat sheet from the sidecars in --outdir, then exit")
	)
	flag.Parse()

	if *list {
		listPresets()
		return
	}
	if *emitMDOut != "" {
		if err := emitImportMD(*outDir, *emitMDOut); err != nil {
			fmt.Fprintln(os.Stderr, "error:", err)
			os.Exit(1)
		}
		return
	}
	if *emitLuaOut != "" {
		if err := emitLua(*outDir, *emitLuaOut); err != nil {
			fmt.Fprintln(os.Stderr, "error:", err)
			os.Exit(1)
		}
		return
	}
	if err := run(runOpts{
		presetKey: *presetKey, bboxArg: *bboxArg, name: *name,
		zoom: *zoom, size: *size, out: *out, outDir: *outDir,
		cacheDir: *cacheDir, urlTmpl: *urlTmpl,
		workers: *workers, retries: *retries,
		arenaStuds: *arenaStuds, studsY: *studsY, colormap: *colormap, preview: *preview,
	}); err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}

type runOpts struct {
	presetKey, bboxArg, name string
	zoom, size               int
	out, outDir              string
	cacheDir, urlTmpl        string
	workers, retries         int
	arenaStuds, studsY       float64
	colormap, preview        bool
}

func run(o runOpts) error {
	p, err := resolvePreset(o)
	if err != nil {
		return err
	}

	z := p.Zoom
	if o.zoom > 0 {
		z = o.zoom
	}
	if z > maxSourceZoom {
		fmt.Fprintf(os.Stderr, "note: zoom %d is past the source's %d — capping\n", z, maxSourceZoom)
		z = maxSourceZoom
	}

	nw, nh := nativeSize(p.BBox, z)
	tw, th := fitSize(nw, nh, o.size)
	if o.size > nw && o.size > nh {
		fmt.Fprintf(os.Stderr,
			"note: --size %d is above the native %dx%d px at zoom %d; keeping native "+
				"(upsampling invents no detail — raise --zoom for more)\n", o.size, nw, nh, z)
	}

	r := tilesFor(p.BBox, z)
	mpp := metersPerPixel(p.BBox.centerLat(), z)
	widthM, heightM := p.BBox.groundSize(z)

	fmt.Printf("%s (%s) — %s\n", p.Name, p.Continent, p.Peak)
	fmt.Printf("  bbox      %.4f,%.4f .. %.4f,%.4f\n",
		p.BBox.LatMin, p.BBox.LonMin, p.BBox.LatMax, p.BBox.LonMax)
	fmt.Printf("  ground    %.1f x %.1f km  (%.1f m/px at zoom %d)\n",
		widthM/1000, heightM/1000, mpp, z)
	fmt.Printf("  tiles     %d  (%d x %d at zoom %d)\n", r.count(), r.X1-r.X0+1, r.Y1-r.Y0+1, z)
	fmt.Printf("  output    %d x %d px\n", tw, th)

	f := newFetcher(o.urlTmpl, o.cacheDir, o.workers, o.retries)
	start := time.Now()
	tiles, err := f.getRange(r, progressPrinter(r.count()))
	if err != nil {
		return err
	}
	fmt.Printf("\r  fetched   %d tiles in %s (%d cached, %d downloaded)\n",
		len(tiles), time.Since(start).Round(time.Millisecond),
		f.hits.Load(), f.misses.Load())

	m, err := mosaic(tiles, r)
	if err != nil {
		return err
	}
	g, err := crop(m, p.BBox, r)
	if err != nil {
		return err
	}
	g = resample(g, tw, th)

	// Metres per pixel of the resampled output, not of the source tiles.
	outMPP := mpp * float64(nw) / float64(tw)

	min, max := g.minMax()
	relief := float64(max - min)
	fmt.Printf("  elevation %.0f .. %.0f m  (relief %.0f m)\n", min, max, relief)

	studsY := p.StudsPerMeterY
	if o.studsY > 0 {
		studsY = o.studsY
	}
	rbx := buildRobloxMeta(widthM, heightM, float64(min), relief, studsY, o.arenaStuds, p.PlaceID)

	heightPath, base := outputPaths(o, p)
	if err := os.MkdirAll(filepath.Dir(heightPath), 0o755); err != nil {
		return err
	}
	if err := writeHeightmap(heightPath, g, min, max); err != nil {
		return err
	}

	colorPath := ""
	var materials []MaterialUse
	if o.colormap {
		colorPath = base + "-colormap.png"
		materials, err = writeColormap(colorPath, g, p.Palette, outMPP)
		if err != nil {
			return err
		}
	}

	previewPath := ""
	if o.preview {
		previewPath = base + "-preview.png"
		if err := writePreview(previewPath, g, p.Palette, outMPP, 1400); err != nil {
			return err
		}
	}

	side := Sidecar{
		Name: p.Name, Continent: p.Continent, Peak: p.Peak, PeakElevM: p.PeakElevM,
		BBox:          [4]float64{p.BBox.LatMin, p.BBox.LonMin, p.BBox.LatMax, p.BBox.LonMax},
		Zoom:          z,
		MinElevationM: math.Round(float64(min)), MaxElevationM: math.Round(float64(max)),
		ReliefM: math.Round(relief),
		WidthPx: tw, HeightPx: th,
		MetersPerPx: round4(outMPP),
		WidthM:      round1(widthM), HeightM: round1(heightM),
		Heightmap: filepath.Base(heightPath),
		Roblox:    rbx,
		Source:    sourceName, Attribution: attribution,
		Generator: "terrain-fetch",
	}
	if colorPath != "" {
		side.Colormap = filepath.Base(colorPath)
		side.ColormapMaterials = materials
	}
	sidePath := base + ".json"
	if err := writeSidecar(sidePath, side); err != nil {
		return err
	}

	fmt.Printf("  arena     %.0f x %.0f x %.0f studs  (vertical exaggeration %.2fx true scale)\n",
		rbx.RegionSizeStuds[0], rbx.RegionSizeStuds[1], rbx.RegionSizeStuds[2], rbx.VerticalExaggeration)
	fmt.Printf("  wrote     %s\n", heightPath)
	if colorPath != "" {
		fmt.Printf("            %s\n", colorPath)
	}
	if previewPath != "" {
		fmt.Printf("            %s\n", previewPath)
	}
	fmt.Printf("            %s\n", sidePath)
	return nil
}

// resolvePreset turns the flags into one arena definition, either a built-in
// preset or an ad-hoc bbox.
func resolvePreset(o runOpts) (Preset, error) {
	switch {
	case o.presetKey != "" && o.bboxArg != "":
		return Preset{}, fmt.Errorf("pass --preset or --bbox, not both")

	case o.presetKey != "":
		return lookupPreset(o.presetKey)

	case o.bboxArg != "":
		b, err := parseBBox(o.bboxArg)
		if err != nil {
			return Preset{}, err
		}
		name := o.name
		if name == "" {
			name = "custom"
		}
		z := o.zoom
		if z == 0 {
			// Aim for roughly the 30 m posting of the underlying DEMs.
			z = autoZoom(b, 1200, maxSourceZoom)
		}
		return Preset{
			Key: slug(name), Name: name, Continent: "", BBox: b, Zoom: z,
			StudsPerMeterY: 0.15, Palette: "alpine",
		}, nil
	}
	return Preset{}, fmt.Errorf("need --preset or --bbox (try --list)")
}

func parseBBox(s string) (BBox, error) {
	parts := strings.Split(s, ",")
	if len(parts) != 4 {
		return BBox{}, fmt.Errorf("bbox needs 4 comma-separated numbers, got %d", len(parts))
	}
	v := make([]float64, 4)
	for i, p := range parts {
		f, err := strconv.ParseFloat(strings.TrimSpace(p), 64)
		if err != nil {
			return BBox{}, fmt.Errorf("bbox part %q: %w", p, err)
		}
		v[i] = f
	}
	b := BBox{LatMin: v[0], LonMin: v[1], LatMax: v[2], LonMax: v[3]}
	if b.LatMin >= b.LatMax || b.LonMin >= b.LonMax {
		return BBox{}, fmt.Errorf("bbox must be lat_min,lon_min,lat_max,lon_max with min < max")
	}
	if b.LatMin < -85 || b.LatMax > 85 {
		return BBox{}, fmt.Errorf("latitude outside the Web Mercator range (-85..85)")
	}
	return b, nil
}

func outputPaths(o runOpts, p Preset) (heightPath, base string) {
	if o.out != "" {
		heightPath = o.out
		base = strings.TrimSuffix(heightPath, filepath.Ext(heightPath))
		return
	}
	base = filepath.Join(o.outDir, p.Key)
	return base + ".png", base
}

func slug(s string) string {
	s = strings.ToLower(strings.TrimSpace(s))
	var b strings.Builder
	for _, r := range s {
		switch {
		case r >= 'a' && r <= 'z', r >= '0' && r <= '9':
			b.WriteRune(r)
		case r == ' ' || r == '-' || r == '_':
			b.WriteRune('-')
		}
	}
	if b.Len() == 0 {
		return "custom"
	}
	return b.String()
}

func defaultCacheDir() string {
	if v := os.Getenv("TERRAIN_FETCH_CACHE"); v != "" {
		return v
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ".cache/terrain-fetch"
	}
	return filepath.Join(home, ".cache", "terrain-fetch")
}

// progressPrinter redraws one line, throttled so a piped run does not fill the
// log with a line per tile.
func progressPrinter(total int) func(done, total int) {
	step := total / 20
	if step < 1 {
		step = 1
	}
	return func(done, _ int) {
		if done%step == 0 || done == total {
			fmt.Printf("\r  fetching  %d/%d tiles", done, total)
		}
	}
}

func listPresets() {
	fmt.Printf("%-13s %-16s %-15s %8s  %s\n", "KEY", "NAME", "CONTINENT", "PEAK m", "BBOX")
	for _, k := range presetKeys() {
		p := presets[k]
		fmt.Printf("%-13s %-16s %-15s %8.0f  %.2f,%.2f,%.2f,%.2f\n",
			p.Key, p.Name, p.Continent, p.PeakElevM,
			p.BBox.LatMin, p.BBox.LonMin, p.BBox.LatMax, p.BBox.LonMax)
	}
}
