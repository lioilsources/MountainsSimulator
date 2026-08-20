package main

import (
	"encoding/json"
	"image"
	"image/color"
	"image/png"
	"math"
	"os"
)

// Sidecar travels next to the heightmap and carries everything the Roblox
// import needs that a greyscale PNG cannot express — above all the elevation
// range the 0..65535 levels were normalised against.
type Sidecar struct {
	Name          string     `json:"name"`
	Continent     string     `json:"continent"`
	Peak          string     `json:"peak,omitempty"`
	PeakElevM     float64    `json:"peak_elevation_m,omitempty"`
	BBox          [4]float64 `json:"bbox"`
	Zoom          int        `json:"zoom"`
	MinElevationM float64    `json:"min_elevation_m"`
	MaxElevationM float64    `json:"max_elevation_m"`
	ReliefM       float64    `json:"relief_m"`
	WidthPx       int        `json:"width_px"`
	HeightPx      int        `json:"height_px"`
	MetersPerPx   float64    `json:"meters_per_pixel"`
	WidthM        float64    `json:"width_m"`
	HeightM       float64    `json:"height_m"`
	Heightmap     string     `json:"heightmap"`
	Colormap      string     `json:"colormap,omitempty"`
	// ColormapMaterials lists what the colormap painted, with the exact RGBs
	// the Terrain Editor must match against Terrain.MaterialColors.
	ColormapMaterials []MaterialUse `json:"colormap_materials,omitempty"`
	POIs              []SidecarPOI  `json:"pois,omitempty"`
	Map               *MapGrid      `json:"map,omitempty"`
	Roblox            RobloxMeta    `json:"roblox"`
	Source            string        `json:"source"`
	Attribution       string        `json:"attribution"`
	Generator         string        `json:"generator"`
}

// RobloxMeta holds the import constants, versioned with the heightmap so a
// regenerated arena cannot drift from the scale it was calibrated at.
type RobloxMeta struct {
	// RegionSizeStuds is what the Terrain Editor's Import dialog wants,
	// as X (west-east), Y (up), Z (north-south).
	RegionSizeStuds     [3]float64 `json:"region_size_studs"`
	RegionPositionStuds [3]float64 `json:"region_position_studs"`
	StudsPerMeterXZ     float64    `json:"studs_per_meter_xz"`
	StudsPerMeterY      float64    `json:"studs_per_meter_y"`
	TerrainHeightStuds  float64    `json:"terrain_height_studs"`
	// VerticalExaggeration is the vertical scale over the horizontal one.
	// 1.0 renders the mountain at true proportions; below 1.0 flattens it.
	VerticalExaggeration float64 `json:"vertical_exaggeration"`
	MetersPerLevel       float64 `json:"meters_per_level"`
	StudsPerLevel        float64 `json:"studs_per_level"`
	BaseElevationM       float64 `json:"base_elevation_m"`
	PlaceID              int64   `json:"place_id"`
}

// writeHeightmap normalises the grid's relief onto 0..65535 and writes a
// 16-bit greyscale PNG, the format the Terrain Editor imports.
func writeHeightmap(path string, g *Grid, min, max float32) error {
	img := image.NewGray16(image.Rect(0, 0, g.W, g.H))
	span := float64(max - min)
	for y := 0; y < g.H; y++ {
		for x := 0; x < g.W; x++ {
			var level uint16
			if span > 0 {
				n := (float64(g.at(x, y)) - float64(min)) / span
				level = uint16(math.Round(math.Max(0, math.Min(1, n)) * 65535))
			}
			img.SetGray16(x, y, color.Gray16{Y: level})
		}
	}
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	defer f.Close()
	enc := png.Encoder{CompressionLevel: png.BestCompression}
	return enc.Encode(f, img)
}

func writeSidecar(path string, s Sidecar) error {
	b, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		return err
	}
	b = append(b, '\n')
	return os.WriteFile(path, b, 0o644)
}

// buildRobloxMeta derives the in-game scale. The arena's width in studs is the
// free parameter; everything else follows from it and the vertical constant.
func buildRobloxMeta(widthM, heightM, minElev, reliefM, studsPerMeterY, arenaStuds float64, placeID int64) RobloxMeta {
	studsPerMeterXZ := arenaStuds / widthM
	sizeZ := heightM * studsPerMeterXZ
	terrainHeight := reliefM * studsPerMeterY

	return RobloxMeta{
		RegionSizeStuds:      [3]float64{round1(arenaStuds), round1(terrainHeight), round1(sizeZ)},
		RegionPositionStuds:  [3]float64{0, round1(terrainHeight / 2), 0},
		StudsPerMeterXZ:      round4(studsPerMeterXZ),
		StudsPerMeterY:       studsPerMeterY,
		TerrainHeightStuds:   round1(terrainHeight),
		VerticalExaggeration: round4(studsPerMeterY / studsPerMeterXZ),
		MetersPerLevel:       round4(reliefM / 65535),
		StudsPerLevel:        round4(terrainHeight / 65535),
		BaseElevationM:       round1(minElev),
		PlaceID:              placeID,
	}
}

func round1(v float64) float64 { return math.Round(v*10) / 10 }
func round4(v float64) float64 { return math.Round(v*10000) / 10000 }
