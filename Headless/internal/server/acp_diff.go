package server

import (
	"fmt"
	"strings"
)

// unifiedLineDiff renders an ACP tool diff (whole old and new text) as a
// unified diff with three lines of context, and counts added and deleted
// lines. Inputs above acpDiffLineLimit lines are reported as a whole-file
// replacement rather than paying for a quadratic diff.
func unifiedLineDiff(file, oldText, newText string) (string, int, int) {
	oldLines := splitDiffLines(oldText)
	newLines := splitDiffLines(newText)
	if len(oldLines)+len(newLines) > acpDiffLineLimit {
		return wholeFileDiff(file, oldLines, newLines), len(newLines), len(oldLines)
	}
	ops := lineDiffOps(oldLines, newLines)
	additions, deletions := 0, 0
	for _, op := range ops {
		switch op.kind {
		case '+':
			additions++
		case '-':
			deletions++
		}
	}
	if additions == 0 && deletions == 0 {
		return "", 0, 0
	}
	var builder strings.Builder
	oldName, newName := "a/"+file, "b/"+file
	if oldText == "" {
		oldName = "/dev/null"
	}
	fmt.Fprintf(&builder, "--- %s\n+++ %s\n", oldName, newName)
	const context = 3
	changes := make([]int, 0, additions+deletions)
	for index, op := range ops {
		if op.kind != ' ' {
			changes = append(changes, index)
		}
	}
	for k := 0; k < len(changes); k++ {
		first, last := changes[k], changes[k]
		for k+1 < len(changes) && changes[k+1]-last <= 2*context+1 {
			k++
			last = changes[k]
		}
		begin := max(first-context, 0)
		end := min(last+context+1, len(ops))
		oldStart, newStart := ops[begin].oldLine, ops[begin].newLine
		oldCount, newCount := 0, 0
		for _, op := range ops[begin:end] {
			if op.kind != '+' {
				oldCount++
			}
			if op.kind != '-' {
				newCount++
			}
		}
		fmt.Fprintf(&builder, "@@ -%d,%d +%d,%d @@\n", hunkStart(oldStart, oldCount), oldCount, hunkStart(newStart, newCount), newCount)
		for _, op := range ops[begin:end] {
			builder.WriteByte(op.kind)
			builder.WriteString(op.text)
			builder.WriteByte('\n')
		}
	}
	return builder.String(), additions, deletions
}

func hunkStart(line, count int) int {
	if count == 0 {
		return line
	}
	return line + 1
}

type diffOp struct {
	kind    byte
	text    string
	oldLine int
	newLine int
}

func splitDiffLines(text string) []string {
	if text == "" {
		return nil
	}
	return strings.Split(strings.TrimSuffix(text, "\n"), "\n")
}

// lineDiffOps is a longest-common-subsequence line diff.
func lineDiffOps(oldLines, newLines []string) []diffOp {
	// Trim the common prefix and suffix first; typical edits touch a few
	// lines of a large file, which keeps the table small.
	prefix := 0
	for prefix < len(oldLines) && prefix < len(newLines) && oldLines[prefix] == newLines[prefix] {
		prefix++
	}
	suffix := 0
	for suffix < len(oldLines)-prefix && suffix < len(newLines)-prefix &&
		oldLines[len(oldLines)-1-suffix] == newLines[len(newLines)-1-suffix] {
		suffix++
	}
	a := oldLines[prefix : len(oldLines)-suffix]
	b := newLines[prefix : len(newLines)-suffix]
	table := make([][]int, len(a)+1)
	for i := range table {
		table[i] = make([]int, len(b)+1)
	}
	for i := len(a) - 1; i >= 0; i-- {
		for j := len(b) - 1; j >= 0; j-- {
			if a[i] == b[j] {
				table[i][j] = table[i+1][j+1] + 1
			} else {
				table[i][j] = max(table[i+1][j], table[i][j+1])
			}
		}
	}
	ops := make([]diffOp, 0, len(oldLines)+len(newLines))
	for index := 0; index < prefix; index++ {
		ops = append(ops, diffOp{kind: ' ', text: oldLines[index], oldLine: index, newLine: index})
	}
	i, j := 0, 0
	for i < len(a) || j < len(b) {
		switch {
		case i < len(a) && j < len(b) && a[i] == b[j]:
			ops = append(ops, diffOp{kind: ' ', text: a[i], oldLine: prefix + i, newLine: prefix + j})
			i++
			j++
		case i < len(a) && (j >= len(b) || table[i+1][j] >= table[i][j+1]):
			// Deletions precede additions within a change, as git prints them.
			ops = append(ops, diffOp{kind: '-', text: a[i], oldLine: prefix + i, newLine: prefix + j})
			i++
		default:
			ops = append(ops, diffOp{kind: '+', text: b[j], oldLine: prefix + i, newLine: prefix + j})
			j++
		}
	}
	for index := 0; index < suffix; index++ {
		oldIndex := len(oldLines) - suffix + index
		newIndex := len(newLines) - suffix + index
		ops = append(ops, diffOp{kind: ' ', text: oldLines[oldIndex], oldLine: oldIndex, newLine: newIndex})
	}
	return ops
}

func wholeFileDiff(file string, oldLines, newLines []string) string {
	var builder strings.Builder
	fmt.Fprintf(&builder, "--- a/%s\n+++ b/%s\n@@ -%d,%d +%d,%d @@\n", file, file, hunkStart(0, len(oldLines)), len(oldLines), hunkStart(0, len(newLines)), len(newLines))
	for _, line := range oldLines {
		builder.WriteString("-" + line + "\n")
	}
	for _, line := range newLines {
		builder.WriteString("+" + line + "\n")
	}
	return builder.String()
}
