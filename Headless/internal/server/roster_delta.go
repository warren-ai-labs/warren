package server

import (
	"reflect"
	"slices"

	"github.com/abcdlsj/warren/Headless/internal/api"
)

// rosterDeltaMessage contains only the roster entities that changed after a
// client-known Store revision. Order is sent separately because an entity can
// move without any of its visible fields changing.
type rosterDeltaMessage struct {
	Type         string                                `json:"t"`
	BaseRevision uint64                                `json:"baseRevision"`
	Revision     uint64                                `json:"revision"`
	Host         *api.Host                             `json:"host,omitempty"`
	Tasks        *rosterEntityDelta[api.Task]          `json:"tasks,omitempty"`
	Projects     *rosterEntityDelta[api.Project]       `json:"projects,omitempty"`
	Workspaces   *rosterEntityDelta[api.Workspace]     `json:"workspaces,omitempty"`
	Groups       *rosterEntityDelta[api.TerminalGroup] `json:"terminalGroups,omitempty"`
	PaneGroups   *rosterEntityDelta[api.PaneGroup]     `json:"paneGroups,omitempty"`
	Sessions     *rosterEntityDelta[api.Session]       `json:"sessions,omitempty"`
	// SessionMetadata carries high-frequency foreground metadata that changes
	// on every prompt or `cd`. Keeping it out of the Session entity keeps a
	// directory change from retransmitting the whole Session and its agent
	// projection over a Relay link.
	SessionMetadata *rosterSessionMetadataDelta `json:"sessionMetadata,omitempty"`
}

type rosterEntityDelta[T any] struct {
	Upsert []T      `json:"upsert,omitempty"`
	Remove []string `json:"remove,omitempty"`
	Order  []string `json:"order,omitempty"`
}

// rosterSessionMetadataDelta is an upsert-only per-session diff. A session
// never leaves the roster through this message; removal still travels in the
// Session entity delta. The fields are not optional on the client: an omitted
// value means the field is empty, not unchanged.
type rosterSessionMetadataDelta struct {
	Upsert []rosterSessionMetadata `json:"upsert,omitempty"`
}

type rosterSessionMetadata struct {
	ID          string `json:"id"`
	Process     string `json:"process,omitempty"`
	CommandLine string `json:"commandLine,omitempty"`
	Directory   string `json:"directory,omitempty"`
}

func makeRosterDelta(before, after api.State, baseRevision, revision uint64) rosterDeltaMessage {
	result := rosterDeltaMessage{
		Type:         "roster.delta",
		BaseRevision: baseRevision,
		Revision:     revision,
	}
	if !reflect.DeepEqual(before.Host, after.Host) {
		host := after.Host
		result.Host = &host
	}
	if delta := rosterEntries(before.Tasks, after.Tasks, func(value api.Task) string { return value.ID }); delta.hasChanges() {
		result.Tasks = &delta
	}
	if delta := rosterEntries(before.Projects, after.Projects, func(value api.Project) string { return value.ID }); delta.hasChanges() {
		result.Projects = &delta
	}
	if delta := rosterEntries(before.Workspaces, after.Workspaces, func(value api.Workspace) string { return value.ID }); delta.hasChanges() {
		result.Workspaces = &delta
	}
	if delta := rosterEntries(before.TerminalGroups, after.TerminalGroups, func(value api.TerminalGroup) string { return value.ID }); delta.hasChanges() {
		result.Groups = &delta
	}
	if delta := rosterEntries(before.PaneGroups, after.PaneGroups, func(value api.PaneGroup) string { return value.ID }); delta.hasChanges() {
		result.PaneGroups = &delta
	}
	sessionDelta := rosterEntriesWithEqual(
		before.Sessions,
		after.Sessions,
		func(value api.Session) string { return value.ID },
		sessionsEqualIgnoringMetadata,
	)
	if sessionDelta.hasChanges() {
		result.Sessions = &sessionDelta
	}
	if metadata := rosterSessionMetadataChanges(before.Sessions, after.Sessions, sessionDelta.Upsert); len(metadata.Upsert) > 0 {
		result.SessionMetadata = &metadata
	}
	return result
}

// sessionsEqualIgnoringMetadata compares everything a client needs to
// re-render the Session entity. The foreground metadata is excluded because it
// travels in the dedicated metadata delta.
func sessionsEqualIgnoringMetadata(a, b api.Session) bool {
	a.Process, a.CommandLine, a.Directory = "", "", ""
	b.Process, b.CommandLine, b.Directory = "", "", ""
	return reflect.DeepEqual(a, b)
}

// rosterSessionMetadataChanges reports sessions whose metadata changed without
// any other Session field changing. Sessions already present in the entity
// upsert carry their metadata there, so they are skipped here.
func rosterSessionMetadataChanges(before, after []api.Session, entityUpsert []api.Session) rosterSessionMetadataDelta {
	skip := make(map[string]struct{}, len(entityUpsert))
	for _, session := range entityUpsert {
		skip[session.ID] = struct{}{}
	}
	beforeByID := make(map[string]api.Session, len(before))
	for _, session := range before {
		beforeByID[session.ID] = session
	}
	result := rosterSessionMetadataDelta{}
	for _, session := range after {
		if _, ok := skip[session.ID]; ok {
			continue
		}
		previous, ok := beforeByID[session.ID]
		if !ok {
			continue
		}
		if previous.Process == session.Process &&
			previous.CommandLine == session.CommandLine &&
			previous.Directory == session.Directory {
			continue
		}
		result.Upsert = append(result.Upsert, rosterSessionMetadata{
			ID:          session.ID,
			Process:     session.Process,
			CommandLine: session.CommandLine,
			Directory:   session.Directory,
		})
	}
	return result
}

func (m rosterDeltaMessage) hasChanges() bool {
	return m.Host != nil || m.Tasks != nil || m.Projects != nil || m.Workspaces != nil || m.Groups != nil || m.Sessions != nil || m.SessionMetadata != nil
}

func (d rosterEntityDelta[T]) hasChanges() bool {
	return len(d.Upsert) > 0 || len(d.Remove) > 0 || len(d.Order) > 0
}

func rosterEntries[T any](before, after []T, id func(T) string) rosterEntityDelta[T] {
	return rosterEntriesWithEqual(before, after, id, func(a, b T) bool { return reflect.DeepEqual(a, b) })
}

func rosterEntriesWithEqual[T any](before, after []T, id func(T) string, equal func(T, T) bool) rosterEntityDelta[T] {
	beforeByID := make(map[string]T, len(before))
	for _, value := range before {
		beforeByID[id(value)] = value
	}
	afterByID := make(map[string]T, len(after))
	orderBefore := make([]string, 0, len(before))
	orderAfter := make([]string, 0, len(after))
	result := rosterEntityDelta[T]{}
	for _, value := range before {
		orderBefore = append(orderBefore, id(value))
	}
	for _, value := range after {
		key := id(value)
		afterByID[key] = value
		orderAfter = append(orderAfter, key)
		if previous, ok := beforeByID[key]; !ok || !equal(previous, value) {
			result.Upsert = append(result.Upsert, value)
		}
	}
	for _, value := range before {
		if _, ok := afterByID[id(value)]; !ok {
			result.Remove = append(result.Remove, id(value))
		}
	}
	if !slices.Equal(orderBefore, orderAfter) {
		result.Order = orderAfter
	}
	return result
}
