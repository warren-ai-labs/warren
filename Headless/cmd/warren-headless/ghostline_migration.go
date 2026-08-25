package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/abcdlsj/ghostline"
	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/store"
)

const (
	ghostlineV0CompatibilityProtocol = "0.8.0"
	ghostlineV0ToV1Handoff           = "ghostline-v0-to-v1-1"
	ghostlineMigrationTimeout        = 20 * time.Second
)

// ghostlineServerVersion is kept separate from the v1 client type because a
// legacy socket can only answer its v0 version request.
type ghostlineServerVersion struct {
	ProtocolVersion string
	TagVersion      string
}

type ghostlineMigrationConfig struct {
	stableSocket    string
	outputDir       string
	probeForeground bool
	expectedTag     string
	state           *store.Store
	logger          *slog.Logger
}

// ensureGhostlineClientWithStore starts a v1 daemon when no daemon exists.
// For an existing v0 daemon it performs the one-off bridge upgrade:
// legacy v0 -> v0.8 compatibility daemon -> v1. Each handoff gets a fresh
// socket; the stable socket is switched only after Ghostline transfers
// ownership and the source has stopped serving.
func ensureGhostlineClientWithStore(socketPath, outputDir string, probeForeground bool, expectedTag string, state *store.Store, logger *slog.Logger) (*ghostline.Client, error) {
	config := ghostlineMigrationConfig{
		stableSocket:    socketPath,
		outputDir:       outputDir,
		probeForeground: probeForeground,
		expectedTag:     expectedTag,
		state:           state,
		logger:          logger,
	}
	if config.logger == nil {
		config.logger = slog.Default()
	}

	if err := resumeGhostlineMigration(config); err != nil {
		return nil, err
	}
	if !ghostlineSocketReady(socketPath) {
		return startGhostline(config, socketPath, v1GhostlineSpawn(config))
	}

	// A normal installation needs no handoff. The only multi-step case is the
	// temporary v0 compatibility bridge, so three probes are sufficient and
	// keep this deliberately small coordinator bounded.
	for attempt := 0; attempt < 3; attempt++ {
		sourceSocket := currentGhostlineRoute(socketPath)
		version, err := probeGhostlineVersion(context.Background(), sourceSocket)
		if err != nil {
			return nil, fmt.Errorf("read ghostline server version: %w", err)
		}

		switch version.ProtocolVersion {
		case ghostline.ProtocolVersion:
			needsUpgrade, trigger := ghostlineVersionNeedsUpgrade(
				ghostline.VersionInfo{ProtocolVersion: version.ProtocolVersion, TagVersion: version.TagVersion},
				config.expectedTag,
				nil,
			)
			if !needsUpgrade {
				client := ghostline.NewClient(socketPath)
				if err := client.Check(context.Background()); err != nil {
					return nil, fmt.Errorf("check ghostline server: %w", err)
				}
				return client, nil
			}
			config.logger.Warn("ghostline server requires rolling upgrade",
				"from_version", version.ProtocolVersion,
				"to_version", ghostline.ProtocolVersion,
				"from_tag", version.TagVersion,
				"to_tag", config.expectedTag,
				"trigger", trigger)
			if err := handoffGhostline(config, sourceSocket, version, "", v1GhostlineSpawn(config)); err != nil {
				return nil, err
			}

		case ghostlineV0CompatibilityProtocol:
			config.logger.Info("migrating ghostline v0.8 compatibility daemon to v1",
				"source", sourceSocket)
			if err := handoffGhostline(config, sourceSocket, version, ghostlineV0ToV1Handoff, v1GhostlineSpawn(config)); err != nil {
				return nil, err
			}

		default:
			config.logger.Info("migrating legacy ghostline through v0.8 compatibility daemon",
				"source", sourceSocket,
				"source_protocol", version.ProtocolVersion)
			if err := handoffGhostline(config, sourceSocket, version, "", compatibilityGhostlineSpawn(config)); err != nil {
				return nil, err
			}
		}
	}
	return nil, errors.New("ghostline migration did not reach v1")
}

