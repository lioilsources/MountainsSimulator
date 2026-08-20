package main

import (
	"fmt"
	"math"
	"path/filepath"
)

// The Terrain Editor's Import refuses regions over 2^32 voxels (the classic
// 16384 x 1024 x 16384 studs at 4 studs/voxel). Full-height arenas exceed
// that, so they are also emitted as Z-axis strips, each safely under the
// limit, imported one after another into the same place.
const (
	voxelStuds        = 4.0
	importVoxelLimit  = 1 << 32
	importVoxelBudget = importVoxelLimit * 8 / 10 // headroom for rounding
	// stripOverlapPx re-imports a little of the neighbouring strip so the
	// second import overwrites the smoothed edge the first one left behind —
	// without it every boundary shows as a seam groove.
	stripOverlapPx = 16
)

// Strip is one importable slice of an arena, rows [Row0, Row1) of the full
// heightmap. Size and position are ready for the Import dialog.
type Strip struct {
	Heightmap  string     `json:"heightmap"`
	Colormap   string     `json:"colormap,omitempty"`
	Row0       int        `json:"row0"`
	Row1       int        `json:"row1"`
	SizeStuds  [3]float64 `json:"size_studs"`
	PosStuds   [3]float64 `json:"position_studs"`
	VoxelCount int64      `json:"voxels"`
}

func regionVoxels(size [3]float64) int64 {
	return int64(math.Ceil(size[0]/voxelStuds)) *
		int64(math.Ceil(size[1]/voxelStuds)) *
		int64(math.Ceil(size[2]/voxelStuds))
}

// planStrips slices the arena into as few strips as fit the import budget.
// Returns nil when the whole region already fits.
func planStrips(rbx RobloxMeta, heightPx int) []Strip {
	total := regionVoxels(rbx.RegionSizeStuds)
	if total <= importVoxelBudget {
		return nil
	}

	xVox := int64(math.Ceil(rbx.RegionSizeStuds[0] / voxelStuds))
	yVox := int64(math.Ceil(rbx.RegionSizeStuds[1] / voxelStuds))
	zVoxMax := importVoxelBudget / (xVox * yVox)
	if zVoxMax < 1 {
		return nil // cannot be sliced along Z alone; caller reports it
	}
	studsPerRow := rbx.RegionSizeStuds[2] / float64(heightPx)
	rowsMax := int(float64(zVoxMax) * voxelStuds / studsPerRow)
	n := (heightPx + rowsMax - 1) / rowsMax
	rows := (heightPx + n - 1) / n

	strips := make([]Strip, 0, n)
	for k := 0; k < n; k++ {
		r0 := k*rows - stripOverlapPx
		r1 := (k+1)*rows + stripOverlapPx
		if r0 < 0 {
			r0 = 0
		}
		if r1 > heightPx {
			r1 = heightPx
		}
		sizeZ := float64(r1-r0) * studsPerRow
		centerZ := (float64(r0+r1)/2/float64(heightPx) - 0.5) * rbx.RegionSizeStuds[2]
		s := Strip{
			Row0: r0, Row1: r1,
			SizeStuds: [3]float64{rbx.RegionSizeStuds[0], rbx.RegionSizeStuds[1], round1(sizeZ)},
			PosStuds:  [3]float64{rbx.RegionPositionStuds[0], rbx.RegionPositionStuds[1], round1(centerZ)},
		}
		s.VoxelCount = regionVoxels(s.SizeStuds)
		strips = append(strips, s)
	}
	return strips
}

// sliceRows copies rows [r0, r1) into a new grid.
func sliceRows(g *Grid, r0, r1 int) *Grid {
	out := newGrid(g.W, r1-r0)
	copy(out.Data, g.Data[r0*g.W:r1*g.W])
	return out
}

// writeStrips emits per-strip heightmaps and colormaps next to the full ones.
// Every strip shares the full arena's normalisation (min..max), so the level
// values line up exactly with the single-file heightmap.
func writeStrips(base string, g *Grid, strips []Strip, paletteName string, metersPerPx float64, min, max float32, withColormap bool) error {
	for i := range strips {
		s := &strips[i]
		part := sliceRows(g, s.Row0, s.Row1)
		hPath := fmt.Sprintf("%s-s%d.png", base, i+1)
		if err := writeHeightmap(hPath, part, min, max); err != nil {
			return err
		}
		s.Heightmap = filepath.Base(hPath)
		if withColormap {
			cPath := fmt.Sprintf("%s-s%d-colormap.png", base, i+1)
			if _, err := writeColormap(cPath, part, paletteName, metersPerPx); err != nil {
				return err
			}
			s.Colormap = filepath.Base(cPath)
		}
	}
	return nil
}
