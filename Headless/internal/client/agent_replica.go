package client

import (
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"

	"github.com/abcdlsj/warren/Headless/internal/api"
)

// agentReplica is a disposable local copy. Only welcome establishes its namespace.
type agentReplica struct {
	db            *sql.DB
	hostID        string
	accessScopeID string
}

func (c *Client) openAgentReplica() (*agentReplica, error) {
	if c.replica != nil {
		return c.replica, nil
	}
	if c.hostID == "" || c.accessScopeID == "" {
		return nil, errors.New("missing authenticated Agent replica namespace")
	}
	directory, err := os.UserCacheDir()
	if err != nil {
		return nil, err
	}
	directory = filepath.Join(directory, "warren", "agent-replica")
	if err := os.MkdirAll(directory, 0700); err != nil {
		return nil, err
	}
	db, err := sql.Open("sqlite3", filepath.Join(directory, "events.sqlite3"))
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1)
	for _, statement := range []string{
		`PRAGMA busy_timeout=5000`,
		`CREATE TABLE IF NOT EXISTS events (host_id TEXT, scope_id TEXT, stream_id TEXT, sequence INTEGER, event_id TEXT, event_json TEXT, PRIMARY KEY(host_id,scope_id,stream_id,sequence), UNIQUE(host_id,scope_id,stream_id,event_id))`,
	} {
		if _, err := db.Exec(statement); err != nil {
			db.Close()
			return nil, err
		}
	}
	c.replica = &agentReplica{db: db, hostID: c.hostID, accessScopeID: c.accessScopeID}
	return c.replica, nil
}

func (c *Client) persistAgentEvents(streamID string, events []api.CanonicalAgentEvent) error {
	replica, err := c.openAgentReplica()
	if err != nil {
		return err
	}
	tx, err := replica.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	for _, event := range events {
		if event.StreamID != streamID || event.EventID == "" || event.Sequence == 0 || event.ExecutionID == "" || event.Payload == nil || event.Type == "" || event.RecordedAt.IsZero() || event.OccurredAt.IsZero() {
			return errors.New("invalid canonical Agent event")
		}
		encoded, err := json.Marshal(event)
		if err != nil {
			return err
		}
		var previous string
		err = tx.QueryRow(`SELECT event_json FROM events WHERE host_id=? AND scope_id=? AND stream_id=? AND (sequence=? OR event_id=?)`, replica.hostID, replica.accessScopeID, streamID, event.Sequence, event.EventID).Scan(&previous)
		if err == nil {
			if previous != string(encoded) {
				return fmt.Errorf("Agent event integrity conflict in %s at %d; stream quarantined", streamID, event.Sequence)
			}
			continue
		}
		if !errors.Is(err, sql.ErrNoRows) {
			return err
		}
		if _, err := tx.Exec(`INSERT INTO events VALUES(?,?,?,?,?,?)`, replica.hostID, replica.accessScopeID, streamID, event.Sequence, event.EventID, string(encoded)); err != nil {
			return err
		}
	}
	return tx.Commit()
}

// AgentContiguousThrough never skips a missing sequence, including unknown types.
func (c *Client) AgentContiguousThrough(streamID string) (uint64, error) {
	replica, err := c.openAgentReplica()
	if err != nil {
		return 0, err
	}
	rows, err := replica.db.Query(`SELECT sequence FROM events WHERE host_id=? AND scope_id=? AND stream_id=? ORDER BY sequence`, replica.hostID, replica.accessScopeID, streamID)
	if err != nil {
		return 0, err
	}
	defer rows.Close()
	var through uint64
	for rows.Next() {
		var sequence uint64
		if err := rows.Scan(&sequence); err != nil {
			return 0, err
		}
		if sequence != through+1 {
			break
		}
		through = sequence
	}
	return through, rows.Err()
}
