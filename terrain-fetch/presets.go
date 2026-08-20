package main

import (
	"fmt"
	"sort"
	"strings"
)

// Preset is one playable arena: a bbox around an iconic peak plus the
// game-side constants the Roblox import needs. See TERRAIN_PLAN.md.
type Preset struct {
	Key       string
	Name      string
	Continent string
	Peak      string
	PeakElevM float64
	BBox      BBox
	Zoom      int
	// StudsPerMeterY scales relief above the base level. One shared constant
	// across every arena (rozhodnuti 2026-08-20): the plan's "every arena
	// ~450 studs tall" rule made mountains read as plains, so it was dropped
	// in favour of monumentality — and with the constant shared, the relative
	// heights of the ranges stay true (Everest really towers over Longs Peak).
	// 0.68 is the "filmovy" cut from the Mont Blanc cross-section study:
	// ~1.6x vertical exaggeration over that arena's horizontal scale.
	StudsPerMeterY float64
	// Palette selects the colormap ramp (see colormap.go).
	Palette string
	// PlaceID is this arena's published Roblox Place, 0 until it exists. It
	// travels through the sidecar into Mountains.lua so the generated module
	// never has to be hand-edited.
	PlaceID int64
}

// verticalStudsPerMeter is the shared vertical scale — see StudsPerMeterY.
const verticalStudsPerMeter = 0.68

var presets = map[string]Preset{
	"montblanc": {
		Key: "montblanc", Name: "Mont Blanc", Continent: "Europe",
		Peak: "Mont Blanc", PeakElevM: 4810,
		BBox:           BBox{LatMin: 45.70, LonMin: 6.60, LatMax: 46.05, LonMax: 7.10},
		Zoom:           12,
		StudsPerMeterY: verticalStudsPerMeter, Palette: "alpine",
	},
	"everest": {
		Key: "everest", Name: "Everest", Continent: "Asia",
		Peak: "Mount Everest", PeakElevM: 8849,
		BBox:           BBox{LatMin: 27.80, LonMin: 86.60, LatMax: 28.10, LonMax: 87.10},
		Zoom:           12,
		StudsPerMeterY: verticalStudsPerMeter, Palette: "himalaya",
	},
	"kilimanjaro": {
		Key: "kilimanjaro", Name: "Kilimanjaro", Continent: "Africa",
		Peak: "Uhuru Peak", PeakElevM: 5895,
		BBox:           BBox{LatMin: -3.25, LonMin: 37.20, LatMax: -2.95, LonMax: 37.55},
		Zoom:           12,
		StudsPerMeterY: verticalStudsPerMeter, Palette: "savanna",
	},
	"aconcagua": {
		Key: "aconcagua", Name: "Aconcagua", Continent: "South America",
		Peak: "Aconcagua", PeakElevM: 6961,
		BBox:           BBox{LatMin: -33.00, LonMin: -70.20, LatMax: -32.50, LonMax: -69.70},
		Zoom:           12,
		StudsPerMeterY: verticalStudsPerMeter, Palette: "andes",
	},
	"longspeak": {
		Key: "longspeak", Name: "Rocky Mountains", Continent: "North America",
		Peak: "Longs Peak", PeakElevM: 4346,
		BBox:           BBox{LatMin: 40.10, LonMin: -105.80, LatMax: 40.45, LonMax: -105.40},
		Zoom:           12,
		StudsPerMeterY: verticalStudsPerMeter, Palette: "rockies",
	},
	// Test preset: small relief, few tiles, fast iteration. Not one of the five.
	"beskydy": {
		Key: "beskydy", Name: "Beskydy", Continent: "Europe",
		Peak: "Lysa hora", PeakElevM: 1323,
		BBox:           BBox{LatMin: 49.35, LonMin: 18.20, LatMax: 49.65, LonMax: 18.75},
		Zoom:           12,
		StudsPerMeterY: verticalStudsPerMeter, Palette: "alpine",
	},
}

func presetKeys() []string {
	keys := make([]string, 0, len(presets))
	for k := range presets {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

func lookupPreset(key string) (Preset, error) {
	p, ok := presets[strings.ToLower(key)]
	if !ok {
		return Preset{}, fmt.Errorf("unknown preset %q (have: %s)", key, strings.Join(presetKeys(), ", "))
	}
	return p, nil
}
