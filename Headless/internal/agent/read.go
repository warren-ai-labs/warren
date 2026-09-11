package agent

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"strings"

	"github.com/abcdlsj/warren/Headless/internal/api"
)

const (
	// DefaultReadRecent bounds a command result so an external agent does not
	// accidentally ingest an entire long-running conversation.
	DefaultReadRecent = 20
	// DefaultReadContentLimit is measured in Unicode code points, not bytes.
	DefaultReadContentLimit = 2000
	// MaxReadActivities bounds an unbounded (--all) read. Callers that need a
	// smaller response should set Recent explicitly.
	MaxReadActivities = 100000
)

// ReadOptions controls how a transcript is projected for an external caller.
// A zero Recent means that every matching event is returned. ContentLimit is
// ignored when Full is true; a zero ContentLimit uses the default limit.
type ReadOptions struct {
	Recent       int
	ContentLimit int
	Full         bool
	IncludeTypes []string
	ExcludeTypes []string
	// Tools adds compact tool-call records to the conversation projection.
	// ToolOutput additionally includes the bounded raw tool results.
	ToolOutput bool
	Tools      bool
}

// ProjectEvents applies the same filtering and content limits as
// ReadTranscript to events already retained by a live Host watcher. This is
// used by remote session readers, where the transcript file lives on the Host
// rather than on the CLI machine.
func ProjectEvents(events []api.AgentEvent, options ReadOptions) ([]api.AgentEvent, error) {
	if options.Recent < 0 {
		return nil, errors.New("recent activity count cannot be negative")
	}
	if options.Recent > MaxReadActivities {
		return nil, fmt.Errorf("recent activity count cannot exceed %d", MaxReadActivities)
	}
	if options.ContentLimit < 0 {
		return nil, errors.New("content limit cannot be negative")
	}

	include, exclude, contentLimit := readProjectionOptions(options)
	result := make([]api.AgentEvent, 0, min(len(events), max(1, options.Recent)))
	for _, event := range events {
		if !includeReadEvent(event, include, exclude) {
			continue
		}
		event = limitReadEvent(event, contentLimit)
		if options.Recent <= 0 && len(result) >= MaxReadActivities {
			return nil, fmt.Errorf("transcript has more than %d matching activities; use --recent to bound the result", MaxReadActivities)
		}
		result = appendRecent(result, event, options.Recent)
	}
	for index := range result {
		result[index].Sequence = uint64(index + 1)
	}
	return result, nil
}

// ReadTranscript parses one Codex, Claude, OpenCode, or Pi JSONL transcript
// into the same normalized events used by Warren's live agent view. The file
// is consumed line by line, so the reader never loads the whole transcript
// into memory.
func ReadTranscript(ctx context.Context, provider, path string, options ReadOptions) ([]api.AgentEvent, error) {
	provider = strings.ToLower(strings.TrimSpace(provider))
	if provider != "codex" && provider != "claude" && provider != "opencode" && provider != "pi" && provider != "qoder" && provider != "antigravity" {
		return nil, fmt.Errorf("unsupported agent provider %q (want codex, claude, opencode, pi, qoder, or antigravity)", provider)
	}
	if strings.TrimSpace(path) == "" {
		return nil, errors.New("agent transcript path is required")
	}
	if options.Recent < 0 {
		return nil, errors.New("recent activity count cannot be negative")
	}
	if options.Recent > MaxReadActivities {
		return nil, fmt.Errorf("recent activity count cannot exceed %d", MaxReadActivities)
	}
	if options.ContentLimit < 0 {
		return nil, errors.New("content limit cannot be negative")
	}

	file, err := openRegularFile(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()

	include, exclude, contentLimit := readProjectionOptions(options)
	parserLimit := maxEventContent
	if options.Full {
		parserLimit = 0
	} else if contentLimit > parserLimit {
		parserLimit = contentLimit
	}
	parser := newParserWithContentLimit(provider, parserLimit)
	result := make([]api.AgentEvent, 0)
	reader := bufio.NewReaderSize(file, 64*1024)
	for {
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		default:
		}

		line, readErr := readBoundedLine(reader, maxTranscriptLine)
		if len(line) > 0 {
			line = bytes.TrimSpace(line)
			if len(line) > 0 {
				events := parser.parse(line)
				// One-shot reads expose normalized conversation events, not live
				// turn notifications. Drain transitions per line so --all does not
				// retain lifecycle metadata for the entire transcript.
				parser.DrainTurns()
				for _, event := range events {
					if !includeReadEvent(event, include, exclude) {
						continue
					}
					event = limitReadEvent(event, contentLimit)
					if options.Recent <= 0 && len(result) >= MaxReadActivities {
						return nil, fmt.Errorf("transcript has more than %d matching activities; use --recent to bound the result", MaxReadActivities)
					}
					event.Sequence = uint64(len(result) + 1)
					result = appendRecent(result, event, options.Recent)
				}
			}
		}
		if errors.Is(readErr, io.EOF) {
			break
		}
		if readErr != nil {
			return nil, readErr
		}
	}

	// The sequence belongs to the returned projection. Re-numbering after the
	// ring buffer keeps a recent-only result contiguous and easy to consume.
	for index := range result {
		result[index].Sequence = uint64(index + 1)
	}
	return result, nil
}

