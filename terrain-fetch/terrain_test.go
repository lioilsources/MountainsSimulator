package main

import (
	"bytes"
	"image"
	"image/color"
	"image/png"
	"math"
	"strconv"
	"testing"
)

func TestPixelMathAtOrigin(t *testing.T) {
	// Null Island sits exactly at the centre of the Mercator grid.
	for z := 0; z <= 14; z++ {
		half := math.Exp2(float64(z)) * tileSize / 2
		if got := lonToPixelX(0, z); math.Abs(got-half) > 1e-6 {
			t.Errorf("z=%d lonToPixelX(0) = %v, want %v", z, got, half)
		}
		if got := latToPixelY(0, z); math.Abs(got-half) > 1e-6 {
			t.Errorf("z=%d latToPixelY(0) = %v, want %v", z, got, half)
		}
	}
}

func TestMetersPerPixelEquator(t *testing.T) {
	// The classic figure: 156543.03 m/px at zoom 0 on the equator.
	if got := metersPerPixel(0, 0); math.Abs(got-156543.03) > 0.01 {
		t.Errorf("metersPerPixel(0,0) = %v, want ~156543.03", got)
	}
	// Every zoom level halves it.
	for z := 1; z <= 15; z++ {
		want := 156543.03392804097 / math.Exp2(float64(z))
		if got := metersPerPixel(0, z); math.Abs(got-want) > 1e-6 {
			t.Errorf("z=%d: got %v, want %v", z, got, want)
		}
	}
}

func TestTilesForEverest(t *testing.T) {
	// Everest summit: 27.9881 N, 86.9250 E. Tile 12/3037/1716 is the one that
	// actually holds it — checked against the live tile, which peaks at 8748 m
	// on a coarse sample while its southern neighbour is 100 m lowland.
	b := BBox{LatMin: 27.9880, LonMin: 86.9249, LatMax: 27.9882, LonMax: 86.9251}
	r := tilesFor(b, 12)
	if r.X0 != 3037 || r.Y0 != 1716 {
		t.Errorf("got tile %d/%d, want 3037/1716", r.X0, r.Y0)
	}
	if r.count() != 1 {
		t.Errorf("a summit-sized bbox spans %d tiles, want 1", r.count())
	}
}

func TestTileRangeCoversBBox(t *testing.T) {
	p := presets["montblanc"]
	r := tilesFor(p.BBox, 12)
	// Every corner of the bbox must fall inside the fetched block.
	px0, px1 := lonToPixelX(p.BBox.LonMin, 12), lonToPixelX(p.BBox.LonMax, 12)
	py0, py1 := latToPixelY(p.BBox.LatMax, 12), latToPixelY(p.BBox.LatMin, 12)
	if px0 < float64(r.X0*tileSize) || px1 > float64((r.X1+1)*tileSize) {
		t.Errorf("x range %v..%v outside tiles %d..%d", px0, px1, r.X0, r.X1)
	}
	if py0 < float64(r.Y0*tileSize) || py1 > float64((r.Y1+1)*tileSize) {
		t.Errorf("y range %v..%v outside tiles %d..%d", py0, py1, r.Y0, r.Y1)
	}
}

