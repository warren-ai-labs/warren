// Tmux is a fully supported alternative runtime. ghostline is the default
// and recommended runtime (server-side PTY sessions with libghostty-vt
// snapshots); --runtime tmux keeps the classic tmux adapter available for
// environments that prefer or require it.
package runtime

import (
	"bytes"
	"compress/gzip"
	"context"
	"crypto/rand"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

type Tmux struct {
	Binary    string
	Socket    string
	OutputDir string

	sessionMu sync.Mutex
	sessions  map[string]*sync.Mutex
}

func (t *Tmux) command(ctx context.Context, args ...string) *exec.Cmd {
	all := make([]string, 0, len(args)+2)
	if t.Socket != "" {
		all = append(all, "-L", t.Socket)
	}
	all = append(all, args...)
	binary := t.Binary
	if binary == "" {
		binary = "tmux"
	}
	return exec.CommandContext(ctx, binary, all...)
}

func (t *Tmux) Check(ctx context.Context) error {
	if _, err := exec.LookPath(defaultString(t.Binary, "tmux")); err != nil {
		return fmt.Errorf("tmux is required: %w", err)
	}
	return nil
}

func (t *Tmux) Create(ctx context.Context, runtimeName, directory, command string, env []string) error {
	args := []string{"new-session", "-d", "-s", runtimeName, "-c", directory, "-x", "120", "-y", "36"}
	// Agent TUIs pick colors from the inherited environment. The daemon removes
	// ambient NO_COLOR before starting the runtime; passing NO_COLOR= here
	// would still disable colors because the variable remains present.
	for _, entry := range env {
		args = append(args, "-e", entry)
	}
	output, err := t.command(ctx, args...).CombinedOutput()
	if err != nil {
		return fmt.Errorf("create tmux session: %s: %w", strings.TrimSpace(string(output)), err)
	}
	if strings.TrimSpace(command) != "" {
		// Start a plain login shell and type the requested command into it.
		// The shell outlives the command, so Ctrl+C / Ctrl+D inside an agent
		// TUI leaves a usable terminal instead of ending the session.
		time.Sleep(400 * time.Millisecond)
		if output, err := t.command(ctx, "send-keys", "-t", runtimeName, "-l", command).CombinedOutput(); err != nil {
			return fmt.Errorf("type session command: %s: %w", strings.TrimSpace(string(output)), err)
		}
		if _, err := t.command(ctx, "send-keys", "-t", runtimeName, "Enter").CombinedOutput(); err != nil {
			return fmt.Errorf("submit session command: %w", err)
		}
	}
	// tmux reports Shift+Enter to panes as a kitty-protocol sequence only when
	// the server's extended-keys option is on. Without it, Ghostty's
	// Shift+Enter newline collapses to plain Enter inside tmux and agent TUIs
	// submit instead of inserting a newline. The server must already exist, so
	// this runs after new-session; best-effort so older tmux versions without
	// the option can still host sessions.
	//
	// Known issue (2026-08): plain shells get Shift+Enter as a literal LF and
	// work, but Codex TUI probes `extended-keys-format` and only requests
	// modifyOtherKeys mode 2 (`CSI > 4;2 m`) when tmux reports `csi-u`. tmux
	// defaults to `xterm`, so in Codex sessions Shift+Enter still collapses to
	// Enter/LF and submits the draft instead of inserting a newline. Fix by
	// also running `set-option -s extended-keys-format csi-u` here, then
	// restarting the Codex session so the pane re-probes at TUI startup.
	_ = t.command(ctx, "set-option", "-s", "extended-keys", "on").Run()
	if err := t.setLatestWindowSize(ctx, runtimeName); err != nil {
		_ = t.Kill(ctx, runtimeName)
		return err
	}
	return nil
}

// EnsurePipe installs the raw PTY byte pipe for a session. tmux supports one
// pipe per pane, so the install is guarded by `#{pane_pipe}` instead of the
// `-o` toggle flag: `pipe-pane -o` closes an existing pipe on tmux 3.5a,
// which would silently stop every adopted session's output after a daemon
// restart. With the guard, repeated attach/adopt never stack a pipe and never
// tear down an already-correct one.
func (t *Tmux) EnsurePipe(ctx context.Context, runtimeName string) error {
	if !t.Exists(ctx, runtimeName) {
		return fmt.Errorf("tmux session not found: %s", runtimeName)
	}
	if t.OutputDir == "" {
		t.OutputDir = defaultOutputDirectory()
	}
	if err := os.MkdirAll(t.OutputDir, 0o700); err != nil {
		return fmt.Errorf("create runtime output directory: %w", err)
	}
	spoolPath := t.SpoolPath(runtimeName)
	file, err := os.OpenFile(spoolPath, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		return fmt.Errorf("open output spool: %w", err)
	}
	_ = file.Close()
	pane, err := t.PaneTarget(ctx, runtimeName)
	if err != nil {
		return err
	}
	lock := t.sessionLock(runtimeName)
	lock.Lock()
	defer lock.Unlock()
	hasPipe, err := t.paneHasPipe(ctx, pane)
	if err != nil {
		return err
	}
	if !hasPipe {
		output, installErr := t.command(ctx,
			"pipe-pane", "-O", "-t", pane,
			"cat >> "+shellQuote(spoolPath),
		).CombinedOutput()
		if installErr != nil {
			return fmt.Errorf("install tmux output pipe: %s: %w", strings.TrimSpace(string(output)), installErr)
		}
	}
	return t.setLatestWindowSize(ctx, runtimeName)
}

func (t *Tmux) paneHasPipe(ctx context.Context, pane string) (bool, error) {
	output, err := t.command(ctx, "display-message", "-p", "-t", pane, "#{pane_pipe}").Output()
	if err != nil {
		return false, fmt.Errorf("query tmux output pipe: %w", err)
	}
	return strings.TrimSpace(string(output)) == "1", nil
}

func (t *Tmux) ClosePipe(ctx context.Context, runtimeName string) error {
	pane, err := t.PaneTarget(ctx, runtimeName)
	if err != nil {
		return err
	}
	output, err := t.command(ctx, "pipe-pane", "-t", pane).CombinedOutput()
	if err != nil {
		return fmt.Errorf("close tmux output pipe: %s: %w", strings.TrimSpace(string(output)), err)
	}
	return nil
}

func (t *Tmux) PaneTarget(ctx context.Context, runtimeName string) (string, error) {
	output, err := t.command(ctx, "display-message", "-p", "-t", runtimeName, "#{pane_id}").Output()
	if err != nil {
		return "", fmt.Errorf("resolve tmux pane: %w", err)
	}
	pane := strings.TrimSpace(string(output))
	if pane == "" {
		return runtimeName + ":0.0", nil
	}
	return pane, nil
}

func (t *Tmux) setLatestWindowSize(ctx context.Context, runtimeName string) error {
	output, err := t.command(ctx, "set-window-option", "-t", runtimeName, "window-size", "latest").CombinedOutput()
	if err != nil {
		return fmt.Errorf("set tmux window-size latest: %s: %w", strings.TrimSpace(string(output)), err)
	}
	return nil
}

func (t *Tmux) SpoolPath(runtimeName string) string {
	dir := t.OutputDir
	if dir == "" {
		dir = defaultOutputDirectory()
	}
	return filepath.Join(dir, runtimeName+".out")
}

func (t *Tmux) SpoolSize(ctx context.Context, runtimeName string) (int64, error) {
	info, err := os.Stat(t.SpoolPath(runtimeName))
	if err != nil {
		return 0, err
	}
	return info.Size(), nil
}

// TruncateSpool compacts the live spool in place. The pipe command keeps its
// O_APPEND file descriptor, so tmux output continues into the same inode from
// byte zero; Host bumps the epoch and reanchors clients.
func (t *Tmux) TruncateSpool(ctx context.Context, runtimeName string) error {
	path := t.SpoolPath(runtimeName)
	if err := os.Truncate(path, 0); err != nil {
		return fmt.Errorf("truncate output spool: %w", err)
	}
	return nil
}

// ArchiveSpool compresses the current spool to a timestamped .gz file and
// prunes old archives. Best-effort diagnostics; truncation must not depend on
// archive success.
func (t *Tmux) ArchiveSpool(ctx context.Context, runtimeName string) error {
	path := t.SpoolPath(runtimeName)
	info, err := os.Stat(path)
	if err != nil || info.Size() == 0 {
		return nil
	}
	archive := path + "." + strconv.FormatInt(time.Now().UnixNano(), 10) + ".gz"
	source, err := os.Open(path)
	if err != nil {
		return err
	}
	defer source.Close()
	destination, err := os.OpenFile(archive, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	writer := gzip.NewWriter(destination)
	if _, err := io.Copy(writer, source); err != nil {
		_ = writer.Close()
		_ = destination.Close()
		_ = os.Remove(archive)
		return err
	}
	if err := writer.Close(); err != nil {
		_ = destination.Close()
		_ = os.Remove(archive)
		return err
	}
	if err := destination.Close(); err != nil {
		return err
	}
	return t.pruneArchives(path)
}

func (t *Tmux) pruneArchives(path string) error {
	matches, err := filepath.Glob(path + ".*.gz")
	if err != nil {
		return err
	}
	for len(matches) > 3 {
		oldest := matches[0]
		for _, match := range matches[1:] {
			if match < oldest {
				oldest = match
			}
		}
		_ = os.Remove(oldest)
		matches = removeString(matches, oldest)
	}
	return nil
}

func removeString(values []string, target string) []string {
	result := values[:0]
	for _, value := range values {
		if value != target {
			result = append(result, value)
		}
	}
	return result
}

func (t *Tmux) RemoveSpool(runtimeName string) {
	path := t.SpoolPath(runtimeName)
	_ = os.Remove(path)
	for _, match := range mustGlob(path + ".*.gz") {
		_ = os.Remove(match)
	}
}

func mustGlob(pattern string) []string {
	matches, _ := filepath.Glob(pattern)
	return matches
}

func defaultOutputDirectory() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".warren", "output")
}

