// Package desktop connects fluxd to the macOS desktop: the clipboard and
// notifications. This file replaces the Wayland clipboard of the Omarchy
// build with pbcopy and pbpaste.
package desktop

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"os/exec"
	"strings"
	"sync"
	"time"
)

// MaxClipboardText is the largest clipboard text that Flux takes from a
// device or reads from the macOS clipboard.
const MaxClipboardText = 1 << 20

// MaxClipboardImage is the largest clipboard image that Flux syncs. macOS
// does not sync images, but the constant keeps the same limit as the
// Omarchy build.
const MaxClipboardImage = 16 << 20

// ImageType is the MIME type of the images that Watch reports on Omarchy.
const ImageType = "image/png"

// clipTimeout limits each run of pbpaste and pbcopy.
const clipTimeout = 5 * time.Second

// pollInterval is how often Watch reads the clipboard for a change. macOS
// sends no change event, so Watch polls.
const pollInterval = 600 * time.Millisecond

// maxWritten is the number of recent Set contents that Watch does not
// report.
const maxWritten = 8

// Clipboard reads and writes the macOS clipboard with pbpaste and pbcopy.
type Clipboard struct {
	mu sync.Mutex
	// lastSeen identifies the last content, from contentKey.
	lastSeen string
	// written identifies the contents that Set put on the clipboard and
	// that Watch did not see yet, the oldest first.
	written []string
}

// NewClipboard returns a clipboard that uses pbpaste and pbcopy.
func NewClipboard() *Clipboard { return &Clipboard{} }

// Watch reads the clipboard every pollInterval and calls onText for each
// new text. macOS has no clipboard watch, so this polls. Images do not
// sync on macOS, so onImage is never called.
func (c *Clipboard) Watch(ctx context.Context, onText func(text string), _ func(data []byte, mime string)) {
	// The first read records the current content and does not report it.
	if text, err := c.Get(); err == nil && text != "" {
		c.mu.Lock()
		c.lastSeen = contentKey("text", []byte(text))
		c.mu.Unlock()
	}
	t := time.NewTicker(pollInterval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
		text, err := c.Get()
		if err != nil || text == "" {
			continue
		}
		if c.observe(contentKey("text", []byte(text))) {
			onText(text)
		}
	}
}

// observe records key as the last content. It reports whether the content
// is a new local change. Content that Set wrote is not a change.
func (c *Clipboard) observe(key string) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	if i := indexOf(c.written, key); i >= 0 {
		c.written = c.written[i+1:]
		c.lastSeen = key
		return false
	}
	if key == c.lastSeen {
		return false
	}
	c.lastSeen = key
	return true
}

// wrote records key as content that Set puts on the clipboard.
func (c *Clipboard) wrote(key string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.lastSeen = key
	c.written = append(c.written, key)
	if len(c.written) > maxWritten {
		c.written = c.written[len(c.written)-maxWritten:]
	}
}

// Get returns the text on the clipboard, or "" when it holds no text.
func (c *Clipboard) Get() (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), clipTimeout)
	defer cancel()
	var stderr bytes.Buffer
	cmd := exec.CommandContext(ctx, "pbpaste")
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		if msg := strings.TrimSpace(stderr.String()); msg != "" {
			return "", errors.New("pbpaste: " + msg)
		}
		return "", err
	}
	if !isText(out) {
		return "", nil
	}
	return string(out), nil
}

// GetImage returns nil: macOS does not sync clipboard images.
func (c *Clipboard) GetImage() ([]byte, error) { return nil, nil }

// Set puts text on the clipboard. Watch does not report this change.
func (c *Clipboard) Set(text string) error {
	c.wrote(contentKey("text", []byte(text)))
	ctx, cancel := context.WithTimeout(context.Background(), clipTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, "pbcopy")
	cmd.Stdin = strings.NewReader(text)
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("pbcopy: %w", err)
	}
	return nil
}

// SetImage does nothing and returns nil: macOS does not sync clipboard
// images.
func (c *Clipboard) SetImage(data []byte, mime string) error { return nil }

// contentKey identifies clipboard content of the type typ.
func contentKey(typ string, data []byte) string {
	sum := sha256.Sum256(data)
	return typ + " " + hex.EncodeToString(sum[:])
}

// isText reports whether b looks like text and not binary data.
func isText(b []byte) bool { return bytes.IndexByte(b, 0) < 0 }

// indexOf returns the index of s in list, or -1.
func indexOf(list []string, s string) int {
	for i, v := range list {
		if v == s {
			return i
		}
	}
	return -1
}
