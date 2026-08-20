package main

import (
	"image"
	"image/color"
	"image/png"
	"math"
	"os"
)

// writePreview renders a hillshaded, material-tinted view of the crop. It is
// never imported into Studio — it exists so a preset can be judged (is the
// peak in frame? is the relief interesting?) without a round trip through the
// Terrain Editor.
func writePreview(path string, g *Grid, paletteName string, metersPerPx float64, maxEdge int) error {
	pw, ph := fitSize(g.W, g.H, maxEdge)
	// Shade at full resolution, then downscale, so fine ridges survive.
	shade := hillshade(g, metersPerPx, 315, 45)

	p, hasPalette := palettes[paletteName]
	steepSlope := math.Tan(p.SteepDeg * math.Pi / 180)

	full := image.NewRGBA(image.Rect(0, 0, g.W, g.H))
	for y := 0; y < g.H; y++ {
		for x := 0; x < g.W; x++ {
			var base [3]uint8 = [3]uint8{190, 190, 190}
			if hasPalette {
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
				base = materialColors[mat]
			}
			s := shade[y*g.W+x]
			// Keep some ambient light so shadowed faces stay readable.
			lit := 0.25 + 0.75*s
			full.SetRGBA(x, y, color.RGBA{
				R: scaleChannel(base[0], lit),
				G: scaleChannel(base[1], lit),
				B: scaleChannel(base[2], lit),
				A: 255,
			})
		}
	}

	out := downscaleRGBA(full, pw, ph)
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	defer f.Close()
	enc := png.Encoder{CompressionLevel: png.BestCompression}
	return enc.Encode(f, out)
}

func scaleChannel(v uint8, k float64) uint8 {
	r := float64(v) * k
	if r < 0 {
		return 0
	}
	if r > 255 {
		return 255
	}
	return uint8(r)
}

// hillshade is the standard Horn illumination model, 0 (shadow) to 1 (lit).
func hillshade(g *Grid, metersPerPx, azimuthDeg, altitudeDeg float64) []float64 {
	zenith := (90 - altitudeDeg) * math.Pi / 180
	az := azimuthDeg * math.Pi / 180
	out := make([]float64, g.W*g.H)
	for y := 0; y < g.H; y++ {
		for x := 0; x < g.W; x++ {
			dzdx := float64(g.clampedAt(x+1, y)-g.clampedAt(x-1, y)) / (2 * metersPerPx)
			dzdy := float64(g.clampedAt(x, y+1)-g.clampedAt(x, y-1)) / (2 * metersPerPx)
			slope := math.Atan(math.Hypot(dzdx, dzdy))
			aspect := math.Atan2(dzdy, -dzdx)
			v := math.Cos(zenith)*math.Cos(slope) +
				math.Sin(zenith)*math.Sin(slope)*math.Cos(az-aspect)
			out[y*g.W+x] = math.Max(0, math.Min(1, v))
		}
	}
	return out
}

// downscaleRGBA box-filters an image down, averaging every source pixel.
func downscaleRGBA(src *image.RGBA, w, h int) *image.RGBA {
	if w == src.Bounds().Dx() && h == src.Bounds().Dy() {
		return src
	}
	sw, sh := src.Bounds().Dx(), src.Bounds().Dy()
	dst := image.NewRGBA(image.Rect(0, 0, w, h))
	for y := 0; y < h; y++ {
		y0, y1 := y*sh/h, (y+1)*sh/h
		if y1 <= y0 {
			y1 = y0 + 1
		}
		for x := 0; x < w; x++ {
			x0, x1 := x*sw/w, (x+1)*sw/w
			if x1 <= x0 {
				x1 = x0 + 1
			}
			var r, g, b, n int
			for sy := y0; sy < y1; sy++ {
				for sx := x0; sx < x1; sx++ {
					i := src.PixOffset(sx, sy)
					r += int(src.Pix[i])
					g += int(src.Pix[i+1])
					b += int(src.Pix[i+2])
					n++
				}
			}
			dst.SetRGBA(x, y, color.RGBA{uint8(r / n), uint8(g / n), uint8(b / n), 255})
		}
	}
	return dst
}
