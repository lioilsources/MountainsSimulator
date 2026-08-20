package main

import (
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

const defaultTileURL = "https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{z}/{x}/{y}.png"

// fetcher downloads terrarium tiles, caching each one on disk forever. Tiles
// are immutable, so a cache hit never needs revalidating.
type fetcher struct {
	urlTmpl  string
	cacheDir string
	workers  int
	retries  int
	client   *http.Client

	hits, misses atomic.Int64
}

func newFetcher(urlTmpl, cacheDir string, workers, retries int) *fetcher {
	return &fetcher{
		urlTmpl:  urlTmpl,
		cacheDir: cacheDir,
		workers:  workers,
		retries:  retries,
		client: &http.Client{
			Timeout: 60 * time.Second,
			Transport: &http.Transport{
				MaxIdleConnsPerHost: workers,
			},
		},
	}
}

func (f *fetcher) tilePath(z, x, y int) string {
	return filepath.Join(f.cacheDir, fmt.Sprint(z), fmt.Sprint(x), fmt.Sprintf("%d.png", y))
}

func (f *fetcher) tileURL(z, x, y int) string {
	r := f.urlTmpl
	r = strings.ReplaceAll(r, "{z}", strconv.Itoa(z))
	r = strings.ReplaceAll(r, "{x}", strconv.Itoa(x))
	r = strings.ReplaceAll(r, "{y}", strconv.Itoa(y))
	return r
}

// tile is one fetched tile, still PNG-encoded.
type tile struct {
	X, Y int
	PNG  []byte
}

// get returns one tile, from cache when possible.
func (f *fetcher) get(z, x, y int) ([]byte, error) {
	path := f.tilePath(z, x, y)
	if b, err := os.ReadFile(path); err == nil && len(b) > 0 {
		f.hits.Add(1)
		return b, nil
	}

	var lastErr error
	for attempt := 0; attempt <= f.retries; attempt++ {
		if attempt > 0 {
			// Exponential backoff: 0.5s, 1s, 2s, 4s...
			time.Sleep(time.Duration(250<<attempt) * time.Millisecond)
		}
		b, err := f.download(z, x, y)
		if err != nil {
			lastErr = err
			continue
		}
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			return nil, err
		}
		// Write via a temp file so a killed run cannot leave a truncated tile
		// in the cache, which would poison every later run.
		tmp := path + ".tmp"
		if err := os.WriteFile(tmp, b, 0o644); err != nil {
			return nil, err
		}
		if err := os.Rename(tmp, path); err != nil {
			return nil, err
		}
		f.misses.Add(1)
		return b, nil
	}
	return nil, fmt.Errorf("tile %d/%d/%d: %w", z, x, y, lastErr)
}

func (f *fetcher) download(z, x, y int) ([]byte, error) {
	resp, err := f.client.Get(f.tileURL(z, x, y))
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		io.Copy(io.Discard, io.LimitReader(resp.Body, 4096))
		return nil, fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	b, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}
	if len(b) == 0 {
		return nil, errors.New("empty body")
	}
	return b, nil
}

// getRange fetches every tile in r concurrently, reporting progress.
func (f *fetcher) getRange(r tileRange, progress func(done, total int)) ([]tile, error) {
	total := r.count()
	out := make([]tile, 0, total)

	type job struct{ x, y int }
	jobs := make(chan job)
	results := make(chan tile, f.workers)

	var (
		wg      sync.WaitGroup
		errOnce sync.Once
		firstEr error
		done    atomic.Int64
	)
	// Closed by the first worker that fails, so the producer stops queueing
	// instead of blocking forever on a channel nobody reads.
	quit := make(chan struct{})

	for i := 0; i < f.workers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := range jobs {
				b, err := f.get(r.Z, j.x, j.y)
				if err != nil {
					errOnce.Do(func() { firstEr = err; close(quit) })
					return
				}
				results <- tile{X: j.x, Y: j.y, PNG: b}
				if progress != nil {
					progress(int(done.Add(1)), total)
				}
			}
		}()
	}

	go func() {
		defer close(jobs)
		for y := r.Y0; y <= r.Y1; y++ {
			for x := r.X0; x <= r.X1; x++ {
				select {
				case jobs <- job{x, y}:
				case <-quit:
					return
				}
			}
		}
	}()

	go func() { wg.Wait(); close(results) }()

	for t := range results {
		out = append(out, t)
	}
	if firstEr != nil {
		return nil, firstEr
	}
	if len(out) != total {
		return nil, fmt.Errorf("fetched %d of %d tiles", len(out), total)
	}
	return out, nil
}