// ReadTranscriptChunk returns one exact byte range from a bound transcript.
// It deliberately does not parse or normalize the JSONL: callers use it for
// the explicit full-transcript escape hatch and stream the result onward in
// small chunks. The returned EOF applies to the file size observed for this
// read; a concurrently-running Agent may append another record afterwards.
func ReadTranscriptChunk(path string, offset int64, limit int) ([]byte, int64, bool, error) {
	if strings.TrimSpace(path) == "" {
		return nil, offset, false, errors.New("agent transcript path is required")
	}
	if offset < 0 {
		return nil, offset, false, errors.New("transcript offset cannot be negative")
	}
	if limit <= 0 {
		return nil, offset, false, errors.New("transcript chunk limit must be positive")
	}

	file, err := openRegularFile(path)
	if err != nil {
		return nil, offset, false, err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return nil, offset, false, err
	}
	if offset >= info.Size() {
		return nil, offset, true, nil
	}
	size := min(int64(limit), info.Size()-offset)
	data := make([]byte, int(size))
	read, err := file.ReadAt(data, offset)
	if err != nil && !errors.Is(err, io.EOF) {
		return nil, offset, false, err
	}
	data = data[:read]
	next := offset + int64(read)
	return data, next, next >= info.Size(), nil
}

func appendRecent(events []api.AgentEvent, event api.AgentEvent, recent int) []api.AgentEvent {
	if recent <= 0 || len(events) < recent {
		return append(events, event)
	}
	copy(events, events[1:])
	events[len(events)-1] = event
	return events
}

func normalizedTypes(values []string) map[string]bool {
	result := make(map[string]bool)
	for _, value := range values {
		for _, item := range strings.Split(value, ",") {
			item = strings.ToLower(strings.TrimSpace(item))
			if item != "" {
				result[item] = true
			}
		}
	}
	return result
}

// defaultReadTypes is deliberately conversation-first. Tool transcripts can
// dominate a long-running Agent session but are rarely useful to a caller
// trying to understand the user request and the Agent's answer.
var defaultReadTypes = map[string]bool{
	"user":      true,
	"assistant": true,
	"error":     true,
}

func readProjectionOptions(options ReadOptions) (map[string]bool, map[string]bool, int) {
	include := normalizedTypes(options.IncludeTypes)
	if len(include) == 0 {
		include = make(map[string]bool, len(defaultReadTypes)+2)
		for typeName := range defaultReadTypes {
			include[typeName] = true
		}
	}
	if options.Tools || options.ToolOutput {
		include["tool_call"] = true
	}
	if options.ToolOutput {
		include["tool_output"] = true
	}

	contentLimit := options.ContentLimit
	if options.Full {
		contentLimit = 0
	} else if contentLimit == 0 {
		contentLimit = DefaultReadContentLimit
	}
	return include, normalizedTypes(options.ExcludeTypes), contentLimit
}

func includeReadEvent(event api.AgentEvent, include, exclude map[string]bool) bool {
	typeName := strings.ToLower(strings.TrimSpace(event.Type))
	canonicalType := strings.ToLower(strings.TrimSpace(event.CanonicalType))
	if !include[typeName] && (canonicalType == "" || !include[canonicalType]) {
		return false
	}
	return !exclude[typeName] && (canonicalType == "" || !exclude[canonicalType])
}

func limitReadEvent(event api.AgentEvent, limit int) api.AgentEvent {
	if limit <= 0 {
		return event
	}
	event.Content = truncate(event.Content, limit)
	event.Output = truncate(event.Output, limit)
	event.Error = truncate(event.Error, limit)
	event.ToolInput = limitReadValue(event.ToolInput, limit)
	return event
}

func limitReadValue(value any, limit int) any {
	switch item := value.(type) {
	case string:
		return truncate(item, limit)
	case []any:
		result := make([]any, len(item))
		for index := range item {
			result[index] = limitReadValue(item[index], limit)
		}
		return result
	case []string:
		result := make([]string, len(item))
		for index := range item {
			result[index] = truncate(item[index], limit)
		}
		return result
	case map[string]any:
		result := make(map[string]any, len(item))
		for key, nested := range item {
			result[key] = limitReadValue(nested, limit)
		}
		return result
	default:
		return value
	}
}
