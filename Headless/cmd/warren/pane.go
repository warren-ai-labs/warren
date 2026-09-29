package main

import (
	"context"
	"fmt"
	"strconv"
	"strings"

	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/client"
	"github.com/abcdlsj/warren/Headless/internal/pane"
)

// ScreenPaneRow flattens one Session's arrangement and screens for tabular
// output. The GROUP/PANE cells describe the durable Host arrangement, which
// exists whether or not any client is connected; the SCREEN cell names a
// connected client that is displaying the Session right now, so a Session
// displayed by two windows at once stays readable as two groups of rows.
type ScreenPaneRow struct {
	Screen     int    `json:"screen,omitempty"`
	Group      string `json:"group"`
	GroupName  string `json:"groupName,omitempty"`
	Revision   uint64 `json:"revision,omitempty"`
	Pane       int    `json:"pane"`
	PaneID     string `json:"paneId"`
	SessionID  string `json:"sessionId"`
	Title      string `json:"title,omitempty"`
	Current    bool   `json:"current,omitempty"`
	Displayed  bool   `json:"displayed,omitempty"`
	OnScreenAt int    `json:"onScreenPane,omitempty"`
}

// screenPaneRows joins the Host's arrangement with the peer telemetry: the
// roster says how the Session is arranged, `screen.panes` says who is showing
// it. A Session in no group is reported once with a blank group, so "not
// arranged" stays distinguishable from "not displayed".
func screenPaneRows(state api.State, sessionID string, result api.ScreenPanesResult) []ScreenPaneRow {
	displayedAt := make(map[string]int)
	for index, screen := range result.Screens {
		for _, pane := range screen.Panes {
			if pane.SessionID == sessionID {
				displayedAt[pane.SessionID] = index + 1
			}
		}
	}
	titles := make(map[string]string, len(state.Sessions))
	for _, session := range state.Sessions {
		title := session.CustomTitle
		if strings.TrimSpace(title) == "" {
			title = session.Title
		}
		titles[session.ID] = title
	}
	for _, group := range state.PaneGroups {
		for index, leaf := range pane.Leaves(&group.Tree) {
			if leaf.SessionID != sessionID {
				continue
			}
			return []ScreenPaneRow{{
				Screen:     displayedAt[sessionID],
				Group:      group.ID,
				GroupName:  group.Name,
				Revision:   group.Revision,
				Pane:       index + 1,
				PaneID:     leaf.PaneID,
				SessionID:  leaf.SessionID,
				Title:      titles[leaf.SessionID],
				Current:    true,
				Displayed:  displayedAt[sessionID] > 0,
				OnScreenAt: displayedAt[sessionID],
			}}
		}
	}
	// No arrangement holds the Session: fall back to what connected clients are
	// showing, so an unplaced Tab stays readable.
	if len(result.Screens) == 0 {
		return nil
	}
	rows := make([]ScreenPaneRow, 0, len(result.Screens))
	for _, screen := range result.Screens {
		for _, pane := range screen.Panes {
			rows = append(rows, ScreenPaneRow{
				Pane:       pane.Index,
				SessionID:  pane.SessionID,
				Title:      pane.Title,
				Current:    pane.Current,
				Displayed:  true,
				Screen:     screen.Position,
				OnScreenAt: screen.Position,
			})
		}
	}
	return rows
}

func screenPaneRowCells(row ScreenPaneRow) []string {
	screen := "-"
	if row.Displayed {
		screen = strconv.Itoa(row.Screen)
	}
	revision := "-"
	if row.Revision > 0 {
		revision = strconv.FormatUint(row.Revision, 10)
	}
	return []string{
		displayValue(row.Group),
		displayValue(row.GroupName),
		strconv.Itoa(row.Pane),
		displayValue(row.PaneID),
		row.SessionID,
		displayValue(row.Title),
		revision,
		screen,
		displayBool(row.Current),
	}
}

// filterPaneGroupRows applies `--workspace`, `--group`, and `--search` to the
// roster's arrangements. It never opens a second request: the roster is the
// list.
func filterPaneGroupRows(groups []api.PaneGroup, params map[string]any) ([]api.PaneGroup, error) {
	workspaceID := stringValue(params, "workspace")
	groupID := stringValue(params, "group")
	if workspaceID != "" && groupID != "" {
		return nil, fmt.Errorf("--workspace and --group are mutually exclusive")
	}
	search := strings.ToLower(strings.TrimSpace(stringValue(params, "search")))
	result := make([]api.PaneGroup, 0, len(groups))
	for _, group := range groups {
		if workspaceID != "" && group.WorkspaceID != workspaceID {
			continue
		}
		if groupID != "" && group.TerminalGroupID != groupID {
			continue
		}
		if search != "" {
			haystack := strings.ToLower(group.ID + " " + group.Name + " " + group.OwnerID())
			if !strings.Contains(haystack, search) {
				continue
			}
		}
		result = append(result, group)
	}
	return result, nil
}