// resumeGhostlineMigration completes only a committed handoff. Before commit
// the old source remains owner, so a stale preparing/prepared record is left
// as diagnostics and a later attempt starts from the unchanged route.
func resumeGhostlineMigration(config ghostlineMigrationConfig) error {
	if config.state == nil {
		return nil
	}
	record, ok := pendingGhostlineMigration(config.state.Snapshot())
	if !ok {
		return nil
	}
	targetReady := ghostlineSocketReady(record.TargetSocket)
	if !targetReady {
		if ghostlinePhaseAtLeast(record.Phase, api.GhostlineMigrationCommitted) {
			return fmt.Errorf("committed ghostline migration target is unavailable: %s", record.TargetSocket)
		}
		return nil
	}
	// A target binds its public socket only after Ghostline commits the whole
	// batch. This covers a process crash between the spawn returning and the
	// journal write below without ever falling back to the old owner.
	if !ghostlinePhaseAtLeast(record.Phase, api.GhostlineMigrationCommitted) {
		if err := setGhostlineMigrationPhase(config.state, record.SessionID, api.GhostlineMigrationCommitted); err != nil {
			return fmt.Errorf("record recovered ghostline commit: %w", err)
		}
		record.Phase = api.GhostlineMigrationCommitted
	}
	return finishGhostlineMigration(config, record)
}

// handoffGhostline delegates session ownership to Ghostline. Warren only
// records the small lifecycle journal, launches the target, and swaps its
// local route; it never reads a v0 spool or translates a cursor.
func handoffGhostline(config ghostlineMigrationConfig, sourceSocket string, sourceVersion ghostlineServerVersion, handoffVersion string, spawn []string) error {
	if config.state == nil {
		return fmt.Errorf("ghostline migration requires persistent Warren state")
	}
	if sourceSocket == "" {
		return fmt.Errorf("resolve ghostline source socket")
	}
	if !ghostlineSocketReady(sourceSocket + ".admin") {
		return fmt.Errorf("ghostline source has no admin socket: %s", sourceSocket+".admin")
	}
	if len(spawn) == 0 {
		return fmt.Errorf("ghostline migration target executable is unavailable")
	}

	record, err := createGhostlineMigration(config.state, sourceSocket, nextGhostlineSocket(config.stableSocket), sourceVersion.ProtocolVersion, handoffVersion)
	if err != nil {
		return err
	}
	if err := setGhostlineMigrationPhase(config.state, record.SessionID, api.GhostlineMigrationPrepared); err != nil {
		return err
	}
	record.Phase = api.GhostlineMigrationPrepared

	client, err := startGhostline(config, record.TargetSocket, append(append([]string{}, spawn...), "--adopt-from", sourceSocket+".admin"))
	if err != nil {
		// A readiness timeout can happen just after commit. A visible target is
		// authoritative, because Ghostline never exposes it before commit.
		if !ghostlineSocketReady(record.TargetSocket) {
			return fmt.Errorf("start ghostline migration target: %w", err)
		}
		client = ghostline.NewClient(record.TargetSocket)
	}
	if pid := client.PID(); pid > 0 {
		if err := writeGhostlinePID(record.TargetSocket, pid); err != nil {
			config.logger.Warn("unable to record ghostline target pid", "path", record.TargetSocket+".pid", "error", err)
		}
	}
	if err := setGhostlineMigrationPhase(config.state, record.SessionID, api.GhostlineMigrationCommitted); err != nil {
		return fmt.Errorf("record ghostline migration commit: %w", err)
	}
	record.Phase = api.GhostlineMigrationCommitted
	return finishGhostlineMigration(config, record)
}