func (t *Tmux) Exists(ctx context.Context, runtimeName string) bool {
	return t.command(ctx, "has-session", "-t", runtimeName).Run() == nil
}

func (t *Tmux) List(ctx context.Context) (map[string]bool, error) {
	output, err := t.command(ctx, "list-sessions", "-F", "#{session_name}").CombinedOutput()
	if err != nil {
		message := string(output)
		if strings.Contains(message, "no server running") || strings.Contains(message, "failed to connect") {
			return map[string]bool{}, nil
		}
		return nil, fmt.Errorf("list tmux sessions: %s: %w", strings.TrimSpace(message), err)
	}
	sessions := make(map[string]bool)
	for _, name := range strings.Fields(string(output)) {
		sessions[name] = true
	}
	return sessions, nil
}

// ListCreated returns the sessions on this socket with their tmux creation
// timestamps. The service uses it to reclaim orphaned sessions that outlived
// their state record, e.g. after a state reset or daemon crash.
func (t *Tmux) ListCreated(ctx context.Context) (map[string]time.Time, error) {
	output, err := t.command(ctx, "list-sessions", "-F", "#{session_name},#{session_created}").CombinedOutput()
	if err != nil {
		message := string(output)
		if strings.Contains(message, "no server running") || strings.Contains(message, "failed to connect") {
			return map[string]time.Time{}, nil
		}
		return nil, fmt.Errorf("list tmux sessions: %s: %w", strings.TrimSpace(message), err)
	}
	sessions := make(map[string]time.Time)
	for _, line := range strings.Split(strings.TrimSpace(string(output)), "\n") {
		if line == "" {
			continue
		}
		fields := strings.SplitN(line, ",", 2)
		if len(fields) != 2 {
			continue
		}
		created, err := strconv.ParseInt(fields[1], 10, 64)
		if err != nil {
			continue
		}
		sessions[fields[0]] = time.Unix(created, 0)
	}
	return sessions, nil
}

