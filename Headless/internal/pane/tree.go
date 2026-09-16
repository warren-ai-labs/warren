// Package pane holds the pure layout algebra for Host-owned Pane Groups.
//
// A Pane Group is one whole-screen arrangement of running Sessions. The tree is
// the single source of pane membership, pane order, and geometry: pane order is
// preorder leaf order, and a pane's 1-based index is always derived, never
// stored. Every function here is pure so the reconciliation rules can be tested
// without a store, a Host, or a client.
package pane

import (
	"errors"
	"fmt"
	"math"

	"github.com/abcdlsj/warren/Headless/internal/api"
)

const (
	// AxisHorizontal splits left and right; AxisVertical splits top and bottom.
	AxisHorizontal = "horizontal"
	AxisVertical   = "vertical"

	// MaxPanes is the visible-pane cap of one arrangement. It is a product and
	// performance boundary: one arrangement is rendered at a time, and a surface
	// budget of four is what the Desktop and Ghostty adapters were measured at.
	MaxPanes = 4

	// MaxGroupsPerOwner bounds how many arrangements one Workspace or Terminal
	// Group may hold. The limit is a top-bar and product boundary, not a
	// performance one, because only one group is ever rendered.
	MaxGroupsPerOwner = 8

	// MinRatio and MaxRatio clamp a divider so a pane can never be dragged to a
	// zero-sized terminal.
	MinRatio = 0.15
	MaxRatio = 0.85

	// MaxNameLength bounds a user-supplied group name.
	MaxNameLength = 120
)

var (
	// ErrPaneNotFound reports a Pane ID that is not in the tree.
	ErrPaneNotFound = errors.New("pane not found")
	// ErrInvalidTree reports a malformed tree.
	ErrInvalidTree = errors.New("invalid pane tree")
	// ErrTooManyPanes reports a tree above MaxPanes.
	ErrTooManyPanes = errors.New("pane tree exceeds the visible pane cap")
)

// Leaves returns the leaf nodes in preorder, which is the order a client renders
// and numbers them in.
func Leaves(root *api.PaneNode) []*api.PaneNode {
	if root == nil {
		return nil
	}
	if root.Axis == "" {
		return []*api.PaneNode{root}
	}
	result := Leaves(root.First)
	return append(result, Leaves(root.Second)...)
}

// Count returns the number of leaves in the tree.
func Count(root *api.PaneNode) int { return len(Leaves(root)) }

// Sessions returns the Session IDs in preorder.
func Sessions(root *api.PaneNode) []string {
	leaves := Leaves(root)
	result := make([]string, 0, len(leaves))
	for _, leaf := range leaves {
		result = append(result, leaf.SessionID)
	}
	return result
}

// Find returns the leaf carrying paneID, or nil.
func Find(root *api.PaneNode, paneID string) *api.PaneNode {
	for _, leaf := range Leaves(root) {
		if leaf.PaneID == paneID {
			return leaf
		}
	}
	return nil
}

// Normalize clamps every ratio into the interactive range and repairs a
// non-finite value. Decoded state predates ratio validation, so this runs on
// every path that can reach a renderer.
func Normalize(node *api.PaneNode) {
	if node == nil || node.Axis == "" {
		return
	}
	switch {
	case !isFinite(node.Ratio):
		node.Ratio = 0.5
	case node.Ratio < MinRatio:
		node.Ratio = MinRatio
	case node.Ratio > MaxRatio:
		node.Ratio = MaxRatio
	}
	Normalize(node.First)
	Normalize(node.Second)
}

func isFinite(value float64) bool {
	return !math.IsNaN(value) && !math.IsInf(value, 0)
}

// Reconcile drops leaves that keep rejects, collapses a split whose sibling
// disappeared, and normalizes the surviving ratios. A surviving leaf keeps its
// Pane ID and Session ID, so a client's focus and its pane identity outlive an
// unrelated Session ending. It returns nil when no leaf survives, which the
// caller reads as "delete the group".
func Reconcile(node *api.PaneNode, keep func(sessionID string) bool) *api.PaneNode {
	if node == nil {
		return nil
	}
	if node.Axis == "" {
		if node.SessionID == "" || !keep(node.SessionID) {
			return nil
		}
		return node
	}
	first := Reconcile(node.First, keep)
	second := Reconcile(node.Second, keep)
	switch {
	case first == nil && second == nil:
		return nil
	case first == nil:
		return second
	case second == nil:
		return first
	}
	node.First, node.Second = first, second
	Normalize(node)
	return node
}

// Split replaces the leaf paneID with a split that keeps the original leaf and
// adds leaf on the requested side. The original leaf keeps its Pane ID, so only
// the newly created pane needs an identity.
//
// It returns the new root: splitting the root leaf replaces that node instead of
// mutating it, so callers must use the returned value.
func Split(root *api.PaneNode, paneID, axis string, before bool, leaf api.PaneNode) (*api.PaneNode, error) {
	if axis != AxisHorizontal && axis != AxisVertical {
		return nil, fmt.Errorf("%w: unknown axis %q", ErrInvalidTree, axis)
	}
	next, found := split(root, paneID, axis, before, leaf)
	if !found {
		return nil, ErrPaneNotFound
	}
	return next, nil
}