// finishGhostlineMigration runs only after ownership moved. The source must
// stop before the stable pathname is replaced: an exiting source removes its
// own socket pathname and could otherwise unlink Warren's new route.
func finishGhostlineMigration(config ghostlineMigrationConfig, record api.GhostlineMigration) error {
	if !ghostlineSocketReady(record.TargetSocket) {
		return fmt.Errorf("ghostline target is not ready: %s", record.TargetSocket)
	}
	if err := waitForGhostlineExit(record.SourceSocket, 5*time.Second); err != nil {
		config.logger.Warn("committed ghostline source did not exit; stopping it", "source", record.SourceSocket, "error", err)
		if stopErr := stopGhostlineServer(record.SourceSocket); stopErr != nil {
			return fmt.Errorf("retire committed ghostline source: %v (stop: %w)", err, stopErr)
		}
	}
	if err := replaceWithSymlink(config.stableSocket, record.TargetSocket); err != nil {
		return fmt.Errorf("route ghostline target: %w", err)
	}
	if !ghostlinePhaseAtLeast(record.Phase, api.GhostlineMigrationRouted) {
		if err := setGhostlineMigrationPhase(config.state, record.SessionID, api.GhostlineMigrationRouted); err != nil {
			return fmt.Errorf("record ghostline route: %w", err)
		}
		record.Phase = api.GhostlineMigrationRouted
	}
	if err := setGhostlineMigrationPhase(config.state, record.SessionID, api.GhostlineMigrationRetired); err != nil {
		return fmt.Errorf("record ghostline retirement: %w", err)
	}
	config.logger.Info("ghostline migration complete",
		"migration", record.SessionID,
		"source", record.SourceSocket,
		"target", record.TargetSocket,
		"source_protocol", record.SourceProtocol,
		"handoff_version", record.HandoffVersion)
	return nil
}

func startGhostline(config ghostlineMigrationConfig, socketPath string, spawn []string) (*ghostline.Client, error) {
	logFile, err := openGhostlineLog(config.stableSocket)
	if err != nil {
		return nil, err
	}
	defer logFile.Close()
	ctx, cancel := context.WithTimeout(context.Background(), ghostlineMigrationTimeout)
	defer cancel()
	client, err := ghostline.ConnectManaged(ctx, ghostline.ManagedClientOptions{
		Socket:       socketPath,
		Spawn:        spawn,
		Log:          logFile,
		ReadyTimeout: ghostlineMigrationTimeout,
	})
	if err != nil {
		return nil, err
	}
	if pid := client.PID(); pid > 0 {
		if err := writeGhostlinePID(socketPath, pid); err != nil {
			config.logger.Warn("unable to record ghostline pid", "path", socketPath+".pid", "error", err)
		}
	}
	return client, nil
}

func v1GhostlineSpawn(config ghostlineMigrationConfig) []string {
	executable, err := os.Executable()
	if err != nil {
		return nil
	}
	return []string{
		executable,
		"--ghostline-serve",
		"--ghostline-socket", "{socket}",
		"--output-dir", config.outputDir,
		"--ghostline-probe-foreground=" + strconv.FormatBool(config.probeForeground),
	}
}

func compatibilityGhostlineSpawn(config ghostlineMigrationConfig) []string {
	compatibility := bundledGhostlineV0CompatPath()
	if compatibility == "" {
		return nil
	}
	return []string{
		compatibility,
		"serve",
		"--socket", "{socket}",
		"--output-dir", config.outputDir,
		"--probe-foreground=" + strconv.FormatBool(config.probeForeground),
	}
}

func createGhostlineMigration(state *store.Store, sourceSocket, targetSocket, sourceProtocol, handoffVersion string) (api.GhostlineMigration, error) {
	now := time.Now().UTC()
	record := api.GhostlineMigration{
		SessionID:      store.NewID(),
		SourceSocket:   sourceSocket,
		TargetSocket:   targetSocket,
		SourceProtocol: sourceProtocol,
		HandoffVersion: handoffVersion,
		Phase:          api.GhostlineMigrationPreparing,
		CreatedAt:      now,
		UpdatedAt:      now,
	}
	err := state.Update(func(value *api.State) error {
		migration := record
		value.GhostlineMigration = &migration
		return nil
	})
	return record, err
}

func setGhostlineMigrationPhase(state *store.Store, sessionID, phase string) error {
	now := time.Now().UTC()
	return state.Update(func(value *api.State) error {
		if value.GhostlineMigration == nil || value.GhostlineMigration.SessionID != sessionID {
			return fmt.Errorf("ghostline migration not found: %s", sessionID)
		}
		value.GhostlineMigration.Phase = phase
		value.GhostlineMigration.UpdatedAt = now
		return nil
	})
}

func pendingGhostlineMigration(state api.State) (api.GhostlineMigration, bool) {
	if state.GhostlineMigration != nil && state.GhostlineMigration.Phase != api.GhostlineMigrationRetired {
		return *state.GhostlineMigration, true
	}
	return api.GhostlineMigration{}, false
}

