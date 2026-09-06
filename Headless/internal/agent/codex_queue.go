package agent

import (
	"context"
	"database/sql"
	"encoding/json"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
	_ "github.com/ncruces/go-sqlite3/driver"
)

func defaultCodexQueueDBPath() string {
	home := os.Getenv("CODEX_HOME")
	if home == "" {
		userHome, _ := os.UserHomeDir()
		home = filepath.Join(userHome, ".codex")
	}
	return filepath.Join(home, "queue_1.sqlite")
}

// readCodexQueuedItems reads queued items for a specific thread_id from Codex's queue_1.sqlite.
func readCodexQueuedItems(dbPath string, threadID string) ([]api.AgentQueueItem, error) {
	if strings.TrimSpace(threadID) == "" {
		return nil, nil
	}
	if strings.TrimSpace(dbPath) == "" {
		dbPath = defaultCodexQueueDBPath()
	}
	if _, err := os.Stat(dbPath); err != nil {
		return nil, nil
	}
	uri := url.URL{
		Scheme:   "file",
		Path:     filepath.ToSlash(dbPath),
		RawQuery: "mode=ro&_pragma=busy_timeout(1000)",
	}
	db, err := sql.Open("sqlite3", uri.String())
	if err != nil {
		return nil, err
	}
	defer db.Close()
	db.SetMaxOpenConns(1)

	ctx, cancel := context.WithTimeout(context.Background(), 1*time.Second)
	defer cancel()

	if _, err := db.ExecContext(ctx, "PRAGMA query_only = ON"); err != nil {
		return nil, err
	}

	rows, err := db.QueryContext(ctx,
		"SELECT id, payload_json, queue_order, created_at_ms FROM queued_items WHERE thread_id = ? ORDER BY queue_order ASC",
		threadID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var items []api.AgentQueueItem
	for rows.Next() {
		var id, payloadJSON string
		var queueOrder int
		var createdAtMs int64
		if err := rows.Scan(&id, &payloadJSON, &queueOrder, &createdAtMs); err != nil {
			continue
		}
		text, attachments := parseCodexQueuedPayload(payloadJSON)
		var createdAt time.Time
		if createdAtMs > 0 {
			createdAt = time.UnixMilli(createdAtMs)
		}
		items = append(items, api.AgentQueueItem{
			ID:          id,
			SessionID:   threadID,
			Action:      "enqueue",
			State:       "queued",
			Order:       queueOrder,
			Content:     text,
			Prompt:      text,
			Attachments: attachments,
			CreatedAt:   createdAt,
		})
	}
	return items, rows.Err()
}

// parseCodexQueuedPayload extracts text and attachments from Codex's queued submission payload_json.
func parseCodexQueuedPayload(raw string) (string, []api.AgentAttachmentRef) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return "", nil
	}
	var val any
	if err := json.Unmarshal([]byte(raw), &val); err != nil {
		return raw, nil
	}
	return extractPayloadTextAndAttachments(val)
}

func extractPayloadTextAndAttachments(val any) (string, []api.AgentAttachmentRef) {
	switch v := val.(type) {
	case string:
		return v, nil
	case []any:
		var texts []string
		var attachments []api.AgentAttachmentRef
		for _, item := range v {
			t, atts := extractPayloadTextAndAttachments(item)
			if t != "" {
				texts = append(texts, t)
			}
			if len(atts) > 0 {
				attachments = append(attachments, atts...)
			}
		}
		return strings.Join(texts, "\n"), attachments
	case map[string]any:
		var texts []string
		var attachments []api.AgentAttachmentRef
		if t, ok := v["text"].(string); ok && t != "" {
			texts = append(texts, t)
		} else if p, ok := v["prompt"].(string); ok && p != "" {
			texts = append(texts, p)
		} else if c, ok := v["content"].(string); ok && c != "" {
			texts = append(texts, c)
		}
		if kind, ok := v["type"].(string); ok {
			switch kind {
			case "image", "local_image", "file":
				name := firstNonEmpty(stringValue(v["name"]), stringValue(v["path"]), stringValue(v["filename"]))
				if name != "" {
					attachments = append(attachments, api.AgentAttachmentRef{
						Name: filepath.Base(name),
					})
				}
			}
		}
		if sub, ok := v["items"].([]any); ok {
			t, atts := extractPayloadTextAndAttachments(sub)
			if t != "" {
				texts = append(texts, t)
			}
			if len(atts) > 0 {
				attachments = append(attachments, atts...)
			}
		}
		return strings.Join(texts, "\n"), attachments
	default:
		return "", nil
	}
}
