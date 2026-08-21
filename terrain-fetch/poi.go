package main

import "math"

// POI is a named summit inside a preset's bbox, in geographic coordinates.
type POI struct {
	Name  string
	Lat   float64
	Lon   float64
	ElevM float64
	// Major marks the marquee peaks (the eight-thousanders on Everest, the
	// dominant summit elsewhere) — the game draws them gold.
	Major bool
	// Town marks settlements and saddles: no snapping to a local maximum
	// (that would drag the marker onto the nearest hill), name shown without
	// an elevation.
	Town bool
	// SnapM overrides the snap radius in metres (0 = the default). Use a
	// small value for minor summits on the flank of a bigger ridge, where
	// the default disc would climb onto the neighbour's slope.
	SnapM float64
}

// SidecarPOI is a POI projected into the arena's stud coordinates.
type SidecarPOI struct {
	Name  string  `json:"name"`
	ElevM float64 `json:"elevation_m"`
	// SnappedElevM is what the DEM actually has at the marker after snapping —
	// the gap against ElevM is the source's resolution, useful as a sanity check.
	SnappedElevM float64 `json:"snapped_elevation_m"`
	Major        bool    `json:"major"`
	Town         bool    `json:"town,omitempty"`
	XStuds       float64 `json:"x_studs"`
	YStuds       float64 `json:"y_studs"`
	ZStuds       float64 `json:"z_studs"`
}

// snapRadiusM is how far a POI may wander to the local summit. Catalog
// coordinates and the DEM disagree by up to a few hundred metres; snapping to
// the local maximum puts the marker on the peak as the terrain actually has
// it. Kept under 1 km so a marker cannot jump to a neighbouring mountain.
const snapRadiusM = 900

// projectPOIs maps each POI into the resampled grid, snaps it to the local
// summit, and converts to stud coordinates (arena centred on the origin,
// north at -Z, Y above the arena's base level).
func projectPOIs(pois []POI, b BBox, z int, g *Grid, outMPP float64, rbx RobloxMeta) []SidecarPOI {
	if len(pois) == 0 {
		return nil
	}
	x0 := lonToPixelX(b.LonMin, z)
	x1 := lonToPixelX(b.LonMax, z)
	y0 := latToPixelY(b.LatMax, z)
	y1 := latToPixelY(b.LatMin, z)

	radiusPx := int(math.Round(snapRadiusM / outMPP))
	out := make([]SidecarPOI, 0, len(pois))
	for _, p := range pois {
		fx := (lonToPixelX(p.Lon, z) - x0) / (x1 - x0)
		fy := (latToPixelY(p.Lat, z) - y0) / (y1 - y0)
		if fx < 0 || fx > 1 || fy < 0 || fy > 1 {
			continue // outside the crop; presets are tested against this
		}
		px := int(fx * float64(g.W-1))
		py := int(fy * float64(g.H-1))
		if !p.Town {
			r := radiusPx
			if p.SnapM > 0 {
				r = int(math.Round(p.SnapM / outMPP))
			}
			px, py = snapToLocalMax(g, px, py, r)
		}
		elev := float64(g.at(px, py))

		out = append(out, SidecarPOI{
			Name: p.Name, ElevM: p.ElevM, Town: p.Town,
			SnappedElevM: math.Round(elev),
			Major:        p.Major,
			XStuds:       round1((float64(px)/float64(g.W-1) - 0.5) * rbx.RegionSizeStuds[0]),
			YStuds:       round1((elev - rbx.BaseElevationM) * rbx.StudsPerMeterY),
			ZStuds:       round1((float64(py)/float64(g.H-1) - 0.5) * rbx.RegionSizeStuds[2]),
		})
	}
	return out
}

func snapToLocalMax(g *Grid, px, py, radius int) (int, int) {
	bx, by := px, py
	best := g.clampedAt(px, py)
	for dy := -radius; dy <= radius; dy++ {
		for dx := -radius; dx <= radius; dx++ {
			if dx*dx+dy*dy > radius*radius {
				continue
			}
			x, y := px+dx, py+dy
			if x < 0 || x >= g.W || y < 0 || y >= g.H {
				continue
			}
			if v := g.at(x, y); v > best {
				best, bx, by = v, x, y
			}
		}
	}
	return bx, by
}

// MapGrid is a coarse elevation raster for the in-game map, hex-encoded so it
// can be embedded in the generated Luau module (no image assets to upload —
// the whole pipeline stays offline).
type MapGrid struct {
	W    int      `json:"w"`
	H    int      `json:"h"`
	Rows []string `json:"rows"`
}

const mapMaxEdge = 64

func buildMapGrid(g *Grid, min, max float32) MapGrid {
	mw, mh := fitSize(g.W, g.H, mapMaxEdge)
	m := resample(g, mw, mh)
	span := float64(max - min)
	rows := make([]string, mh)
	const hexdigits = "0123456789abcdef"
	buf := make([]byte, mw*2)
	for y := 0; y < mh; y++ {
		for x := 0; x < mw; x++ {
			v := 0.0
			if span > 0 {
				v = (float64(m.at(x, y)) - float64(min)) / span
			}
			b := int(math.Round(math.Max(0, math.Min(1, v)) * 255))
			buf[x*2] = hexdigits[b>>4]
			buf[x*2+1] = hexdigits[b&15]
		}
		rows[y] = string(buf)
	}
	return MapGrid{W: mw, H: mh, Rows: rows}
}