func ghostlinePhaseAtLeast(phase, minimum string) bool {
	order := map[string]int{
		api.GhostlineMigrationPreparing: 0,
		api.GhostlineMigrationPrepared:  1,
		api.GhostlineMigrationCommitted: 2,
		api.GhostlineMigrationRouted:    3,
		api.GhostlineMigrationRetired:   4,
	}
	value, exists := order[phase]
	threshold, minimumExists := order[minimum]
	return exists && minimumExists && value >= threshold
}

func ghostlineVersionNeedsUpgrade(serverVersion ghostline.VersionInfo, expectedTag string, versionErr error) (bool, string) {
	if versionErr != nil {
		return true, "version_query_failed"
	}
	if serverVersion.ProtocolVersion != ghostline.ProtocolVersion {
		return true, "protocol_mismatch"
	}
	if expectedTag != "" && serverVersion.TagVersion != expectedTag {
		return true, "tag_mismatch"
	}
	return false, ""
}

func nextGhostlineSocket(stableSocket string) string {
	return filepath.Join(filepath.Dir(stableSocket), "ghostline-"+strconv.FormatInt(time.Now().UnixNano(), 10)+".sock")
}

func currentGhostlineRoute(socketPath string) string {
	resolved, err := filepath.EvalSymlinks(socketPath)
	if err == nil {
		return resolved
	}
	return socketPath
}

func writeGhostlinePID(socketPath string, pid int) error {
	if pid <= 0 {
		return nil
	}
	return os.WriteFile(socketPath+".pid", []byte(strconv.Itoa(pid)+"\n"), 0o600)
}

