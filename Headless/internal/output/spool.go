package output

import (
	"errors"
	"io"
	"os"
	"strconv"
	"sync"
	"sync/atomic"
	"time"
)

// SpoolWatcher tails an append-only spool from a persisted byte offset. Its
// polling interval can change while it is running so callers can reserve fast
// output delivery for the terminal the user is actively viewing.
type SpoolWatcher struct {
	path       string
	file       *os.File
	offset     atomic.Int64
	maxBytes   atomic.Int64
	interval   atomic.Int64
	buffer     []byte
	onBytes    func([]byte)
	onRotate   func()
	onOverflow func()

	ping            chan struct{}
	intervalChanged chan struct{}
	done            chan struct{}
	startOnce       sync.Once
	closeOnce       sync.Once
	readMu          sync.Mutex
	paused          bool
}

// NewSpoolWatcher returns a watcher positioned at offset in path. Callbacks
// may be nil. Start begins polling.
func NewSpoolWatcher(path string, offset int64, onBytes func([]byte), onRotate func(), onOverflow func()) (*SpoolWatcher, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	info, err := file.Stat()
	if err != nil {
		closeQuietly(file)
		return nil, err
	}
	if offset < 0 {
		offset = 0
	}
	if offset > info.Size() {
		closeQuietly(file)
		return nil, &spoolOffsetError{Path: path, Offset: offset, Size: info.Size()}
	}
	if _, err := file.Seek(offset, io.SeekStart); err != nil {
		closeQuietly(file)
		return nil, err
	}
	watcher := &SpoolWatcher{
		path:            path,
		file:            file,
		onBytes:         onBytes,
		onRotate:        onRotate,
		onOverflow:      onOverflow,
		ping:            make(chan struct{}, 1),
		intervalChanged: make(chan struct{}, 1),
		done:            make(chan struct{}),
	}
	watcher.maxBytes.Store(64 * 1024 * 1024)
	watcher.interval.Store(int64(50 * time.Millisecond))
	watcher.offset.Store(offset)
	return watcher, nil
}

type spoolOffsetError struct {
	Path   string
	Offset int64
	Size   int64
}

func (e *spoolOffsetError) Error() string {
	return "spool offset " + strconv.FormatInt(e.Offset, 10) + " is beyond file size " + strconv.FormatInt(e.Size, 10) + ": " + e.Path
}

// Offset returns the next byte position the watcher will deliver.
func (w *SpoolWatcher) Offset() int64 {
	return w.offset.Load()
}

// Interval returns the current polling cadence.
func (w *SpoolWatcher) Interval() time.Duration {
	return w.pollInterval()
}

// SetMaxBytes configures the spool size cap. When the watcher passes the cap
// it calls onOverflow so the owner can compact the spool.
func (w *SpoolWatcher) SetMaxBytes(maxBytes int64) {
	if maxBytes > 0 {
		w.maxBytes.Store(maxBytes)
	}
}

// SetInterval changes the polling cadence and wakes the loop so a shorter
// interval takes effect immediately. Invalid durations leave the cadence
// unchanged.
func (w *SpoolWatcher) SetInterval(interval time.Duration) {
	if interval <= 0 || w.interval.Swap(int64(interval)) == int64(interval) {
		return
	}
	select {
	case w.intervalChanged <- struct{}{}:
	default:
	}
}

// Ping asks the watcher to check for output without waiting for its next poll.
func (w *SpoolWatcher) Ping() {
	select {
	case w.ping <- struct{}{}:
	default:
	}
}

// Drain synchronously tails any output currently available. It is used at an
// attach boundary so a background cadence cannot delay the newly visible
// terminal.
func (w *SpoolWatcher) Drain() {
	w.drain()
}

// Start begins watching. Repeated calls are safe and have no effect.
func (w *SpoolWatcher) Start() {
	w.startOnce.Do(func() { go w.loop() })
}

// Close stops the watcher and releases its file descriptor. It is safe to call
// multiple times.
func (w *SpoolWatcher) Close() {
	w.closeOnce.Do(func() {
		close(w.done)
		closeQuietly(w.file)
	})
}

// Pause blocks until any in-flight drain finishes, then prevents new drains.
// Use it while preparing a checkpoint replay so live reads cannot interleave.
func (w *SpoolWatcher) Pause() {
	w.readMu.Lock()
	w.paused = true
	w.readMu.Unlock()
}

// Resume re-enables draining after Pause and asks the watcher to check
// immediately.
func (w *SpoolWatcher) Resume() {
	w.readMu.Lock()
	w.paused = false
	w.readMu.Unlock()
	w.Ping()
}

// SkipTo re-bases the watcher to a byte position covered by a snapshot. It
// must be called while paused and the offset must be within the current file;
// any unread bytes below the target were already rendered by the snapshot and
// must not be delivered again.
func (w *SpoolWatcher) SkipTo(offset int64) error {
	w.readMu.Lock()
	defer w.readMu.Unlock()
	if !w.paused {
		return errors.New("skip spool watcher while running")
	}
	info, err := w.file.Stat()
	if err != nil {
		return err
	}
	if offset < 0 || offset > info.Size() {
		return &spoolOffsetError{Path: w.path, Offset: offset, Size: info.Size()}
	}
	if _, err := w.file.Seek(offset, io.SeekStart); err != nil {
		return err
	}
	w.offset.Store(offset)
	return nil
}

func (w *SpoolWatcher) loop() {
	w.drain()
	timer := time.NewTimer(w.pollInterval())
	defer stopTimer(timer)
	for {
		select {
		case <-w.done:
			return
		case <-w.ping:
			w.drain()
		case <-timer.C:
			w.drain()
		case <-w.intervalChanged:
		}
		resetTimer(timer, w.pollInterval())
	}
}

func (w *SpoolWatcher) pollInterval() time.Duration {
	return time.Duration(w.interval.Load())
}

func (w *SpoolWatcher) drain() {
	w.readMu.Lock()
	defer w.readMu.Unlock()
	if w.paused {
		return
	}
	info, err := w.file.Stat()
	if err != nil {
		return
	}
	offset := w.offset.Load()
	if info.Size() < offset {
		if _, err := w.file.Seek(0, io.SeekStart); err != nil {
			return
		}
		offset = 0
		w.offset.Store(0)
		if w.onRotate != nil {
			w.onRotate()
		}
	}
	if info.Size() == offset {
		return
	}
	if w.buffer == nil {
		w.buffer = make([]byte, 64*1024)
	}
	for {
		read, readErr := w.file.Read(w.buffer)
		if read > 0 {
			offset += int64(read)
			w.offset.Store(offset)
			if w.onBytes != nil {
				w.onBytes(w.buffer[:read])
			}
			if maxBytes := w.maxBytes.Load(); maxBytes > 0 && offset > maxBytes && w.onOverflow != nil {
				w.onOverflow()
			}
		}
		if readErr != nil {
			return
		}
		if read == 0 {
			return
		}
	}
}

func resetTimer(timer *time.Timer, interval time.Duration) {
	if !timer.Stop() {
		select {
		case <-timer.C:
		default:
		}
	}
	timer.Reset(interval)
}

func stopTimer(timer *time.Timer) {
	if !timer.Stop() {
		select {
		case <-timer.C:
		default:
		}
	}
}

func closeQuietly(file *os.File) {
	if file != nil {
		_ = file.Close()
	}
}