func split(node *api.PaneNode, paneID, axis string, before bool, leaf api.PaneNode) (*api.PaneNode, bool) {
	if node == nil {
		return nil, false
	}
	if node.Axis == "" {
		if node.PaneID != paneID {
			return node, false
		}
		// The original leaf is copied into the new subtree: assigning over the
		// node in place would leave the split pointing at itself.
		original := &api.PaneNode{PaneID: node.PaneID, SessionID: node.SessionID}
		first, second := original, &leaf
		if before {
			first, second = second, first
		}
		return &api.PaneNode{Axis: axis, Ratio: 0.5, First: first, Second: second}, true
	}
	if first, found := split(node.First, paneID, axis, before, leaf); found {
		node.First = first
		return node, true
	}
	if second, found := split(node.Second, paneID, axis, before, leaf); found {
		node.Second = second
		return node, true
	}
	return node, false
}

// Remove drops the leaf paneID and collapses a parent left with one child. It
// returns nil when the removed leaf was the last one, which the caller reads as
// "delete the group". The returned value is the new root and must be used.
func Remove(root *api.PaneNode, paneID string) (*api.PaneNode, error) {
	next, found := remove(root, paneID)
	if !found {
		return nil, ErrPaneNotFound
	}
	return next, nil
}

// remove reports the subtree after the removal, with found=false when paneID is
// not in this subtree. A nil subtree with found=true means "this subtree was
// exactly the removed leaf", which is the caller's signal to collapse.
func remove(node *api.PaneNode, paneID string) (*api.PaneNode, bool) {
	if node == nil {
		return nil, false
	}
	if node.Axis == "" {
		if node.PaneID != paneID {
			return node, false
		}
		return nil, true
	}
	if first, found := remove(node.First, paneID); found {
		if first == nil {
			return node.Second, true
		}
		node.First = first
		return node, true
	}
	if second, found := remove(node.Second, paneID); found {
		if second == nil {
			return node.First, true
		}
		node.Second = second
		return node, true
	}
	return node, false
}

// AssignPaneIDs fills every leaf that has no Pane ID with a freshly generated
// one. Pane identity is Host-owned: a client sends an empty Pane ID for a pane
// it is creating and reads the assigned identity back from the roster.
func AssignPaneIDs(root *api.PaneNode, newID func() string) {
	if root == nil {
		return
	}
	if root.Axis == "" {
		if root.PaneID == "" {
			root.PaneID = newID()
		}
		return
	}
	AssignPaneIDs(root.First, newID)
	AssignPaneIDs(root.Second, newID)
}

// HasPaneID reports whether every leaf already carries a Pane ID.
func HasPaneID(root *api.PaneNode) bool {
	for _, leaf := range Leaves(root) {
		if leaf.PaneID == "" {
			return false
		}
	}
	return true
}

// ValidateStructure rejects a malformed tree. It deliberately does not know
// about Sessions or owners; ownership and liveness are the service's business.
func ValidateStructure(root *api.PaneNode) error {
	if root == nil {
		return fmt.Errorf("%w: empty tree", ErrInvalidTree)
	}
	if err := validateNode(root, 0); err != nil {
		return err
	}
	if count := Count(root); count > MaxPanes {
		return fmt.Errorf("%w: %d panes", ErrTooManyPanes, count)
	}
	paneIDs := make(map[string]struct{})
	sessions := make(map[string]struct{})
	for _, leaf := range Leaves(root) {
		if _, duplicate := paneIDs[leaf.PaneID]; duplicate {
			return fmt.Errorf("%w: duplicate pane id %s", ErrInvalidTree, leaf.PaneID)
		}
		paneIDs[leaf.PaneID] = struct{}{}
		if _, duplicate := sessions[leaf.SessionID]; duplicate {
			return fmt.Errorf("%w: session %s appears twice", ErrInvalidTree, leaf.SessionID)
		}
		sessions[leaf.SessionID] = struct{}{}
	}
	return nil
}

func validateNode(node *api.PaneNode, depth int) error {
	if depth > MaxPanes {
		return fmt.Errorf("%w: tree is deeper than the pane cap", ErrInvalidTree)
	}
	if node.Axis == "" {
		if node.PaneID == "" || node.SessionID == "" {
			return fmt.Errorf("%w: leaf needs a pane id and a session", ErrInvalidTree)
		}
		if node.First != nil || node.Second != nil {
			return fmt.Errorf("%w: leaf carries split children", ErrInvalidTree)
		}
		return nil
	}
	if node.PaneID != "" || node.SessionID != "" {
		return fmt.Errorf("%w: split carries leaf fields", ErrInvalidTree)
	}
	if node.Axis != AxisHorizontal && node.Axis != AxisVertical {
		return fmt.Errorf("%w: unknown axis %q", ErrInvalidTree, node.Axis)
	}
	if !isFinite(node.Ratio) || node.Ratio < MinRatio || node.Ratio > MaxRatio {
		return fmt.Errorf("%w: ratio %v is outside [%v, %v]", ErrInvalidTree, node.Ratio, MinRatio, MaxRatio)
	}
	if node.First == nil || node.Second == nil {
		return fmt.Errorf("%w: split needs two children", ErrInvalidTree)
	}
	if err := validateNode(node.First, depth+1); err != nil {
		return err
	}
	return validateNode(node.Second, depth+1)
}
