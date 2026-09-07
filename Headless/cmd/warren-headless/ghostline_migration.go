package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/abcdlsj/ghostline"
	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/runtime"
	"github.com/abcdlsj/warren/Headless/internal/store"
)

const (
	ghostlineMigrationTimeout = 20 * time.Second
)

// ghostlineServerVersion is kept separate from the v1 client type so the
// migration coordinator can persist the source version in its journal.
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
// Every Warren package upgrade performs a direct v1 rolling handoff. Each
// handoff gets a fresh socket; the stable socket is switched only after
// Ghostline transfers ownership and the source has stopped serving.
func ensureGhostlineClientWithStore(socketPath, outputDir string, probeForeground bool, expectedTag string, warrenVersion string, state *store.Store, logger *slog.Logger) (*ghostline.Client, error) {
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

	// Force handoff is a one-shot control signal. Consume it before spawning
	// any Ghostline child (and before recovery can return an error), so it
	// cannot be inherited by the serve process or trigger another handoff when
	// this daemon is restarted.
	force := consumeForceGhostlineHandoff(config)
	if err := resumeGhostlineMigration(config); err != nil {
		return nil, err
	}
	storedVersion := ""
	versionHandoffRequired := false
	if warrenVersion != "" && state != nil {
		storedVersion = state.Snapshot().WarrenVersion
		// An empty stored version is the expected value when a schema-2 state
		// file is opened for the first time after the migration journal returns.
		// Do not gate this on semver formatting: dev, dirty, and CI package
		// builds still represent a new Warren runtime and must hand off PTYs.
		versionHandoffRequired = force || storedVersion != warrenVersion
	}
	if !ghostlineSocketReady(socketPath) {
		client, err := startGhostline(config, socketPath, v1GhostlineSpawn(config))
		if err != nil {
			return nil, err
		}
		if versionHandoffRequired {
			if err := recordWarrenVersion(state, warrenVersion); err != nil {
				return nil, fmt.Errorf("record Warren version: %w", err)
			}
		}
		return client, nil
	}

	// A package version change (including an empty value from a schema-2 state)
	// always takes the direct v1 handoff path before the normal protocol check.
	// This also handles the stable socket being a symlink to the currently
	// serving per-migration socket.
	if versionHandoffRequired {
		sourceSocket := currentGhostlineRoute(socketPath)
		if !ghostlineSocketReady(sourceSocket) {
			return nil, fmt.Errorf("ghostline source is not ready: %s", sourceSocket)
		}
		if !ghostlineSocketReady(sourceSocket + ".admin") {
			return nil, fmt.Errorf("ghostline source has no admin socket: %s", sourceSocket+".admin")
		}
		sourceVersion, err := probeGhostlineVersion(context.Background(), sourceSocket)
		if err != nil {
			return nil, fmt.Errorf("read ghostline server version for handoff: %w", err)
		}
		if sourceVersion.ProtocolVersion != ghostline.ProtocolVersion {
			return nil, fmt.Errorf("unsupported ghostline source protocol %q; current runtime requires %q", sourceVersion.ProtocolVersion, ghostline.ProtocolVersion)
		}
		handoffVersion := "warren-" + warrenVersion
		if force && storedVersion == warrenVersion {
			handoffVersion += "-forced"
		}
		config.logger.Info("warren version changed, handing off ghostline", "from", storedVersion, "to", warrenVersion, "force", force)
		if err := handoffGhostline(config, sourceSocket, sourceVersion, handoffVersion, v1GhostlineSpawn(config)); err != nil {
			return nil, err
		}
		// AdoptWithReport keeps the source authoritative when any session cannot
		// be recovered. Leave WarrenVersion unchanged so a later package start
		// retries the handoff instead of permanently accepting the old owner.
		if ghostlineMigrationSkipped(state) {
			return checkedGhostlineClient(socketPath, "after retained source")
		}
		if err := recordWarrenVersion(state, warrenVersion); err != nil {
			return nil, fmt.Errorf("record Warren version after handoff: %w", err)
		}
		return checkedGhostlineClient(socketPath, "after version handoff")
	}

	// The normal path still upgrades a mismatched Ghostline protocol/tag. A
	// pre-v1 source is rejected explicitly because this package intentionally
	// ships no historical compatibility bridge.
	for attempt := 0; attempt < 2; attempt++ {
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
			if ghostlineMigrationSkipped(config.state) {
				return checkedGhostlineClient(socketPath, "after retained source")
			}

		default:
			return nil, fmt.Errorf("unsupported ghostline source protocol %q; current runtime requires %q", version.ProtocolVersion, ghostline.ProtocolVersion)
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
// local route; Ghostline owns the PTY and terminal-state transfer.
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
	sourceClient := ghostline.NewClient(sourceSocket)
	listContext, listCancel := context.WithTimeout(context.Background(), 5*time.Second)
	sourceSessions, err := sourceClient.List(listContext)
	listCancel()
	if err != nil {
		return fmt.Errorf("list ghostline source sessions: %w", err)
	}
	sourceNames := make(map[string]struct{}, len(sourceSessions))
	for _, session := range sourceSessions {
		sourceNames[session.Name()] = struct{}{}
	}

	client, err := startGhostline(config, record.TargetSocket, append(append([]string{}, spawn...), "--adopt-from", sourceSocket+".admin"))
	if err != nil {
		// A readiness timeout can happen just after commit. A visible target is
		// authoritative, because Ghostline never exposes it before commit.
		if !ghostlineSocketReady(record.TargetSocket) {
			return fmt.Errorf("start ghostline migration target: %w", err)
		}
		client = ghostline.NewClient(record.TargetSocket)
	}
	targetContext, targetCancel := context.WithTimeout(context.Background(), 5*time.Second)
	targetSessions, targetListErr := client.List(targetContext)
	targetCancel()
	if targetListErr != nil {
		return fmt.Errorf("list ghostline target sessions: %w", targetListErr)
	}
	targetNames := make(map[string]struct{}, len(targetSessions))
	for _, session := range targetSessions {
		targetNames[session.Name()] = struct{}{}
	}
	skipped := make(map[string]string)
	for name := range sourceNames {
		if _, ok := targetNames[name]; !ok {
			skipped[name] = "adopt runtime failed"
		}
	}
	if len(skipped) > 0 {
		if err := setGhostlineMigrationSkipped(config.state, record.SessionID, skipped); err != nil {
			return fmt.Errorf("record skipped ghostline sessions: %w", err)
		}
		record.SkippedSessions = make([]string, 0, len(skipped))
		for name := range skipped {
			record.SkippedSessions = append(record.SkippedSessions, name)
		}
		sort.Strings(record.SkippedSessions)
		if len(skipped) == len(sourceNames) && len(sourceNames) > 0 {
			_ = stopGhostlineServer(record.TargetSocket)
			if err := setGhostlineMigrationPhase(config.state, record.SessionID, api.GhostlineMigrationRetired); err != nil {
				return fmt.Errorf("record skipped ghostline migration: %w", err)
			}
			config.logger.Warn("ghostline adoption skipped all sessions; retaining source", "count", len(skipped))
			return nil
		}
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
		Socket: socketPath,
		Spawn:  spawn,
		// Ghostline v1 merges this list with its own os.Environ(). The daemon
		// may retain Warren/provider configuration for control-plane work, so
		// pass only the terminal baseline here; the --ghostline-serve entry
		// point applies the same boundary before creating its server.
		Env:          runtime.TerminalEnvironment(os.Environ()),
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

func checkedGhostlineClient(socketPath, phase string) (*ghostline.Client, error) {
	client := ghostline.NewClient(socketPath)
	if err := client.Check(context.Background()); err != nil {
		return nil, fmt.Errorf("check ghostline server %s: %w", phase, err)
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

func setGhostlineMigrationSkipped(state *store.Store, sessionID string, skipped map[string]string) error {
	if len(skipped) == 0 {
		return nil
	}
	now := time.Now().UTC()
	names := make([]string, 0, len(skipped))
	for k := range skipped {
		names = append(names, k)
	}
	sort.Strings(names)
	return state.Update(func(value *api.State) error {
		if value.GhostlineMigration == nil || value.GhostlineMigration.SessionID != sessionID {
			return fmt.Errorf("ghostline migration not found: %s", sessionID)
		}
		value.GhostlineMigration.SkippedSessions = names
		value.GhostlineMigration.SkipReasons = skipped
		value.GhostlineMigration.UpdatedAt = now
		return nil
	})
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

func forceGhostlineHandoffRequested() bool {
	if v := strings.TrimSpace(os.Getenv("WARREN_GHOSTLINE_FORCE_HANDOFF")); v != "" && v != "0" && !strings.EqualFold(v, "false") {
		return true
	}
	if v := strings.TrimSpace(os.Getenv("WARREN_FORCE_HANDOFF")); v != "" && v != "0" && !strings.EqualFold(v, "false") {
		return true
	}
	return false
}

func forceGhostlineHandoffRequestedFor(config ghostlineMigrationConfig) bool {
	if forceGhostlineHandoffRequested() {
		return true
	}
	marker := filepath.Join(filepath.Dir(config.stableSocket), "force-ghostline-handoff")
	if _, err := os.Stat(marker); err == nil {
		return true
	}
	return false
}

func consumeForceGhostlineHandoff(config ghostlineMigrationConfig) bool {
	requested := forceGhostlineHandoffRequestedFor(config)
	if requested {
		clearForceGhostlineHandoffMarker(config)
	}
	return requested
}

func clearForceGhostlineHandoffMarker(config ghostlineMigrationConfig) {
	_ = os.Remove(filepath.Join(filepath.Dir(config.stableSocket), "force-ghostline-handoff"))
	_ = os.Unsetenv("WARREN_GHOSTLINE_FORCE_HANDOFF")
	_ = os.Unsetenv("WARREN_FORCE_HANDOFF")
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

func recordWarrenVersion(state *store.Store, version string) error {
	if state == nil || version == "" {
		return nil
	}
	if state.Snapshot().WarrenVersion == version {
		return nil
	}
	return state.Update(func(value *api.State) error {
		value.WarrenVersion = version
		return nil
	})
}

func ghostlineMigrationSkipped(state *store.Store) bool {
	if state == nil {
		return false
	}
	migration := state.Snapshot().GhostlineMigration
	return migration != nil && len(migration.SkippedSessions) > 0
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
	return ghostlineServerVersion{}, fmt.Errorf("ghostline v1 version probe: %w", err)
}

// ghostlineSocketReady only checks local Unix reachability. It works for v1
// public/admin sockets without exposing admin RPCs to terminal clients.
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
