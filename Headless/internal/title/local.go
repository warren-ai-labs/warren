package title

import (
	"regexp"
	"strings"
	"unicode"
)

// localLabelLimit is the longest label this fallback writes, in runes. It is
// the budget a sidebar row has for a name: long enough to say what the work is,
// short enough that the row never has to truncate it to stay readable.
const localLabelLimit = 48

// localStripPasses bounds the scaffolding a message may lead with: a system
// block inside a tag inside front matter is already unusual, and the bound
// keeps a pathological message from being walked forever.
const localStripPasses = 8

var (
	// localLeadingTag matches the opening tag of a block a message may lead
	// with, such as `<environment_context>` or `<user_instructions>`.
	localLeadingTag = regexp.MustCompile(`^<([A-Za-z][\w:.-]*)(?:\s[^>]{0,200})?>`)
	// localSlashCommand matches a leading slash command, which names the
	// command rather than the work.
	localSlashCommand = regexp.MustCompile(`^/[A-Za-z][\w:-]*[\s]*`)
	// localBullet matches a leading list marker or blockquote.
	localBullet = regexp.MustCompile(`^(?:[-*+>]+|\d{1,3}[.)])\s+`)
	// localInlineTag drops markup left inside the line that survives the strip.
	localInlineTag = regexp.MustCompile(`<[^>]{0,200}>`)
	// localMarkdownNoise drops the emphasis and code marks that read as noise in
	// a row title.
	localMarkdownNoise = regexp.MustCompile("[`*_~]+")
	localWhitespace    = regexp.MustCompile(`\s+`)
)

// LocalLabel derives a name for a Session from the first thing the person wrote
// in it, for a Host whose own title model is not configured or whose request
// failed.
//
// It is a fallback, not a title: it keeps the person's own words and drops the
// scaffolding around them — provider context blocks, front matter, a pasted
// code block or JSON body, a leading slash command, a list marker — because
// those describe the harness rather than the work. It returns "" when nothing
// worth showing is left, so the caller keeps the Session's own rule instead of
// labelling the row with punctuation.
func LocalLabel(user string) string {
	text := strings.TrimSpace(strings.ReplaceAll(user, "\r\n", "\n"))
	for pass := 0; pass < localStripPasses; pass++ {
		trimmed := strings.TrimSpace(text)
		switch {
		case trimmed == "":
			return ""
		case strings.HasPrefix(trimmed, "---"):
			// Front matter describing the message rather than saying anything.
			rest, ok := localAfterDelimiter(trimmed, "---")
			if !ok {
				return ""
			}
			text = rest
		case strings.HasPrefix(trimmed, "```"):
			// A pasted code block leads; the prose after it is the subject.
			rest, ok := localAfterFence(trimmed)
			if !ok {
				return ""
			}
			text = rest
		case strings.HasPrefix(trimmed, "{"), strings.HasPrefix(trimmed, "["):
			// A JSON body, such as a tool payload pasted as the first message.
			rest, ok := localAfterJSON(trimmed)
			if !ok {
				return ""
			}
			text = rest
		case localLeadingTag.MatchString(trimmed):
			rest, ok := localAfterTagBlock(trimmed)
			if !ok {
				return ""
			}
			text = rest
		case strings.HasPrefix(trimmed, "#"):
			text = strings.TrimLeft(trimmed, "#")
		case localSlashCommand.MatchString(trimmed):
			text = localSlashCommand.ReplaceAllString(trimmed, "")
		case localBullet.MatchString(trimmed):
			text = localBullet.ReplaceAllString(trimmed, "")
		default:
			text = trimmed
		}
		if text == trimmed {
			break
		}
	}

	line := strings.SplitN(strings.TrimSpace(text), "\n", 2)[0]
	line = localInlineTag.ReplaceAllString(line, " ")
	line = localMarkdownNoise.ReplaceAllString(line, "")
	line = localWhitespace.ReplaceAllString(line, " ")
	line = Normalize(clip(strings.TrimSpace(line), localLabelLimit))
	if !localHasWord(line) {
		return ""
	}
	return line
}

// localHasWord reports whether the label carries something a person reads: a
// letter, a digit, or an ideograph. A line of punctuation is not a name.
func localHasWord(value string) bool {
	for _, symbol := range value {
		if unicode.IsLetter(symbol) || unicode.IsDigit(symbol) {
			return true
		}
	}
	return false
}

// localAfterDelimiter returns what follows the closing `---` of a leading
// front-matter block.
func localAfterDelimiter(text, delimiter string) (string, bool) {
	rest := text[len(delimiter):]
	for {
		line, tail, found := strings.Cut(rest, "\n")
		if !found {
			return "", false
		}
		if strings.TrimSpace(line) == delimiter {
			return tail, true
		}
		rest = tail
	}
}

// localAfterFence returns what follows a leading fenced code block.
func localAfterFence(text string) (string, bool) {
	rest := text[3:]
	if newline := strings.IndexByte(rest, '\n'); newline >= 0 {
		rest = rest[newline+1:]
	} else {
		return "", false
	}
	for {
		line, tail, found := strings.Cut(rest, "\n")
		if strings.HasPrefix(strings.TrimSpace(line), "```") {
			return tail, true
		}
		if !found {
			return "", false
		}
		rest = tail
	}
}

// localAfterJSON returns what follows a leading JSON value. The walk counts
// braces and brackets only, which is enough to find the end of a pasted
// payload: a `{` or `[` inside a string still balances.
func localAfterJSON(text string) (string, bool) {
	depth := 0
	inString := false
	escaped := false
	for index := 0; index < len(text); index++ {
		symbol := text[index]
		if inString {
			switch {
			case escaped:
				escaped = false
			case symbol == '\\':
				escaped = true
			case symbol == '"':
				inString = false
			}
			continue
		}
		switch symbol {
		case '"':
			inString = true
		case '{', '[':
			depth++
		case '}', ']':
			depth--
			if depth == 0 {
				return text[index+1:], true
			}
		}
	}
	return "", false
}

// localAfterTagBlock returns what follows the block a leading tag opens. A tag
// with no closing partner is dropped on its own and the walk continues, so a
// stray marker does not swallow the whole message.
func localAfterTagBlock(text string) (string, bool) {
	match := localLeadingTag.FindStringSubmatch(text)
	if match == nil {
		return "", false
	}
	name := match[1]
	rest := text[len(match[0]):]
	closing := "</" + name + ">"
	if end := strings.Index(rest, closing); end >= 0 {
		return rest[end+len(closing):], true
	}
	// Self-closing or unpaired: drop the tag itself and keep the message.
	return rest, true
}
