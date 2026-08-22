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

	include := normalizedTypes(options.IncludeTypes)
	exclude := normalizedTypes(options.ExcludeTypes)
	contentLimit := options.ContentLimit
	if options.Full {
		contentLimit = 0
	} else if contentLimit == 0 {
		contentLimit = DefaultReadContentLimit
	}
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

// ReadTranscript parses one Codex or Claude JSONL transcript into the same
// normalized events used by Warren's live agent view. The file is consumed
// line by line, so the reader never loads the whole transcript into memory.
func ReadTranscript(ctx context.Context, provider, path string, options ReadOptions) ([]api.AgentEvent, error) {
	provider = strings.ToLower(strings.TrimSpace(provider))
	if provider != "codex" && provider != "claude" {
		return nil, fmt.Errorf("unsupported agent provider %q (want codex or claude)", provider)
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

	include := normalizedTypes(options.IncludeTypes)
	exclude := normalizedTypes(options.ExcludeTypes)
	contentLimit := options.ContentLimit
	if options.Full {
		contentLimit = 0
	} else if contentLimit == 0 {
		contentLimit = DefaultReadContentLimit
	}
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

// These records are useful to the live UI internally but usually distract an
// external agent from the conversation. An explicit --include can opt back in.
var defaultReadIgnoredTypes = map[string]bool{
	"attachment":          true,
	"system_instructions": true,
	"usage":               true,
}

func includeReadEvent(event api.AgentEvent, include, exclude map[string]bool) bool {
	typeName := strings.ToLower(strings.TrimSpace(event.Type))
	if len(include) > 0 {
		if !include[typeName] {
			return false
		}
	} else if defaultReadIgnoredTypes[typeName] {
		return false
	}
	return !exclude[typeName]
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
