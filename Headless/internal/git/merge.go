package git

import (
	"context"
	"errors"
	"os/exec"
	"strconv"
	"strings"
)

// BranchBase returns the commit a branch was created from, as recorded by the
// oldest entry of its reflog. Git writes "branch: Created from ..." there when
// it creates a branch, so this is the only durable evidence for branches
// Warren did not create itself. A trimmed reflog, a branch created with
// reflogs disabled, or a branch that was re-pointed without a creation entry
// reports unknown.
func BranchBase(ctx context.Context, dir, branch string) (string, bool) {
	output, err := run(ctx, dir, "reflog", "show", "--format=%H%x00%gs", "refs/heads/"+branch)
	if err != nil {
		return "", false
	}
	lines := strings.Split(strings.TrimRight(output, "\n"), "\n")
	oid, message, found := strings.Cut(lines[len(lines)-1], "\x00")
	if !found || oid == "" || !strings.HasPrefix(message, "branch: Created from ") {
		return "", false
	}
	return oid, true
}

// MergedIntoTarget reports whether the branch's own commits are contained in
// target, and whether the answer could be determined. base is the commit the
// branch was created from when it is known; an empty base means the caller
// has no record of it.
//
// A branch that still sits on its creation point has no commits of its own,
// so it is never merged; without that rule a freshly created branch would
// look merged because it carries no diff against the default branch.
func MergedIntoTarget(ctx context.Context, dir, target, branch, base string) (merged, known bool) {
	branchOID, err := resolveCommit(ctx, dir, branch)
	if err != nil {
		return false, false
	}
	targetOID, err := resolveCommit(ctx, dir, target)
	if err != nil {
		return false, false
	}
	if base != "" {
		if branchOID == base {
			return false, true
		}
	} else if branchOID == targetOID {
		return false, true
	}
	// Every commit of the branch is already reachable from target: a merge
	// commit or a fast-forward, which the path comparison below would miss
	// once target moved on past the shared paths.
	if ancestor, err := isAncestor(ctx, dir, branchOID, targetOID); err != nil {
		return false, false
	} else if ancestor {
		return true, true
	}
	return branchChangesIncluded(ctx, dir, target, branchOID, base)
}

// isAncestor reports whether ancestor is reachable from descendant.
func isAncestor(ctx context.Context, dir, ancestor, descendant string) (bool, error) {
	output, err := run(ctx, dir, "rev-list", "--count", descendant+".."+ancestor)
	if err != nil {
		return false, err
	}
	count, err := strconv.Atoi(strings.TrimSpace(output))
	if err != nil {
		return false, err
	}
	return count == 0, nil
}

// branchChangesIncluded compares only the paths the branch changed since it
// started from diffBase. An empty path list means there is nothing unique to
// compare, which counts as merged.
func branchChangesIncluded(ctx context.Context, dir, target, branchOID, base string) (merged, known bool) {
	if base == "" {
		output, err := run(ctx, dir, "merge-base", target, branchOID)
		if err != nil {
			return false, false
		}
		base = strings.TrimSpace(output)
		if base == "" {
			return false, false
		}
	}
	pathsOutput, err := run(ctx, dir, "diff", "--name-only", "-z", "--no-renames", base, branchOID)
	if err != nil {
		return false, false
	}
	var paths []string
	for _, path := range strings.Split(strings.TrimRight(pathsOutput, "\x00"), "\x00") {
		if path != "" {
			paths = append(paths, path)
		}
	}
	if len(paths) == 0 {
		return true, true
	}
	args := append([]string{"--literal-pathspecs", "diff", "--quiet", branchOID, target, "--"}, paths...)
	_, err = run(ctx, dir, args...)
	if err == nil {
		return true, true
	}
	// git diff --quiet signals "differences found" with exit status 1.
	var gitErr *Error
	if errors.As(err, &gitErr) {
		var exitErr *exec.ExitError
		if errors.As(gitErr.Err, &exitErr) && exitErr.ExitCode() == 1 {
			return false, true
		}
	}
	return false, false
}