// Metadata reports the pane's current foreground command and working
// directory, the tmux equivalent of the ghostline foreground probe.
func (t *Tmux) Metadata(ctx context.Context, runtimeName string) (RuntimeMetadata, error) {
	pane, err := t.PaneTarget(ctx, runtimeName)
	if err != nil {
		return RuntimeMetadata{}, err
	}
	output, err := t.command(ctx, "display-message", "-p", "-t", pane, "#{pane_current_command}\t#{pane_current_path}").Output()
	if err != nil {
		return RuntimeMetadata{}, fmt.Errorf("query tmux metadata: %s: %w", strings.TrimSpace(string(output)), err)
	}
	fields := strings.SplitN(strings.TrimSpace(string(output)), "\t", 2)
	if len(fields) != 2 {
		return RuntimeMetadata{}, fmt.Errorf("unexpected tmux metadata: %q", strings.TrimSpace(string(output)))
	}
	return RuntimeMetadata{Process: fields[0], Directory: fields[1]}, nil
}

func (t *Tmux) Capture(ctx context.Context, runtimeName string) ([]byte, error) {
	target := runtimeName + ":0.0"
	// Query the cursor and capture the pane in one tmux command sequence. A
	// shell can move between two separate tmux invocations, which would make a
	// cursor coordinate belong to a different screen than the captured cells.
	output, err := t.command(ctx,
		"display-message", "-p", "-t", target, "#{cursor_x},#{cursor_y}", ";",
		"capture-pane", "-p", "-e", "-J", "-S", "-", "-t", target,
	).Output()
	if err != nil {
		return nil, err
	}
	capture, cursorX, cursorY, err := parseCaptureWithCursor(output)
	if err != nil {
		return nil, fmt.Errorf("parse tmux capture: %w", err)
	}
	return renderCaptureSnapshot(capture, cursorX, cursorY), nil
}

