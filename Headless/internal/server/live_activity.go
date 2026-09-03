package server

import (
	"bytes"
	"context"
	"encoding/json"
	"strings"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
)

// LiveActivitySession is the bounded Host projection sent to Relay. It is
// deliberately independent from the full roster so push payloads never carry
// transcript text, paths, command lines, or credentials.
type LiveActivitySession struct {
	ID         string `json:"id"`
	Title      string `json:"title,omitempty"`
	Connection string `json:"connection"`
	Activity   string `json:"activity,omitempty"`
	Attention  bool   `json:"attention,omitempty"`
}

// LiveActivitySnapshot is a complete snapshot for one Host. Relay owns the
// registered ActivityKit tokens and fans this projection out per Session.
type LiveActivitySnapshot struct {
	Connection            string                `json:"connection"`
	ActiveSessionCount    int                   `json:"activeSessionCount"`
	WorkingSessionCount   int                   `json:"workingSessionCount"`
	AttentionSessionCount int                   `json:"attentionSessionCount"`
	Sessions              []LiveActivitySession `json:"sessions"`
	UpdatedAt             time.Time             `json:"updatedAt"`
}

// LiveActivityPublisher is installed by the daemon entrypoint when an owned
// Relay is configured. A nil publisher leaves the Host fully functional while
// disabling optional mobile push delivery.
type LiveActivityPublisher func(context.Context, LiveActivitySnapshot) error

func (s *Service) initLiveActivity() {
	s.liveActivityMu.Lock()
	defer s.liveActivityMu.Unlock()
	if s.liveActivityWake == nil {
		s.liveActivityWake = make(chan struct{}, 1)
	}
}

// SetLiveActivityPublisher changes the optional Host→Relay push sink. It is
// safe to call after Start while the relay supervisor is being assembled.
func (s *Service) SetLiveActivityPublisher(publisher LiveActivityPublisher) {
	if s == nil {
		return
	}
	s.initLiveActivity()
	s.liveActivityMu.Lock()
	s.liveActivityPublisher = publisher
	s.liveActivityDigest = nil
	wake := s.liveActivityWake
	s.liveActivityMu.Unlock()
	select {
	case wake <- struct{}{}:
	default:
	}
}

func (s *Service) wakeLiveActivity() {
	if s == nil {
		return
	}
	s.initLiveActivity()
	s.liveActivityMu.Lock()
	wake := s.liveActivityWake
	s.liveActivityMu.Unlock()
	select {
	case wake <- struct{}{}:
	default:
	}
}

func (s *Service) liveActivityLoop(ctx context.Context) {
	s.initLiveActivity()
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			s.publishLiveActivity(ctx)
		case <-s.liveActivityWake:
			s.publishLiveActivity(ctx)
		}
	}
}

func (s *Service) publishLiveActivity(ctx context.Context) {
	s.liveActivityMu.Lock()
	publisher := s.liveActivityPublisher
	s.liveActivityMu.Unlock()
	if publisher == nil || s.Store == nil {
		return
	}
	snapshot := s.liveActivitySnapshot()
	// UpdatedAt is delivery metadata. Exclude it from the change digest so a
	// quiet Host does not emit one APNs request every polling tick.
	snapshot.UpdatedAt = time.Time{}
	digest, err := json.Marshal(snapshot)
	if err != nil {
		return
	}
	s.liveActivityMu.Lock()
	if bytes.Equal(s.liveActivityDigest, digest) {
		s.liveActivityMu.Unlock()
		return
	}
	s.liveActivityMu.Unlock()
	snapshot.UpdatedAt = time.Now().UTC()
	publishContext, cancel := context.WithTimeout(ctx, 10*time.Second)
	err = publisher(publishContext, snapshot)
	cancel()
	if err != nil {
		s.logWarn("publish live activity snapshot", "error", err)
		return
	}
	s.liveActivityMu.Lock()
	s.liveActivityDigest = append(s.liveActivityDigest[:0], digest...)
	s.liveActivityMu.Unlock()
}

func (s *Service) liveActivitySnapshot() LiveActivitySnapshot {
	state, _ := s.RosterVersion(context.Background())
	snapshot := LiveActivitySnapshot{
		Connection: "connected",
		Sessions:   make([]LiveActivitySession, 0, len(state.Sessions)),
	}
	for _, session := range state.Sessions {
		connection := "stopped"
		if session.Lifecycle == "running" {
			connection = "connected"
			snapshot.ActiveSessionCount++
		}
		activity := ""
		attention := false
		if session.AgentStatus != nil {
			activity = string(session.AgentStatus.Activity)
			attention = session.AgentStatus.Attention != nil ||
				session.AgentStatus.Activity == api.AgentActivityBlocked ||
				session.AgentStatus.Activity == api.AgentActivityStalled
		}
		if connection == "connected" {
			if activity == string(api.AgentActivityWorking) {
				snapshot.WorkingSessionCount++
			}
			if attention {
				snapshot.AttentionSessionCount++
			}
		}
		title := strings.TrimSpace(session.CustomTitle)
		if title == "" {
			title = strings.TrimSpace(session.Title)
		}
		if title == "" {
			title = strings.TrimSpace(session.Kind)
		}
		snapshot.Sessions = append(snapshot.Sessions, LiveActivitySession{
			ID:         session.ID,
			Title:      title,
			Connection: connection,
			Activity:   activity,
			Attention:  attention,
		})
	}
	return snapshot
}
