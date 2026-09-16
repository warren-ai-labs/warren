package pane

import (
	"errors"
	"testing"

	"github.com/abcdlsj/warren/Headless/internal/api"
)

func leaf(paneID, sessionID string) api.PaneNode {
	return api.PaneNode{PaneID: paneID, SessionID: sessionID}
}

func branch(axis string, ratio float64, first, second api.PaneNode) api.PaneNode {
	firstCopy, secondCopy := first, second
	return api.PaneNode{Axis: axis, Ratio: ratio, First: &firstCopy, Second: &secondCopy}
}

func TestLeavesReturnsPreorderPaneOrder(t *testing.T) {
	tree := branch(AxisHorizontal, 0.5,
		leaf("p1", "s1"),
		branch(AxisVertical, 0.5, leaf("p2", "s2"), leaf("p3", "s3")),
	)
	if got := []string{"p1", "p2", "p3"}; !equalStrings(ids(Leaves(&tree)), got) {
		t.Fatalf("leaf order = %v, want %v", ids(Leaves(&tree)), got)
	}
	if Count(&tree) != 3 {
		t.Fatalf("count = %d, want 3", Count(&tree))
	}
	if tree.PaneID == "" && tree.Axis == "" {
		t.Fatal("split lost its shape")
	}
}

func TestReconcileDropsEndedSessionsAndCollapsesParents(t *testing.T) {
	tree := branch(AxisHorizontal, 0.5,
		leaf("p1", "s1"),
		branch(AxisVertical, 0.5, leaf("p2", "s2"), leaf("p3", "s3")),
	)
	// s2 ends: its parent split must collapse to the surviving leaf instead of
	// leaving a half-empty split behind.
	reconciled := Reconcile(&tree, func(sessionID string) bool { return sessionID != "s2" })
	if reconciled == nil {
		t.Fatal("expected the surviving panes")
	}
	if Count(reconciled) != 2 {
		t.Fatalf("count = %d, want 2", Count(reconciled))
	}
	if got := []string{"p1", "p3"}; !equalStrings(ids(Leaves(reconciled)), got) {
		t.Fatalf("leaves = %v, want %v", ids(Leaves(reconciled)), got)
	}
	// The surviving leaves keep their pane identity, so a client's focus and
	// pane identity outlive an unrelated session ending.
	if Find(reconciled, "p1") == nil || Find(reconciled, "p3") == nil {
		t.Fatal("surviving leaves lost their pane ids")
	}
}

func TestReconcileReturnsNilWhenNothingSurvives(t *testing.T) {
	tree := branch(AxisHorizontal, 0.5, leaf("p1", "s1"), leaf("p2", "s2"))
	if reconciled := Reconcile(&tree, func(string) bool { return false }); reconciled != nil {
		t.Fatalf("expected nil, got %#v", reconciled)
	}
}

func TestReconcileNormalizesRatios(t *testing.T) {
	tree := branch(AxisHorizontal, 0.98, leaf("p1", "s1"), leaf("p2", "s2"))
	reconciled := Reconcile(&tree, func(string) bool { return true })
	if reconciled.Ratio != MaxRatio {
		t.Fatalf("ratio = %v, want %v", reconciled.Ratio, MaxRatio)
	}
	broken := branch(AxisHorizontal, 1, leaf("p1", "s1"), leaf("p2", "s2"))
	broken.Ratio = 0
	if Normalize(&broken); broken.Ratio != MinRatio {
		t.Fatalf("ratio = %v, want %v", broken.Ratio, MinRatio)
	}
}

func TestSplitKeepsTheOriginalLeafIdentity(t *testing.T) {
	tree := leaf("p1", "s1")
	splitted, err := Split(&tree, "p1", AxisHorizontal, true, leaf("", "s2"))
	if err != nil {
		t.Fatal(err)
	}
	// The original leaf is copied into the new subtree. Splitting in place
	// would leave the split pointing at itself.
	if got := []string{"s2", "s1"}; !equalStrings(Sessions(splitted), got) {
		t.Fatalf("sessions = %v, want %v", Sessions(splitted), got)
	}
	if Find(splitted, "p1") == nil {
		t.Fatal("the original pane lost its identity")
	}
	if splitted.First == splitted || splitted.Second == splitted {
		t.Fatal("split is self-referential")
	}
}

func TestSplitRejectsAnUnknownPaneAndAxis(t *testing.T) {
	tree := leaf("p1", "s1")
	if _, err := Split(&tree, "missing", AxisHorizontal, false, leaf("p2", "s2")); !errors.Is(err, ErrPaneNotFound) {
		t.Fatalf("err = %v, want ErrPaneNotFound", err)
	}
	if _, err := Split(&tree, "p1", "diagonal", false, leaf("p2", "s2")); !errors.Is(err, ErrInvalidTree) {
		t.Fatalf("err = %v, want ErrInvalidTree", err)
	}
}