func parseCaptureWithCursor(output []byte) ([]byte, int, int, error) {
	metadata, capture, found := bytes.Cut(output, []byte{'\n'})
	if !found {
		return nil, 0, 0, fmt.Errorf("missing cursor metadata")
	}
	values := strings.SplitN(strings.TrimSpace(string(metadata)), ",", 2)
	if len(values) != 2 {
		return nil, 0, 0, fmt.Errorf("invalid cursor metadata %q", metadata)
	}
	cursorX, err := strconv.Atoi(values[0])
	if err != nil || cursorX < 0 {
		return nil, 0, 0, fmt.Errorf("invalid cursor column %q", values[0])
	}
	cursorY, err := strconv.Atoi(values[1])
	if err != nil || cursorY < 0 {
		return nil, 0, 0, fmt.Errorf("invalid cursor row %q", values[1])
	}
	return capture, cursorX, cursorY, nil
}

func renderCaptureSnapshot(output []byte, cursorX, cursorY int) []byte {
	if cursorX < 0 || cursorY < 0 {
		return nil
	}
	output = trimCaptureFinalLineEnding(output)
	// Known limitation: replaying a full tmux snapshot through Ghostty can
	// misalign background color blocks on soft-wrapped colored history
	// (Ghostty BCE behavior, upstream #12497 / #12505). A transient resize
	// clears it but causes visible flicker or a black reveal window, and
	// rewriting per-row SGR is intrusive on colors. Warren deliberately keeps
	// the snapshot bytes faithful and tracks upstream instead of applying a
	// lossy workaround here. Because surfaces are retained across tab
	// switches, one manual resize reflows Ghostty back into alignment and
	// later switches resume from an anchor without replaying history;
	// however any subsequent scroll from live output can re-trigger Ghostty's
	// BCE corruption until upstream changes the behavior.
	// capture-pane emits LF-only lines. A terminal interprets LF as a line
	// feed without returning to column zero, which makes every subsequent
	// snapshot drift farther to the right in xterm.js. Normalize the snapshot
	// to the CRLF convention used by a PTY before sending it to clients.
	normalized := normalizeCaptureOutput(output)
	// Clear both the visible screen and the client's old scrollback before
	// replaying the complete tmux history. Restore the real tmux cursor after
	// replay: the final capture line may contain the prompt at any column, and
	// a trailing LF would otherwise move the cursor to the next row/column 0.
	result := make([]byte, 0, len(normalized)+32)
	result = append(result, []byte("\x1b[3J\x1b[2J\x1b[H")...)
	result = append(result, normalized...)
	result = append(result, []byte(fmt.Sprintf("\x1b[%d;%dH", cursorY+1, cursorX+1))...)
	return result
}

