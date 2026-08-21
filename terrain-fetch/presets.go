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
	// POIs are the named summits shown on the in-game map and compass.
	// Coordinates are catalog values; the tool snaps each to the local summit
	// of the DEM, so a few hundred metres of imprecision is fine.
	POIs []POI
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
		POIs: []POI{
			{Name: "Mont Blanc", Lat: 45.8326, Lon: 6.8652, ElevM: 4810, Major: true},
			{Name: "Grandes Jorasses", Lat: 45.8686, Lon: 6.9860, ElevM: 4208},
			{Name: "Aiguille Verte", Lat: 45.9349, Lon: 6.9697, ElevM: 4122},
			{Name: "Dent du Geant", Lat: 45.8622, Lon: 6.9519, ElevM: 4013},
			{Name: "Aiguille du Midi", Lat: 45.8790, Lon: 6.8873, ElevM: 3842},
		},
	},
	"everest": {
		Key: "everest", Name: "Everest", Continent: "Asia",
		Peak: "Mount Everest", PeakElevM: 8849,
		BBox:           BBox{LatMin: 27.80, LonMin: 86.60, LatMax: 28.10, LonMax: 87.10},
		Zoom:           12,
		StudsPerMeterY: verticalStudsPerMeter, Palette: "himalaya",
		// The crop holds four of the fourteen eight-thousanders; Cho Oyu and
		// Makalu sit right at its edges. (K2 is in the Karakoram — a range of
		// its own, and a natural future preset.)
		POIs: []POI{
			{Name: "Everest", Lat: 27.9881, Lon: 86.9250, ElevM: 8849, Major: true},
			{Name: "Lhotse", Lat: 27.9626, Lon: 86.9336, ElevM: 8516, Major: true},
			{Name: "Makalu", Lat: 27.8897, Lon: 87.0888, ElevM: 8485, Major: true},
			{Name: "Cho Oyu", Lat: 28.0942, Lon: 86.6608, ElevM: 8188, Major: true},
			{Name: "Nuptse", Lat: 27.9668, Lon: 86.8880, ElevM: 7861},
			{Name: "Pumori", Lat: 28.0147, Lon: 86.8281, ElevM: 7161},
			{Name: "Ama Dablam", Lat: 27.8617, Lon: 86.8614, ElevM: 6812},
		},
	},
	"kilimanjaro": {
		Key: "kilimanjaro", Name: "Kilimanjaro", Continent: "Africa",
		Peak: "Uhuru Peak", PeakElevM: 5895,
		BBox:           BBox{LatMin: -3.25, LonMin: 37.20, LatMax: -2.95, LonMax: 37.55},
		Zoom:           12,
		StudsPerMeterY: verticalStudsPerMeter, Palette: "savanna",
		POIs: []POI{
			{Name: "Uhuru Peak", Lat: -3.0674, Lon: 37.3556, ElevM: 5895, Major: true},
			{Name: "Mawenzi", Lat: -3.0968, Lon: 37.4551, ElevM: 5149},
			{Name: "Shira", Lat: -3.0396, Lon: 37.2438, ElevM: 3962},
		},
	},
	"aconcagua": {
		Key: "aconcagua", Name: "Aconcagua", Continent: "South America",
		Peak: "Aconcagua", PeakElevM: 6961,
		BBox:           BBox{LatMin: -33.00, LonMin: -70.20, LatMax: -32.50, LonMax: -69.70},
		Zoom:           12,
		StudsPerMeterY: verticalStudsPerMeter, Palette: "andes",
		POIs: []POI{
			{Name: "Aconcagua", Lat: -32.6532, Lon: -70.0109, ElevM: 6961, Major: true},
			{Name: "Cerro Ameghino", Lat: -32.6360, Lon: -69.9760, ElevM: 5940},
			{Name: "Cerro Cuerno", Lat: -32.6650, Lon: -70.0550, ElevM: 5462},
		},
	},
	"longspeak": {
		Key: "longspeak", Name: "Rocky Mountains", Continent: "North America",
		Peak: "Longs Peak", PeakElevM: 4346,
		BBox:           BBox{LatMin: 40.10, LonMin: -105.80, LatMax: 40.45, LonMax: -105.40},
		Zoom:           12,
		StudsPerMeterY: verticalStudsPerMeter, Palette: "rockies",
		POIs: []POI{
			{Name: "Longs Peak", Lat: 40.2549, Lon: -105.6160, ElevM: 4346, Major: true},
			{Name: "Mount Meeker", Lat: 40.2481, Lon: -105.6047, ElevM: 4241},
			{Name: "Hallett Peak", Lat: 40.3049, Lon: -105.6808, ElevM: 3875},
		},
	},
	// Test preset: small relief, few tiles, fast iteration. Not one of the five.
	"beskydy": {
		Key: "beskydy", Name: "Beskydy", Continent: "Europe",
		Peak: "Lysa hora", PeakElevM: 1323,
		// Rozsireno na zapad (2026-08-21): Roznovska brazda s Valasskym
		// Mezirici a Roznovem, Radhost, Verovicke vrchy, Frenstat, Koprivnice.
		BBox:           BBox{LatMin: 49.35, LonMin: 17.94, LatMax: 49.65, LonMax: 18.75},
		Zoom:           12,
		StudsPerMeterY: verticalStudsPerMeter, Palette: "alpine",
		// Souradnice vrcholu i sidel overene proti OSM/Nominatim (bounded
		// query v bboxu, 2026-08-21).
		POIs: []POI{
			{Name: "Lysa hora", Lat: 49.5461, Lon: 18.4475, ElevM: 1323, Major: true},
			{Name: "Smrk", Lat: 49.4993, Lon: 18.3730, ElevM: 1276},
			{Name: "Travny", Lat: 49.5616, Lon: 18.5070, ElevM: 1203},
			{Name: "Radhost", Lat: 49.4916, Lon: 18.2231, ElevM: 1129},
			{Name: "Velky Javornik", Lat: 49.5272, Lon: 18.1608, ElevM: 918},
			{Name: "Cerna hora", Lat: 49.4783, Lon: 18.1971, ElevM: 886, SnapM: 250},
			{Name: "Pindula", Lat: 49.4991, Lon: 18.1856, ElevM: 560, Town: true},
			{Name: "Roznov p. R.", Lat: 49.4588, Lon: 18.1430, ElevM: 378, Town: true},
			{Name: "Valasske Mezirici", Lat: 49.4716, Lon: 17.9716, ElevM: 294, Town: true},
			{Name: "Frenstat p. R.", Lat: 49.5474, Lon: 18.2117, ElevM: 400, Town: true},
			{Name: "Koprivnice", Lat: 49.5989, Lon: 18.1452, ElevM: 320, Town: true},
		},
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