// makeTerrariumPNG builds a tile whose every pixel encodes the same height.
func makeTerrariumPNG(t *testing.T, r, g, b uint8) []byte {
	t.Helper()
	img := image.NewNRGBA(image.Rect(0, 0, tileSize, tileSize))
	for y := 0; y < tileSize; y++ {
		for x := 0; x < tileSize; x++ {
			img.SetNRGBA(x, y, color.NRGBA{R: r, G: g, B: b, A: 255})
		}
	}
	var buf bytes.Buffer
	if err := png.Encode(&buf, img); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

func TestDecodeTerrarium(t *testing.T) {
	cases := []struct {
		r, g, b uint8
		want    float64
	}{
		{128, 0, 0, 0},               // the encoding's zero point
		{128, 0, 128, 0.5},           // blue channel is 1/256 m
		{162, 145, 0, 8849},          // Everest
		{127, 255, 255, -0.00390625}, // just below sea level
		{0, 0, 0, -32768},            // floor
	}
	for _, c := range cases {
		g, err := decodeTerrarium(makeTerrariumPNG(t, c.r, c.g, c.b))
		if err != nil {
			t.Fatal(err)
		}
		if got := float64(g.at(7, 11)); math.Abs(got-c.want) > 1e-4 {
			t.Errorf("decode(%d,%d,%d) = %v, want %v", c.r, c.g, c.b, got, c.want)
		}
	}
}

func TestMosaicPlacesTilesByPosition(t *testing.T) {
	r := tileRange{Z: 12, X0: 10, Y0: 20, X1: 11, Y1: 20}
	tiles := []tile{
		// Deliberately out of order: the mosaic must place by X/Y, not by index.
		{X: 11, Y: 20, PNG: makeTerrariumPNG(t, 133, 0, 0)}, // 1280 m
		{X: 10, Y: 20, PNG: makeTerrariumPNG(t, 130, 0, 0)}, // 512 m
	}
	m, err := mosaic(tiles, r)
	if err != nil {
		t.Fatal(err)
	}
	if m.W != 512 || m.H != 256 {
		t.Fatalf("mosaic is %dx%d, want 512x256", m.W, m.H)
	}
	if got := m.at(5, 5); math.Abs(float64(got)-512) > 1e-3 {
		t.Errorf("left tile = %v, want 512", got)
	}
	if got := m.at(300, 5); math.Abs(float64(got)-1280) > 1e-3 {
		t.Errorf("right tile = %v, want 1280", got)
	}
}

func TestResampleKeepsConstantField(t *testing.T) {
	g := newGrid(64, 64)
	for i := range g.Data {
		g.Data[i] = 1234.5
	}
	for _, size := range []int{16, 64, 200} {
		out := resample(g, size, size)
		for _, v := range out.Data {
			if math.Abs(float64(v)-1234.5) > 1e-2 {
				t.Fatalf("resample to %d: got %v, want 1234.5", size, v)
			}
		}
	}
}

func TestResampleKeepsLinearRamp(t *testing.T) {
	// A ramp is the case an anti-aliasing filter must not distort: the mean of
	// a linear function equals its value at the centre of the window.
	const n = 128
	g := newGrid(n, n)
	for y := 0; y < n; y++ {
		for x := 0; x < n; x++ {
			g.Data[y*n+x] = float32(x) * 10
		}
	}
	for _, size := range []int{32, 256} {
		out := resample(g, size, size)
		scale := float64(size) / float64(n)
		// Skip the border, where edge clamping legitimately bends the ramp.
		for x := 4; x < size-4; x++ {
			srcX := (float64(x)+0.5)/scale - 0.5
			want := srcX * 10
			if got := float64(out.at(x, size/2)); math.Abs(got-want) > 0.5 {
				t.Fatalf("resample to %d at x=%d: got %v, want %v", size, x, got, want)
			}
		}
	}
}

func TestResampleDownscaleAveragesInsteadOfPointSampling(t *testing.T) {
	// Alternating spikes: point sampling would return the spike value (or the
	// floor); a proper filter returns something near the mean.
	const n = 64
	g := newGrid(n, n)
	for y := 0; y < n; y++ {
		for x := 0; x < n; x++ {
			if x%2 == 0 {
				g.Data[y*n+x] = 1000
			}
		}
	}
	out := resample(g, 8, 8)
	for x := 1; x < 7; x++ {
		v := float64(out.at(x, 4))
		if v < 300 || v > 700 {
			t.Fatalf("downscaled spike field at x=%d = %v, want near the 500 mean", x, v)
		}
	}
}

func TestFitSize(t *testing.T) {
	cases := []struct{ w, h, max, wantW, wantH int }{
		{1000, 500, 0, 1000, 500},    // no cap
		{1000, 500, 4096, 1000, 500}, // already inside
		{8192, 4096, 4096, 4096, 2048},
		{4096, 8192, 4096, 2048, 4096}, // portrait caps on height
	}
	for _, c := range cases {
		w, h := fitSize(c.w, c.h, c.max)
		if w != c.wantW || h != c.wantH {
			t.Errorf("fitSize(%d,%d,%d) = %d,%d want %d,%d", c.w, c.h, c.max, w, h, c.wantW, c.wantH)
		}
	}
}

func TestCropMatchesBBoxSize(t *testing.T) {
	b := presets["beskydy"].BBox
	z := 12
	r := tilesFor(b, z)
	m := newGrid((r.X1-r.X0+1)*tileSize, (r.Y1-r.Y0+1)*tileSize)
	for i := range m.Data {
		m.Data[i] = float32(i % 100)
	}
	c, err := crop(m, b, r)
	if err != nil {
		t.Fatal(err)
	}
	wantW, wantH := nativeSize(b, z)
	if c.W != wantW || c.H != wantH {
		t.Errorf("crop is %dx%d, want the native %dx%d", c.W, c.H, wantW, wantH)
	}
}

func TestHeightmapSpansFullRange(t *testing.T) {
	g := newGrid(4, 4)
	for i := range g.Data {
		g.Data[i] = float32(300 + i*10) // 300..450
	}
	min, max := g.minMax()
	path := t.TempDir() + "/h.png"
	if err := writeHeightmap(path, g, min, max); err != nil {
		t.Fatal(err)
	}
	img := decodePNG(t, path)
	if _, ok := img.(*image.Gray16); !ok {
		t.Fatalf("heightmap is %T, want *image.Gray16 — the Terrain importer needs 16-bit", img)
	}
	lo := img.(*image.Gray16).Gray16At(0, 0).Y
	hi := img.(*image.Gray16).Gray16At(3, 3).Y
	if lo != 0 {
		t.Errorf("minimum elevation encoded as %d, want 0", lo)
	}
	if hi != 65535 {
		t.Errorf("maximum elevation encoded as %d, want 65535", hi)
	}
}

func TestRobloxMetaScales(t *testing.T) {
	// A 40 km crop with 4000 m of relief, 16384 studs wide, 0.12 studs/m up.
	m := buildRobloxMeta(40000, 30000, 800, 4000, 0.12, 16384, 0)
	if math.Abs(m.StudsPerMeterXZ-0.4096) > 1e-4 {
		t.Errorf("horizontal scale = %v, want 0.4096", m.StudsPerMeterXZ)
	}
	if math.Abs(m.TerrainHeightStuds-480) > 0.1 {
		t.Errorf("terrain height = %v studs, want 480", m.TerrainHeightStuds)
	}
	if math.Abs(m.RegionSizeStuds[2]-12288) > 0.1 {
		t.Errorf("Z size = %v, want 12288 (aspect preserved)", m.RegionSizeStuds[2])
	}
	// The region is centred, so black sits at Y=0 and white at the summit.
	if math.Abs(m.RegionPositionStuds[1]-240) > 0.1 {
		t.Errorf("region centre Y = %v, want half the height", m.RegionPositionStuds[1])
	}
	if math.Abs(m.VerticalExaggeration-0.293) > 0.01 {
		t.Errorf("exaggeration = %v, want ~0.29", m.VerticalExaggeration)
	}
}

func TestColormapUsesExactMaterialColors(t *testing.T) {
	g := newGrid(32, 32)
	for y := 0; y < 32; y++ {
		for x := 0; x < 32; x++ {
			g.Data[y*32+x] = float32(y) * 200 // 0..6200 m
		}
	}
	path := t.TempDir() + "/c.png"
	used, err := writeColormap(path, g, "alpine", 30)
	if err != nil {
		t.Fatal(err)
	}
	img := decodePNG(t, path)
	// Every pixel must be one of the palette's exact RGBs; a blended colour
	// would snap to some unrelated material on import.
	valid := map[[3]uint32]bool{}
	for _, c := range materialColors {
		valid[[3]uint32{uint32(c[0]), uint32(c[1]), uint32(c[2])}] = true
	}
	for y := 0; y < 32; y++ {
		for x := 0; x < 32; x++ {
			r, gg, b, _ := img.At(x, y).RGBA()
			key := [3]uint32{r >> 8, gg >> 8, b >> 8}
			if !valid[key] {
				t.Fatalf("pixel %d,%d is %v — not an exact material colour", x, y, key)
			}
		}
	}
	total := 0.0
	for _, u := range used {
		total += u.Percent
	}
	if math.Abs(total-100) > 0.5 {
		t.Errorf("material percentages sum to %v, want 100", total)
	}
}

func TestParseBBoxRejectsBadInput(t *testing.T) {
	bad := []string{
		"1,2,3", "a,b,c,d", "",
		"46.0,6.6,45.7,7.1", // lat_max below lat_min
		"45.7,7.1,46.0,6.6", // lon_max below lon_min
		"-89,6.6,-86,7.1",   // outside Mercator
	}
	for _, s := range bad {
		if _, err := parseBBox(s); err == nil {
			t.Errorf("parseBBox(%q) accepted bad input", s)
		}
	}
	b, err := parseBBox(" 45.70, 6.60, 46.05, 7.10 ")
	if err != nil {
		t.Fatal(err)
	}
	if b != (BBox{LatMin: 45.70, LonMin: 6.60, LatMax: 46.05, LonMax: 7.10}) {
		t.Errorf("parsed %v", b)
	}
}

func TestEveryPresetIsSane(t *testing.T) {
	for _, k := range presetKeys() {
		p := presets[k]
		if _, ok := palettes[p.Palette]; !ok {
			t.Errorf("%s: palette %q is not defined", k, p.Palette)
		}
		if p.StudsPerMeterY <= 0 {
			t.Errorf("%s: vertical scale must be positive", k)
		}
		w, h := nativeSize(p.BBox, p.Zoom)
		if w < 256 || h < 256 {
			t.Errorf("%s: native size %dx%d px is too small to be worth importing", k, w, h)
		}
		if w > 4096 || h > 4096 {
			t.Errorf("%s: native size %dx%d px exceeds the importer's 4096 limit", k, w, h)
		}
		km, _ := p.BBox.groundSize(p.Zoom)
		if km/1000 < 20 || km/1000 > 60 {
			t.Errorf("%s: crop is %.1f km wide, outside the planned 30-50 km", k, km/1000)
		}
	}
}

func TestPOISnapAndProjection(t *testing.T) {
	// A 200x100 grid with one sharp summit off-centre.
	g := newGrid(200, 100)
	sx, sy := 130, 40
	for y := 0; y < 100; y++ {
		for x := 0; x < 200; x++ {
			d := math.Hypot(float64(x-sx), float64(y-sy))
			g.Data[y*200+x] = float32(2000 - d*10)
		}
	}
	b := BBox{LatMin: 45.0, LonMin: 6.0, LatMax: 45.5, LonMax: 7.0}
	rbx := buildRobloxMeta(40000, 20000, 800, 1200, 0.68, 16384, 0)
	rbx.BaseElevationM = float64(g.Data[0]) // not used for min here; set explicitly
	min, _ := g.minMax()
	rbx.BaseElevationM = round1(float64(min))

	// Catalog coordinates deliberately ~6 px off the true summit.
	lonAt := func(px int) float64 { return 6.0 + float64(px)/199.0 }
	latAt := func(py int) float64 { return 45.5 - 0.5*float64(py)/99.0 }
	pois := projectPOIs([]POI{
		{Name: "Summit", Lat: latAt(sy + 4), Lon: lonAt(sx - 5), ElevM: 2000, Major: true},
		{Name: "Outside", Lat: 50, Lon: 20, ElevM: 1},
	}, b, 12, g, 30, rbx)

	if len(pois) != 1 {
		t.Fatalf("got %d POIs, want 1 (outside one dropped)", len(pois))
	}
	p := pois[0]
	if p.SnappedElevM != 2000 {
		t.Errorf("snap missed the summit: elevation %v, want 2000", p.SnappedElevM)
	}
	wantX := (float64(sx)/199.0 - 0.5) * rbx.RegionSizeStuds[0]
	wantZ := (float64(sy)/99.0 - 0.5) * rbx.RegionSizeStuds[2]
	if math.Abs(p.XStuds-wantX) > 1 || math.Abs(p.ZStuds-wantZ) > 1 {
		t.Errorf("projected to (%v, %v), want (%v, %v)", p.XStuds, p.ZStuds, wantX, wantZ)
	}
	if math.Abs(p.YStuds-(2000-float64(min))*0.68) > 1 {
		t.Errorf("YStuds = %v", p.YStuds)
	}
}

func TestPresetPOIsInsideBBox(t *testing.T) {
	for _, k := range presetKeys() {
		p := presets[k]
		for _, poi := range p.POIs {
			if poi.Lat < p.BBox.LatMin || poi.Lat > p.BBox.LatMax ||
				poi.Lon < p.BBox.LonMin || poi.Lon > p.BBox.LonMax {
				t.Errorf("%s: POI %q (%v, %v) is outside the bbox", k, poi.Name, poi.Lat, poi.Lon)
			}
		}
		if len(p.POIs) == 0 {
			t.Errorf("%s: no POIs — the map would be empty", k)
		}
	}
}

func TestMapGridEncoding(t *testing.T) {
	g := newGrid(128, 64)
	for y := 0; y < 64; y++ {
		for x := 0; x < 128; x++ {
			g.Data[y*128+x] = float32(x) // ramp west->east
		}
	}
	min, max := g.minMax()
	m := buildMapGrid(g, min, max)
	if m.W != 64 || m.H != 32 {
		t.Fatalf("map is %dx%d, want 64x32", m.W, m.H)
	}
	for _, row := range m.Rows {
		if len(row) != m.W*2 {
			t.Fatalf("row length %d, want %d", len(row), m.W*2)
		}
	}
	// The ramp must decode back: west edge dark, east edge bright. The
	// downscale averages neighbouring pixels, so allow it a few levels.
	hex := func(s string) int64 { v, _ := strconv.ParseInt(s, 16, 32); return v }
	first := hex(m.Rows[16][:2])
	last := hex(m.Rows[16][len(m.Rows[16])-2:])
	if first > 4 {
		t.Errorf("west edge = %d, want near 0", first)
	}
	if last < 251 {
		t.Errorf("east edge = %d, want near 255", last)
	}
}
