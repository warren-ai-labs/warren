package programstatus

import "sort"

// Tracker holds the record set for one terminal. Each report replaces its
// record completely; clear removes records. The zero value is not usable; call
// NewTracker.
type Tracker struct {
	records  map[string]*Record
	sequence uint64
}

// NewTracker returns an empty tracker.
func NewTracker() *Tracker {
	return &Tracker{records: make(map[string]*Record)}
}

// Apply folds one decoded report into the record set. It reports whether the
// visible record set changed, which callers use to advance the observer-facing
// roster revision without a durable Store write.
func (t *Tracker) Apply(report Report) bool {
	t.sequence++
	if report.State == StateClear {
		return t.remove(report.ID)
	}
	record := &Record{
		Report:       report,
		EffectiveApp: t.effectiveApp(report.ID, report.App),
		Sequence:     t.sequence,
	}
	previous, existed := t.records[report.ID]
	if !existed && len(t.records) >= maxRecords {
		t.evictOldest()
	}
	t.records[report.ID] = record
	return !existed || !previous.visibleEqual(*record)
}

// Records returns the current records ordered by last update.
func (t *Tracker) Records() []Record {
	ordered := make([]Record, 0, len(t.records))
	for _, record := range t.records {
		ordered = append(ordered, *record)
	}
	sort.Slice(ordered, func(i, j int) bool {
		return ordered[i].Sequence < ordered[j].Sequence
	})
	return ordered
}

// Root returns the root record when one exists.
func (t *Tracker) Root() (Record, bool) {
	record, ok := t.records[""]
	if !ok {
		return Record{}, false
	}
	return *record, true
}

// Len is the number of stored records.
func (t *Tracker) Len() int {
	return len(t.records)
}

// remove deletes id and every record beneath it. An empty id clears the whole
// terminal, matching the spec's "no id removes every record". It reports
// whether anything was removed.
func (t *Tracker) remove(id string) bool {
	if id == "" {
		changed := len(t.records) > 0
		t.records = make(map[string]*Record)
		return changed
	}
	prefix := id + "/"
	changed := false
	for key := range t.records {
		if key == id || len(key) > len(prefix) && key[:len(prefix)] == prefix {
			delete(t.records, key)
			changed = true
		}
	}
	return changed
}

// evictOldest drops the least-recently-updated record to make room at the cap.
func (t *Tracker) evictOldest() {
	oldest := ""
	var oldestSequence uint64
	for key, record := range t.records {
		if oldest == "" || record.Sequence < oldestSequence {
			oldest = key
			oldestSequence = record.Sequence
		}
	}
	if oldest != "" {
		delete(t.records, oldest)
	}
}

// effectiveApp walks from id toward the root and returns the nearest ancestor's
// app when the record itself does not carry one.
func (t *Tracker) effectiveApp(id, app string) string {
	if app != "" {
		return app
	}
	for current := id; current != ""; {
		slash := lastSlash(current)
		current = current[:slash]
		if ancestor, ok := t.records[current]; ok && ancestor.App != "" {
			return ancestor.App
		}
	}
	return ""
}

func lastSlash(path string) int {
	for i := len(path) - 1; i >= 0; i-- {
		if path[i] == '/' {
			return i
		}
	}
	return 0
}

// visibleEqual compares the fields a client renders. Sequence is excluded on
// purpose: refreshing a record's position in the eviction order is not a change
// anyone can see, and treating it as one would broadcast on every repeat report.
func (r Record) visibleEqual(other Record) bool {
	return r.State == other.State &&
		r.ID == other.ID &&
		r.Kind == other.Kind &&
		r.App == other.App &&
		r.Title == other.Title &&
		r.Msg == other.Msg &&
		r.EffectiveApp == other.EffectiveApp &&
		progressEqual(r.Progress, other.Progress)
}

func progressEqual(a, b *int) bool {
	if a == nil || b == nil {
		return a == nil && b == nil
	}
	return *a == *b
}
