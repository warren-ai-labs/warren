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
	Sessions     *rosterEntityDelta[api.Session]       `json:"sessions,omitempty"`
	// A pointer to a pointer lets the delta distinguish "unchanged" (outer
	// pointer nil) from "cleared" (outer pointer non-nil, inner pointer nil).
	// The latter must be encoded as an explicit JSON null so clients can retire
	// a migration report without waiting for a reconnect.
	GhostlineMigration **api.GhostlineMigration `json:"ghostlineMigration,omitempty"`
}

type rosterEntityDelta[T any] struct {
	Upsert []T      `json:"upsert,omitempty"`
	Remove []string `json:"remove,omitempty"`
	Order  []string `json:"order,omitempty"`
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
	if delta := rosterEntries(before.Sessions, after.Sessions, func(value api.Session) string { return value.ID }); delta.hasChanges() {
		result.Sessions = &delta
	}
	if !reflect.DeepEqual(before.GhostlineMigration, after.GhostlineMigration) {
		migration := after.GhostlineMigration
		result.GhostlineMigration = &migration
	}
	return result
}

func (m rosterDeltaMessage) hasChanges() bool {
	return m.Host != nil || m.Tasks != nil || m.Projects != nil || m.Workspaces != nil || m.Groups != nil || m.Sessions != nil || m.GhostlineMigration != nil
}

func (d rosterEntityDelta[T]) hasChanges() bool {
	return len(d.Upsert) > 0 || len(d.Remove) > 0 || len(d.Order) > 0
}

func rosterEntries[T any](before, after []T, id func(T) string) rosterEntityDelta[T] {
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
		if previous, ok := beforeByID[key]; !ok || !reflect.DeepEqual(previous, value) {
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