func trimCaptureFinalLineEnding(output []byte) []byte {
	if len(output) == 0 || output[len(output)-1] != '\n' {
		return output
	}
	output = output[:len(output)-1]
	if len(output) > 0 && output[len(output)-1] == '\r' {
		output = output[:len(output)-1]
	}
	return output
}

func normalizeCaptureOutput(output []byte) []byte {
	if len(output) == 0 {
		return nil
	}

	normalized := make([]byte, 0, len(output)+bytes.Count(output, []byte{'\n'}))
	for index, value := range output {
		if value == '\n' && (index == 0 || output[index-1] != '\r') {
			normalized = append(normalized, '\r')
		}
		normalized = append(normalized, value)
	}
	return normalized
}

func (t *Tmux) Input(ctx context.Context, runtimeName string, data []byte) error {
	if len(data) == 0 {
		return nil
	}
	lock := t.sessionLock(runtimeName)
	lock.Lock()
	defer lock.Unlock()
	// Pasting raw escape sequences through paste-buffer does not behave like
	// a real key press (less/git log ignores pasted CSI arrow bytes). Route
	// recognized terminal keys through tmux send-keys so shells and pagers
	// see the same key the user actually pressed.
	if key, ok := tmuxKeyName(data); ok {
		if output, err := t.command(ctx, "send-keys", "-t", runtimeName+":0.0", key).CombinedOutput(); err != nil {
			return fmt.Errorf("send tmux key: %s: %w", strings.TrimSpace(string(output)), err)
		}
		return nil
	}
	// Every write uses a unique tmux buffer so concurrent inputs can never
	// cross. paste-buffer -d deletes the buffer on success; a failed write is
	// cleaned up below and never touches another input.
	bufferName := "warren-in-" + strings.ReplaceAll(newID(), "-", "")
	cmd := t.command(ctx, "load-buffer", "-b", bufferName, "-")
	cmd.Stdin = bytes.NewReader(data)
	if output, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("load tmux input: %s: %w", strings.TrimSpace(string(output)), err)
	}
	if output, err := t.command(ctx, "paste-buffer", "-b", bufferName, "-d", "-t", runtimeName+":0.0").CombinedOutput(); err != nil {
		_, _ = t.command(ctx, "delete-buffer", "-b", bufferName).CombinedOutput()
		return fmt.Errorf("send tmux input: %s: %w", strings.TrimSpace(string(output)), err)
	}
	return nil
}

