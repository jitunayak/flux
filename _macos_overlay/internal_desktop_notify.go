// This file replaces the D-Bus notification client of the Omarchy build
// with the macOS notification center, through osascript. It keeps the API
// that fluxd uses.
package desktop

import (
	"context"
	"fmt"
	"os/exec"
	"strings"
	"sync"
	"time"
)

// busTimeout is the timeout of the D-Bus media client in media.go, which
// stays in this build. The notification client below uses it for osascript.
const busTimeout = 2 * time.Second

// Action is one button on a desktop notification. macOS shows no buttons
// through osascript, so a notification shows only its title and body.
type Action struct{ Key, Label string }

// Notification is a desktop notification.
type Notification struct {
	AppName, Title, Body, IconPath string
	Actions                        []Action
	// Urgency is 0 for low, 1 for normal, and 2 for critical.
	Urgency byte
	// Timeout is the display time. macOS ignores it, and it uses the
	// timeout of System Settings.
	Timeout    time.Duration
	ReplacesID uint32
	Category   string
	Silent     bool
}

// Notifier shows notifications with the macOS notification center through
// osascript. It keeps the same API as the D-Bus notifier of Omarchy.
type Notifier struct {
	mu       sync.Mutex
	nextID   uint32
	onAction []func(id uint32, key string)
	onClosed []func(id uint32)
}

// NewNotifier returns a notifier that uses osascript. It fails when
// osascript is missing, so fluxd logs notifications off, as on Omarchy
// without a session bus.
func NewNotifier() (*Notifier, error) {
	if _, err := exec.LookPath("osascript"); err != nil {
		return nil, fmt.Errorf("osascript is not installed: %w", err)
	}
	return &Notifier{}, nil
}

// Show displays a notification and returns its ID.
func (n *Notifier) Show(note Notification) (uint32, error) {
	// display notification uses the title, the subtitle, and the body. The
	// app name of the device goes in the subtitle.
	script := "display notification " + appleScriptString(note.Body) +
		" with title " + appleScriptString(note.Title)
	if note.AppName != "" {
		script += " subtitle " + appleScriptString(note.AppName)
	}
	ctx, cancel := context.WithTimeout(context.Background(), busTimeout)
	defer cancel()
	out, err := exec.CommandContext(ctx, "osascript", "-e", script).CombinedOutput()
	if err != nil {
		return 0, fmt.Errorf("osascript: %v: %s", err, strings.TrimSpace(string(out)))
	}
	n.mu.Lock()
	n.nextID++
	id := n.nextID
	n.mu.Unlock()
	return id, nil
}

// Close does nothing: the macOS notification center owns the notification,
// and osascript gives no handle to remove it.
func (n *Notifier) Close(id uint32) error { return nil }

// OnAction records fn. macOS gives osascript no button, so fn never runs.
func (n *Notifier) OnAction(fn func(id uint32, key string)) {
	n.mu.Lock()
	n.onAction = append(n.onAction, fn)
	n.mu.Unlock()
}

// OnClosed records fn. macOS gives osascript no close event, so fn never
// runs.
func (n *Notifier) OnClosed(fn func(id uint32)) {
	n.mu.Lock()
	n.onClosed = append(n.onClosed, fn)
	n.mu.Unlock()
}

// Shutdown does nothing: there is no session bus to close.
func (n *Notifier) Shutdown() {}

// appleScriptString returns s as an AppleScript string literal.
func appleScriptString(s string) string {
	r := strings.NewReplacer("\\", "\\\\", "\"", "\\\"")
	return "\"" + r.Replace(s) + "\""
}