func TestRemoveCollapsesAndReportsTheLastPane(t *testing.T) {
	tree := branch(AxisHorizontal, 0.5,
		leaf("p1", "s1"),
		branch(AxisVertical, 0.5, leaf("p2", "s2"), leaf("p3", "s3")),
	)
	next, err := Remove(&tree, "p2")
	if err != nil {
		t.Fatal(err)
	}
	if got := []string{"p1", "p3"}; !equalStrings(ids(Leaves(next)), got) {
		t.Fatalf("leaves = %v, want %v", ids(Leaves(next)), got)
	}
	next, err = Remove(next, "p1")
	if err != nil {
		t.Fatal(err)
	}
	last, err := Remove(next, "p3")
	if err != nil {
		t.Fatal(err)
	}
	if last != nil {
		t.Fatalf("removing the last pane = %#v, want nil", last)
	}
	if _, err := Remove(&tree, "missing"); !errors.Is(err, ErrPaneNotFound) {
		t.Fatalf("err = %v, want ErrPaneNotFound", err)
	}
}

func TestAssignPaneIDsFillsOnlyMissingIdentities(t *testing.T) {
	tree := branch(AxisHorizontal, 0.5, leaf("p1", "s1"), leaf("", "s2"))
	counter := 0
	AssignPaneIDs(&tree, func() string {
		counter++
		return "generated-" + string(rune('a'+counter-1))
	})
	if counter != 1 {
		t.Fatalf("assigned %d ids, want 1", counter)
	}
	if Find(&tree, "p1") == nil || Find(&tree, "generated-a") == nil {
		t.Fatalf("unexpected identities: %v", ids(Leaves(&tree)))
	}
}

func TestValidateStructureRejectsMalformedTrees(t *testing.T) {
	cases := map[string]api.PaneNode{
		"leaf without pane id":    {SessionID: "s1"},
		"leaf without session":    {PaneID: "p1"},
		"unknown axis":            {Axis: "diagonal", Ratio: 0.5, First: nodePtr(leaf("p1", "s1")), Second: nodePtr(leaf("p2", "s2"))},
		"missing child":           {Axis: AxisHorizontal, Ratio: 0.5, First: nodePtr(leaf("p1", "s1"))},
		"ratio below range":       {Axis: AxisHorizontal, Ratio: 0.01, First: nodePtr(leaf("p1", "s1")), Second: nodePtr(leaf("p2", "s2"))},
		"duplicate pane id":       branch(AxisHorizontal, 0.5, leaf("p1", "s1"), leaf("p1", "s2")),
		"duplicate session":       branch(AxisHorizontal, 0.5, leaf("p1", "s1"), leaf("p2", "s1")),
		"leaf carrying children":  {PaneID: "p1", SessionID: "s1", First: nodePtr(leaf("p2", "s2"))},
		"split carrying leaf ids": {PaneID: "p1", Axis: AxisHorizontal, Ratio: 0.5, First: nodePtr(leaf("p1", "s1")), Second: nodePtr(leaf("p2", "s2"))},
	}
	for name, tree := range cases {
		t.Run(name, func(t *testing.T) {
			if err := ValidateStructure(&tree); err == nil {
				t.Fatalf("expected a rejection for %#v", tree)
			}
		})
	}
	valid := branch(AxisHorizontal, 0.5,
		leaf("p1", "s1"),
		branch(AxisVertical, 0.5, leaf("p2", "s2"), leaf("p3", "s3")),
	)
	if err := ValidateStructure(&valid); err != nil {
		t.Fatalf("valid tree rejected: %v", err)
	}
}

func TestValidateStructureEnforcesThePaneCap(t *testing.T) {
	tree := leaf("p0", "s0")
	for index := 1; index < MaxPanes; index++ {
		splitted, err := Split(&tree, "p"+itoa(index-1), AxisHorizontal, false, leaf("p"+itoa(index), "s"+itoa(index)))
		if err != nil {
			t.Fatal(err)
		}
		tree = *splitted
	}
	if Count(&tree) != MaxPanes {
		t.Fatalf("count = %d, want %d", Count(&tree), MaxPanes)
	}
	if err := ValidateStructure(&tree); err != nil {
		t.Fatalf("tree at the cap rejected: %v", err)
	}
	five, err := Split(&tree, "p0", AxisVertical, false, leaf("p5", "s5"))
	if err != nil {
		t.Fatal(err)
	}
	if err := ValidateStructure(five); !errors.Is(err, ErrTooManyPanes) {
		t.Fatalf("err = %v, want ErrTooManyPanes", err)
	}
}

func TestValidateStructureRejectsNonFiniteRatio(t *testing.T) {
	tree := branch(AxisHorizontal, 0.5, leaf("p1", "s1"), leaf("p2", "s2"))
	tree.Ratio = ratioNaN()
	if err := ValidateStructure(&tree); !errors.Is(err, ErrInvalidTree) {
		t.Fatalf("err = %v, want ErrInvalidTree", err)
	}
}

func ids(leaves []*api.PaneNode) []string {
	result := make([]string, 0, len(leaves))
	for _, leaf := range leaves {
		result = append(result, leaf.PaneID)
	}
	return result
}

func nodePtr(node api.PaneNode) *api.PaneNode { return &node }

func equalStrings(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for index := range a {
		if a[index] != b[index] {
			return false
		}
	}
	return true
}

func itoa(value int) string {
	if value == 0 {
		return "0"
	}
	digits := ""
	for value > 0 {
		digits = string(rune('0'+value%10)) + digits
		value /= 10
	}
	return digits
}

func ratioNaN() float64 {
	var zero float64
	return zero / zero
}