// tmuxKeyName maps terminal byte sequences that must reach tmux as key
// presses instead of pasted text. Exact single-key sequences (arrows, editing
// keys, and common CSI/SS3 forms) return tmux's key name; everything else
// returns ok=false and continues through the binary-safe paste path.
func tmuxKeyName(data []byte) (string, bool) {
	switch string(data) {
	case "\x1b":
		return "Escape", true
	case "\r":
		return "Enter", true
	// tmux's paste path converts a literal LF into Enter (CR), so a
	// Shift+Enter (or Ctrl+J) newline must arrive as the real C-j key:
	// send-keys delivers it to the pane as an unmodified LF.
	case "\n":
		return "C-j", true
	case "\t":
		return "Tab", true
	// Kitty-protocol Shift+Enter, emitted when a future Ghostty version
	// bypasses the text: keybind for an app that requested extended keys.
	case "\x1b[13;2u":
		return "S-Enter", true
	case "\x7f":
		return "BSpace", true
	case "\x1bOA", "\x1b[A":
		return "Up", true
	case "\x1bOB", "\x1b[B":
		return "Down", true
	case "\x1bOC", "\x1b[C":
		return "Right", true
	case "\x1bOD", "\x1b[D":
		return "Left", true
	case "\x1bOH", "\x1b[H":
		return "Home", true
	case "\x1bOF", "\x1b[F":
		return "End", true
	case "\x1b[Z":
		return "BTab", true
	}
	if len(data) < 4 || data[0] != 0x1b || data[1] != '[' {
		return "", false
	}

	text := string(data)
	final := text[len(text)-1]
	params := strings.Split(text[2:len(text)-1], ";")
	if final == '~' {
		if len(params) != 1 {
			return "", false
		}
		code, err := strconv.Atoi(params[0])
		if err != nil {
			return "", false
		}
		switch code {
		case 1, 7:
			return "Home", true
		case 2:
			return "IC", true
		case 3:
			return "DC", true
		case 4, 8:
			return "End", true
		case 5:
			return "PageUp", true
		case 6:
			return "PageDown", true
		case 11, 12, 13, 14, 15, 17, 18, 19, 20, 21, 23, 24:
			return fmt.Sprintf("F%d", functionKeyNumber(code)), true
		default:
			return "", false
		}
	}

	base := ""
	switch final {
	case 'A':
		base = "Up"
	case 'B':
		base = "Down"
	case 'C':
		base = "Right"
	case 'D':
		base = "Left"
	case 'H':
		base = "Home"
	case 'F':
		base = "End"
	case 'Z':
		base = "BTab"
	default:
		return "", false
	}
	if len(params) == 1 && params[0] == "" {
		return base, true
	}
	if len(params) != 2 {
		return "", false
	}
	prefix := ""
	switch params[1] {
	case "2":
		prefix = "S-"
	case "3":
		prefix = "M-"
	case "4":
		prefix = "M-S-"
	case "5":
		prefix = "C-"
	case "6":
		prefix = "C-S-"
	case "7":
		prefix = "C-M-"
	case "8":
		prefix = "C-M-S-"
	default:
		return "", false
	}
	return prefix + base, true
}

func functionKeyNumber(code int) int {
	switch code {
	case 11:
		return 1
	case 12:
		return 2
	case 13:
		return 3
	case 14:
		return 4
	case 15:
		return 5
	case 17:
		return 6
	case 18:
		return 7
	case 19:
		return 8
	case 20:
		return 9
	case 21:
		return 10
	case 23:
		return 11
	case 24:
		return 12
	default:
		return 0
	}
}

func (t *Tmux) Resize(ctx context.Context, runtimeName string, columns, rows int) error {
	lock := t.sessionLock(runtimeName)
	lock.Lock()
	defer lock.Unlock()
	return t.command(ctx, "resize-window", "-t", runtimeName, "-x", fmt.Sprint(columns), "-y", fmt.Sprint(rows)).Run()
}

func (t *Tmux) Kill(ctx context.Context, runtimeName string) error {
	output, err := t.command(ctx, "kill-session", "-t", runtimeName).CombinedOutput()
	if err != nil && t.Exists(ctx, runtimeName) {
		return fmt.Errorf("kill tmux session: %s: %w", strings.TrimSpace(string(output)), err)
	}
	return nil
}

func (t *Tmux) sessionLock(name string) *sync.Mutex {
	t.sessionMu.Lock()
	defer t.sessionMu.Unlock()
	if t.sessions == nil {
		t.sessions = map[string]*sync.Mutex{}
	}
	lock := t.sessions[name]
	if lock == nil {
		lock = &sync.Mutex{}
		t.sessions[name] = lock
	}
	return lock
}

// newID is a UUIDv4-style generator used only for tmux buffer names.
func newID() string {
	var raw [16]byte
	if _, err := rand.Read(raw[:]); err != nil {
		return fmt.Sprintf("%d", time.Now().UnixNano())
	}
	raw[6] = (raw[6] & 0x0f) | 0x40
	raw[8] = (raw[8] & 0x3f) | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", raw[0:4], raw[4:6], raw[6:8], raw[8:10], raw[10:16])
}

func shellQuote(value string) string {
	return "'" + strings.ReplaceAll(value, "'", "'\\''") + "'"
}

func defaultString(value, fallback string) string {
	if value == "" {
		return fallback
	}
	return value
}