func openGhostlineLog(socketPath string) (*os.File, error) {
	directory := filepath.Dir(socketPath)
	if err := os.MkdirAll(directory, 0o700); err != nil {
		return nil, err
	}
	return os.OpenFile(filepath.Join(directory, "ghostline.log"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
}

func probeGhostlineVersion(ctx context.Context, socketPath string) (ghostlineServerVersion, error) {
	client := ghostline.NewClient(socketPath)
	info, err := client.VersionInfo(ctx)
	if err == nil {
		return ghostlineServerVersion{ProtocolVersion: info.ProtocolVersion, TagVersion: info.TagVersion}, nil
	}
	legacy, legacyErr := probeLegacyGhostlineVersion(ctx, socketPath)
	if legacyErr == nil {
		return legacy, nil
	}
	return ghostlineServerVersion{}, fmt.Errorf("v1 probe: %v; legacy probe: %w", err, legacyErr)
}

func probeLegacyGhostlineVersion(ctx context.Context, socketPath string) (ghostlineServerVersion, error) {
	connection, err := (&net.Dialer{}).DialContext(ctx, "unix", socketPath)
	if err != nil {
		return ghostlineServerVersion{}, err
	}
	defer connection.Close()
	if deadline, ok := ctx.Deadline(); ok {
		_ = connection.SetDeadline(deadline)
	} else {
		_ = connection.SetDeadline(time.Now().Add(2 * time.Second))
	}
	request := struct {
		ID     int64  `json:"id"`
		Method string `json:"method"`
	}{ID: 1, Method: "version"}
	writer := bufio.NewWriter(connection)
	if err := json.NewEncoder(writer).Encode(request); err != nil {
		return ghostlineServerVersion{}, err
	}
	if err := writer.Flush(); err != nil {
		return ghostlineServerVersion{}, err
	}
	var response struct {
		ID     int64           `json:"id"`
		Result json.RawMessage `json:"result"`
		Error  json.RawMessage `json:"error"`
	}
	if err := json.NewDecoder(bufio.NewReader(connection)).Decode(&response); err != nil {
		return ghostlineServerVersion{}, err
	}
	if response.ID != request.ID {
		return ghostlineServerVersion{}, fmt.Errorf("legacy version response id %d, want %d", response.ID, request.ID)
	}
	if len(response.Error) > 0 && string(response.Error) != "null" {
		return ghostlineServerVersion{}, fmt.Errorf("legacy version error: %s", response.Error)
	}
	var result struct {
		Version    string `json:"version"`
		TagVersion string `json:"tagVersion"`
	}
	if err := json.Unmarshal(response.Result, &result); err != nil {
		return ghostlineServerVersion{}, err
	}
	if strings.TrimSpace(result.Version) == "" {
		return ghostlineServerVersion{}, fmt.Errorf("legacy version response is empty")
	}
	return ghostlineServerVersion{ProtocolVersion: result.Version, TagVersion: result.TagVersion}, nil
}

// ghostlineSocketReady only checks local Unix reachability. It works for the
// legacy, compatibility, and v1 public/admin sockets without exposing admin
// RPCs to terminal clients.
func ghostlineSocketReady(socketPath string) bool {
	if strings.TrimSpace(socketPath) == "" {
		return false
	}
	connection, err := net.DialTimeout("unix", socketPath, 250*time.Millisecond)
	if err != nil {
		return false
	}
	_ = connection.Close()
	return true
}

func waitForGhostlineExit(socketPath string, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for (ghostlineSocketReady(socketPath) || ghostlineSocketReady(socketPath+".admin")) && time.Now().Before(deadline) {
		time.Sleep(50 * time.Millisecond)
	}
	if ghostlineSocketReady(socketPath) || ghostlineSocketReady(socketPath+".admin") {
		return fmt.Errorf("ghostline source is still accepting at %s", socketPath)
	}
	return nil
}

// replaceWithSymlink atomically swaps the stable route. In particular, it
// does not remove stable first: a failed rename must leave the old route in
// place rather than creating a client-visible gap.
func replaceWithSymlink(stable, target string) error {
	linkTarget, err := filepath.Rel(filepath.Dir(stable), target)
	if err != nil {
		linkTarget = target
	}
	temporary := stable + ".tmp-" + strconv.FormatInt(time.Now().UnixNano(), 10)
	if err := os.Symlink(linkTarget, temporary); err != nil {
		return fmt.Errorf("create socket symlink: %w", err)
	}
	if err := os.Rename(temporary, stable); err != nil {
		_ = os.Remove(temporary)
		return fmt.Errorf("install socket symlink: %w", err)
	}
	return nil
}

// stopGhostlineServer is used only after Ghostline committed ownership to a
// target. It deliberately never participates in normal Warren shutdown.
func stopGhostlineServer(socketPath string) error {
	pidPath := socketPath + ".pid"
	data, err := os.ReadFile(pidPath)
	if err != nil {
		data, err = os.ReadFile(filepath.Join(filepath.Dir(socketPath), "ghostline.pid"))
	}
	if err != nil {
		return fmt.Errorf("read ghostline source pid: %w", err)
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(data)))
	if err != nil || pid <= 0 {
		return fmt.Errorf("read ghostline source pid: invalid value in %s", pidPath)
	}
	if err := syscall.Kill(pid, syscall.SIGTERM); err != nil && err != syscall.ESRCH {
		return fmt.Errorf("stop ghostline source: %w", err)
	}
	return waitForGhostlineExit(socketPath, 5*time.Second)
}

func bundledGhostlineV0CompatPath() string {
	if override := strings.TrimSpace(os.Getenv("WARREN_GHOSTLINE_V0_COMPAT")); override != "" {
		if info, err := os.Stat(override); err == nil && !info.IsDir() && info.Mode()&0o111 != 0 {
			return override
		}
		return ""
	}
	executable, err := os.Executable()
	if err != nil {
		return ""
	}
	return bundledGhostlineV0CompatPathFor(executable)
}

func bundledGhostlineV0CompatPathFor(executable string) string {
	if resolved, resolveErr := filepath.EvalSymlinks(executable); resolveErr == nil {
		executable = resolved
	}
	macOSDirectory := filepath.Dir(executable)
	if filepath.Base(macOSDirectory) != "MacOS" || filepath.Base(filepath.Dir(macOSDirectory)) != "Contents" {
		return ""
	}
	candidate := filepath.Join(macOSDirectory, "..", "Resources", "ghostline-v0-compat")
	info, err := os.Stat(candidate)
	if err != nil || info.IsDir() || info.Mode()&0o111 == 0 {
		return ""
	}
	return candidate
}
