package git

import (
	"strconv"
	"strings"
)

// LineCount is the added/deleted line total of one path in a diff.
type LineCount struct {
	Added   int
	Deleted int
}

// applyCounts folds numstat counts into one change. Rename entries
// (RenameFrom set) also absorb the old path's deletions so a rename shows as
// +M -N.
func applyCounts(change *Change, counts map[string]LineCount) {
	line := counts[change.Path]
	change.Added = line.Added
	change.Deleted = line.Deleted
	if change.RenameFrom != "" {
		if old, ok := counts[change.RenameFrom]; ok {
			change.Added += old.Added
			change.Deleted += old.Deleted
		}
	}
}

// parseNumstat reads git diff/log --numstat output. With -z entries are
// NUL-delimited; without -z they are newline-delimited. Regular files appear
// as "add\tdelete\tpath". Renames appear as "add\tdelete\told => new" without
// -z, or as "add\tdelete" followed by separate old/new tokens with -z. The
// merged rename is credited to the new path. Binary files report "-" for both
// counts and parse to zero.
func parseNumstat(block string) map[string]LineCount {
	tokens := strings.FieldsFunc(block, func(r rune) bool { return r == '\x00' || r == '\n' })
	counts := make(map[string]LineCount)
	for i := 0; i < len(tokens); i++ {
		parts := strings.SplitN(tokens[i], "\t", 3)
		if len(parts) < 2 {
			continue
		}
		added, ok := numstatCount(parts[0])
		if !ok {
			continue
		}
		deleted, ok := numstatCount(parts[1])
		if !ok {
			continue
		}
		if len(parts) == 3 && parts[2] != "" {
			path := parts[2]
			if oldNew := strings.SplitN(path, " => ", 2); len(oldNew) == 2 {
				path = oldNew[1]
			}
			counts[path] = LineCount{Added: added, Deleted: deleted}
			continue
		}
		// -z rename: "add\tdelete\t" followed by old and new path tokens.
		if i+2 < len(tokens) {
			counts[tokens[i+2]] = LineCount{Added: added, Deleted: deleted}
			i += 2
		}
	}
	return counts
}

func numstatCount(value string) (int, bool) {
	if value == "-" {
		return 0, true
	}
	count, err := strconv.Atoi(value)
	if err != nil {
		return 0, false
	}
	return count, true
}
