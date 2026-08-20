package main

import (
	"image"
	"image/png"
	"os"
	"testing"
)

func openFile(t *testing.T, path string) *os.File {
	t.Helper()
	f, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { f.Close() })
	return f
}

func decodePNG(t *testing.T, path string) image.Image {
	t.Helper()
	img, err := png.Decode(openFile(t, path))
	if err != nil {
		t.Fatal(err)
	}
	return img
}