func paneGroupRowCells(group api.PaneGroup) []string {
	owner := group.WorkspaceID
	if group.TerminalGroupID != "" {
		owner = group.TerminalGroupID
	}
	return []string{
		group.ID,
		group.OwnerScope(),
		displayValue(owner),
		displayValue(group.Name),
		strconv.Itoa(pane.Count(&group.Tree)),
		strconv.Itoa(group.Order),
		strconv.FormatUint(group.Revision, 10),
		strings.Join(pane.Sessions(&group.Tree), ","),
	}
}

// paneGroupContaining finds the group that shows one pane, or that holds one
// Session when paneID is empty.
func paneGroupContaining(state api.State, paneID, sessionID string) (api.PaneGroup, bool) {
	for _, group := range state.PaneGroups {
		if paneID != "" {
			if pane.Find(&group.Tree, paneID) != nil {
				return group, true
			}
			continue
		}
		for _, leaf := range pane.Leaves(&group.Tree) {
			if leaf.SessionID == sessionID {
				return group, true
			}
		}
	}
	return api.PaneGroup{}, false
}

// paneSplit reads the arrangement from the roster, adds one pane around an
// existing Session, and writes the replacement tree back under the revision it
// observed. The read-compute-write is one compare-and-swap: a concurrent edit
// fails with a revision conflict instead of being overwritten.
func paneSplit(ctx context.Context, c *client.Client, params map[string]any) error {
	paneID := stringValue(params, "pane")
	sessionID := stringValue(params, "session")
	axis := pane.AxisHorizontal
	switch strings.ToLower(stringValue(params, "axis")) {
	case "", pane.AxisHorizontal:
	case pane.AxisVertical:
		axis = pane.AxisVertical
	default:
		return newUsageError("--axis must be horizontal or vertical", actionUsageText("pane", "split"))
	}
	state, err := c.Roster(ctx)
	if err != nil {
		return err
	}
	group, ok := paneGroupContaining(state, paneID, "")
	if !ok {
		return fmt.Errorf("pane group not found for pane: %s", paneID)
	}
	for _, existing := range pane.Leaves(&group.Tree) {
		if existing.SessionID == sessionID {
			return fmt.Errorf("pane group session in use: %s is already shown by pane group %s", sessionID, group.ID)
		}
	}
	before := boolValue(params, "before")
	tree := clonePaneTree(&group.Tree)
	// Split returns the new root: splitting the root leaf replaces it rather
	// than mutating in place, so the returned value has to be used.
	splitted, err := pane.Split(tree, paneID, axis, before, api.PaneNode{SessionID: sessionID})
	if err != nil {
		return err
	}
	tree = splitted
	var updated api.PaneGroup
	if err := c.Request(ctx, "pane-group.update", map[string]any{
		"id":               group.ID,
		"tree":             tree,
		"expectedRevision": group.Revision,
	}, &updated); err != nil {
		return err
	}
	return printValue(updated)
}

// paneClose removes one pane from its arrangement. The Session keeps running:
// closing a pane is a layout edit, and ending a Session stays an explicit
// Session command. The last pane of a group removes the group.
func paneClose(ctx context.Context, c *client.Client, params map[string]any) error {
	paneID := stringValue(params, "pane")
	state, err := c.Roster(ctx)
	if err != nil {
		return err
	}
	group, ok := paneGroupContaining(state, paneID, "")
	if !ok {
		return fmt.Errorf("pane group not found for pane: %s", paneID)
	}
	tree := clonePaneTree(&group.Tree)
	next, err := pane.Remove(tree, paneID)
	if err != nil {
		return err
	}
	if next == nil {
		var removed map[string]any
		if err := c.Request(ctx, "pane-group.remove", map[string]any{"id": group.ID}, &removed); err != nil {
			return err
		}
		return printValue(map[string]any{"closed": true, "groupRemoved": true, "session": group.Tree.SessionID})
	}
	var updated api.PaneGroup
	if err := c.Request(ctx, "pane-group.update", map[string]any{
		"id":               group.ID,
		"tree":             next,
		"expectedRevision": group.Revision,
	}, &updated); err != nil {
		return err
	}
	return printValue(updated)
}

// clonePaneTree copies a tree before a local edit, so a failed request cannot
// leave a mutation on the caller's roster value.
func clonePaneTree(node *api.PaneNode) *api.PaneNode {
	if node == nil {
		return nil
	}
	cloned := &api.PaneNode{
		PaneID:    node.PaneID,
		SessionID: node.SessionID,
		Axis:      node.Axis,
		Ratio:     node.Ratio,
	}
	cloned.First = clonePaneTree(node.First)
	cloned.Second = clonePaneTree(node.Second)
	return cloned
}
