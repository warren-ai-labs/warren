package git

import (
	"context"
	"errors"
	"strconv"
	"strings"
	"time"
)

// FileChange is one file touched by a commit, as reported by --name-status,
// with added/deleted line counts merged from --numstat.
type FileChange struct {
	Path       string
	Status     string
	RenameFrom string
	Added      int
	Deleted    int
}

// Commit is one entry of a workspace's commit history.
type Commit struct {
	Hash    string
	Short   string
	Subject string
	Author  string
	Email   string
	Time    time.Time
	Files   []FileChange
}

func Log(ctx context.Context, dir string, limit int) ([]Commit, error) {
	args, err := logArgs(ctx, dir, limit)
	if err != nil {
		return nil, err
	}
	return logRange(ctx, dir, args)
}

// LogRange returns every commit reachable from HEAD but not from ref, i.e.
// the current branch's changes that are not yet merged into ref's line.
func LogRange(ctx context.Context, dir, ref string) ([]Commit, error) {
	args := []string{"-c", "core.quotepath=false", "log", "-M", ref + "..HEAD"}
	return logRange(ctx, dir, args)
}

func logRange(ctx context.Context, dir string, args []string) ([]Commit, error) {
	output, err := run(ctx, dir, append(append([]string{}, args...), "--name-status", "--format=COMMIT%x00%H%x00%h%x00%s%x00%an%x00%ae%x00%aI%x00")...)
	if err != nil {
		// A repository with no commits yet fails git log; the panel should
		// show an empty history instead of an error.
		var gitErr *Error
		if errors.As(err, &gitErr) && strings.Contains(gitErr.Output, "does not have any commits") {
			return nil, nil
		}
		return nil, err
	}
	commits := parseLog(output)
	if len(commits) == 0 {
		return commits, nil
	}
	stats, err := run(ctx, dir, append(append([]string{}, args...), "--numstat", "-z", "--format=COMMIT%x00%H%x00")...)
	if err != nil {
		return nil, err
	}
	mergeLogCounts(commits, parseLogNumstat(stats))
	return commits, nil
}

// logArgs builds the git log arguments scoped to the current branch: commits
// reachable from any other local or remote branch are excluded so the history
// shows only changes unique to the current branch. A detached HEAD falls back
// to the full history.
func logArgs(ctx context.Context, dir string, limit int) ([]string, error) {
	args := []string{"-c", "core.quotepath=false", "log", "-M", "-n", strconv.Itoa(limit)}
	branch, err := CurrentBranch(ctx, dir)
	if err != nil || branch == "HEAD" {
		return args, nil
	}
	tips, err := otherBranchTips(ctx, dir, branch)
	if err != nil {
		return nil, err
	}
	if len(tips) > 0 {
		// HEAD must be explicit: an implicit HEAD would be negated by --not.
		args = append(args, "HEAD", "--not")
		args = append(args, tips...)
	}
	return args, nil
}

// otherBranchTips lists every local and remote branch tip except the current
// branch, matching refs/remotes/<remote>/<name> against the branch name.
func otherBranchTips(ctx context.Context, dir, branch string) ([]string, error) {
	output, err := run(ctx, dir, "for-each-ref", "--format=%(refname)", "refs/heads", "refs/remotes")
	if err != nil {
		return nil, err
	}
	var tips []string
	for _, ref := range strings.Split(output, "\n") {
		ref = strings.TrimSpace(ref)
		if ref == "" || ref == "refs/heads/"+branch {
			continue
		}
		if short, ok := strings.CutPrefix(ref, "refs/remotes/"); ok {
			if _, name, found := strings.Cut(short, "/"); found && name == branch {
				continue
			}
		}
		tips = append(tips, ref)
	}
	return tips, nil
}

// parseLog reads git log --name-status output. Each commit is a
// "COMMIT\x00" marker followed by NUL-separated fields, a blank line, and
// the name-status lines for that commit.
func parseLog(output string) []Commit {
	var commits []Commit
	for _, chunk := range strings.Split(output, "COMMIT\x00") {
		if chunk == "" {
			continue
		}
		fields := strings.SplitN(chunk, "\x00", 7)
		if len(fields) < 6 {
			continue
		}
		commit := Commit{
			Hash:    fields[0],
			Short:   fields[1],
			Subject: fields[2],
			Author:  fields[3],
			Email:   fields[4],
		}
		if parsed, err := time.Parse(time.RFC3339, fields[5]); err == nil {
			commit.Time = parsed
		}
		if len(fields) > 6 {
			commit.Files = parseNameStatus(fields[6])
		}
		commits = append(commits, commit)
	}
	return commits
}

func parseNameStatus(block string) []FileChange {
	var files []FileChange
	for _, line := range strings.Split(block, "\n") {
		parts := strings.SplitN(line, "\t", 3)
		if len(parts) < 2 || parts[0] == "" {
			continue
		}
		change := FileChange{Status: parts[0][:1], Path: parts[1]}
		if len(parts) > 2 {
			change.Path = parts[2]
			change.RenameFrom = parts[1]
		}
		files = append(files, change)
	}
	return files
}

// parseLogNumstat reads git log --numstat -z output keyed by commit hash.
func parseLogNumstat(output string) map[string]map[string]LineCount {
	result := make(map[string]map[string]LineCount)
	for _, chunk := range strings.Split(output, "COMMIT\x00") {
		if chunk == "" {
			continue
		}
		fields := strings.SplitN(chunk, "\x00", 3)
		if len(fields) < 2 || fields[0] == "" {
			continue
		}
		block := strings.Join(fields[1:], "\x00")
		if newline := strings.IndexByte(block, '\n'); newline >= 0 {
			block = block[newline+1:]
		} else {
			block = ""
		}
		if counts := parseNumstat(block); len(counts) > 0 {
			result[fields[0]] = counts
		}
	}
	return result
}

// mergeLogCounts folds per-commit numstat counts into file changes. Renames
// also absorb the old path's deletions.
func mergeLogCounts(commits []Commit, countsByCommit map[string]map[string]LineCount) {
	for i := range commits {
		counts := countsByCommit[commits[i].Hash]
		for j := range commits[i].Files {
			file := &commits[i].Files[j]
			line := counts[file.Path]
			file.Added = line.Added
			file.Deleted = line.Deleted
			if file.RenameFrom != "" {
				if old, ok := counts[file.RenameFrom]; ok {
					file.Added += old.Added
					file.Deleted += old.Deleted
				}
			}
		}
	}
}
