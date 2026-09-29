package server

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/settings"
)

func (p *wsPeer) handle(ctx context.Context, command api.Envelope) error {
	if command.Type != "request" {
		return fmt.Errorf("unsupported message type: %s", command.Type)
	}
	params := command.Params
	switch command.Method {
	case "roster":
		return p.writeResult(command.ID, p.server.Service.Roster(ctx))
	case "agent.execution.get":
		executionID := stringParam(params, "executionId")
		if executionID == "" {
			return p.writeCanonicalError(command.ID, errors.New("executionId is required"))
		}
		if session, ok := p.server.Service.sessionForCanonicalStream(executionID); ok {
			if execution, exists := p.server.Service.canonicalExecutionForSession(session.ID); exists {
				return p.writeResult(command.ID, execution)
			}
		}
		if agentStore := p.server.Service.agentStore(); agentStore != nil {
			execution, found, err := agentStore.CanonicalExecution(ctx, executionID)
			if err != nil {
				return p.writeCanonicalError(command.ID, err)
			}
			if found {
				return p.writeResult(command.ID, execution)
			}
		}
		return p.writeCanonicalError(command.ID, fmt.Errorf("agent execution not found: %s", executionID))
	case "agent.events.history":
		request, err := decodeAgentParams[api.AgentEventsHistoryRequest](params)
		if err != nil {
			return p.writeCanonicalError(command.ID, err)
		}
		request.StreamID = strings.TrimSpace(request.StreamID)
		if request.StreamID == "" {
			return p.writeCanonicalError(command.ID, errors.New("streamId is required"))
		}
		result, queryErr := p.server.Service.canonicalHistoryPage(ctx, request.StreamID, request.AfterSequence, request.BeforeSequence, int(request.Limit))
		if queryErr != nil {
			return p.writeCanonicalError(command.ID, queryErr)
		}
		return p.writeResult(command.ID, result)
	case "usage.stats":
		request, err := decodeAgentParams[api.UsageStatsRequest](params)
		if err != nil {
			return p.writeCanonicalError(command.ID, err)
		}
		result, statsErr := p.server.Service.UsageStats(ctx, request)
		if statsErr != nil {
			return p.writeCanonicalError(command.ID, statsErr)
		}
		return p.writeResult(command.ID, result)
	case "usage.rebuild":
		if err := p.requireOwner(); err != nil {
			return err
		}
		result, rebuildErr := p.server.Service.RebuildUsage(ctx)
		if rebuildErr != nil {
			return p.writeCanonicalError(command.ID, rebuildErr)
		}
		return p.writeResult(command.ID, result)
	case "agent.events.subscribe":
		request, err := decodeAgentParams[api.AgentEventsSubscriptionRequest](params)
		if err != nil {
			return p.writeCanonicalError(command.ID, err)
		}
		request.StreamID = strings.TrimSpace(request.StreamID)
		if request.StreamID == "" {
			return p.writeCanonicalError(command.ID, errors.New("streamId is required"))
		}
		session, ok := p.server.Service.sessionForCanonicalStream(request.StreamID)
		if !ok {
			return p.writeCanonicalError(command.ID, fmt.Errorf("agent execution not found: %s", request.StreamID))
		}
		lock := p.server.Service.agentLock(session.ID)
		if err := lock.LockContext(ctx); err != nil {
			return p.writeCanonicalError(command.ID, err)
		}
		result, queryErr := p.server.Service.canonicalHistoryPage(ctx, request.StreamID, request.AfterSequence, 0, int(request.Limit))
		if queryErr != nil {
			lock.Unlock()
			return p.writeCanonicalError(command.ID, queryErr)
		}
		checkpoint := p.server.Service.canonicalProjectionCheckpoint(session.ID, result.HeadSequence)
		if err := p.subscribeCanonicalAgent(session.ID, request.StreamID); err != nil {
			lock.Unlock()
			return p.writeCanonicalError(command.ID, err)
		}
		value := api.AgentEventsSubscriptionResult{
			StreamID:          request.StreamID,
			ExecutionID:       result.ExecutionID,
			Checkpoint:        checkpoint,
			Events:            result.Events,
			Live:              true,
			NextAfterSequence: result.NextAfterSequence,
			HeadSequence:      result.HeadSequence,
			HasMore:           result.HasMore,
			RetainedFrom:      result.RetainedFrom,
			StateEvents:       result.StateEvents,
		}
		writeErr := p.writeResult(command.ID, value)
		lock.Unlock()
		if writeErr != nil {
			p.unsubscribeCanonicalAgent(request.StreamID)
		}
		return writeErr
	case "agent.events.unsubscribe":
		request, err := decodeAgentParams[api.AgentEventsSubscriptionRequest](params)
		if err != nil {
			return p.writeCanonicalError(command.ID, err)
		}
		request.StreamID = strings.TrimSpace(request.StreamID)
		if request.StreamID == "" {
			return p.writeCanonicalError(command.ID, errors.New("streamId is required"))
		}
		// Unsubscribing a stream this connection does not hold is a no-op, so a
		// client can retire a Session without first asking what it holds.
		dropped := p.unsubscribeCanonicalAgent(request.StreamID)
		return p.writeResult(command.ID, map[string]any{"streamId": request.StreamID, "unsubscribed": dropped})
	case "agent.execution.resume":
		return p.handleCanonicalExecutionResume(ctx, command)
	case "agent.turn.start":
		return p.handleCanonicalTurnStart(ctx, command)
	case "agent.turn.steer":
		return p.handleCanonicalTurnSteer(ctx, command)
	case "agent.turn.cancel":
		return p.handleCanonicalTurnCancel(ctx, command)
	case "agent.interaction.resolve":
		return p.handleCanonicalInteractionResolve(ctx, command)
	case "agent.goal.set":
		return p.handleCanonicalGoalSet(ctx, command)
	case "agent.goal.clear":
		return p.handleCanonicalGoalClear(ctx, command)
	case "agent.config.set":
		return p.handleCanonicalConfigSet(ctx, command)
	case "agent.attachment.prepare":
		return p.handleCanonicalAttachmentPrepare(ctx, command)
	case "agent.attachment.chunk":
		return p.handleCanonicalAttachmentChunk(ctx, command)
	case "agent.attachment.complete":
		return p.handleCanonicalAttachmentComplete(ctx, command)
	case "agent.attachment.abort":
		return p.handleCanonicalAttachmentAbort(ctx, command)
	case "relay.pairing":
		if err := p.requireOwner(); err != nil {
			return err
		}
		if p.server.RelayPairing == nil {
			return errors.New("Relay pairing is unavailable")
		}
		value, err := p.server.RelayPairing(ctx)
		if err != nil {
			return err
		}
		return p.writeResult(command.ID, value)
	case "relay.devices.list":
		if err := p.requireOwner(); err != nil {
			return err
		}
		if p.server.RelayRouteClient == nil {
			return errors.New("Relay device management is unavailable")
		}
		client, err := p.server.RelayRouteClient()
		if err != nil {
			return err
		}
		devices, err := client.Devices(ctx)
		if err != nil {
			return err
		}
		return p.writeResult(command.ID, map[string]any{"devices": devices})
	case "relay.devices.revoke":
		if err := p.requireOwner(); err != nil {
			return err
		}
		if p.server.RelayRouteClient == nil {
			return errors.New("Relay device management is unavailable")
		}
		client, err := p.server.RelayRouteClient()
		if err != nil {
			return err
		}
		if err := client.RevokeDevice(ctx, stringParam(params, "deviceID")); err != nil {
			return err
		}
		return p.writeResult(command.ID, map[string]bool{"revoked": true})
	case "pairing.enable":
		if err := p.requireOwner(); err != nil {
			return err
		}
		value, err := p.server.armPairing()
		if err != nil {
			return err
		}
		return p.writeResult(command.ID, value)
	case "pairing.status":
		if err := p.requireOwner(); err != nil {
			return err
		}
		p.server.pairingMu.Lock()
		value := p.server.pairingStatusLocked(time.Now())
		p.server.pairingMu.Unlock()
		return p.writeResult(command.ID, value)
	case "pairing.disable":
		if err := p.requireOwner(); err != nil {
			return err
		}
		p.server.disarmPairing()
		return p.writeResult(command.ID, lanPairingStatus{})
	case "settings.get":
		if err := p.requireOwner(); err != nil {
			return err
		}
		value := p.server.Service.SettingsSnapshot()
		p.server.pairingMu.Lock()
		pairing := p.server.pairingStatusLocked(time.Now())
		p.server.pairingMu.Unlock()
		return p.writeResult(command.ID, map[string]any{
			"defaultRuntime":     value.DefaultRuntime,
			"runtimeEnv":         value.RuntimeEnv,
			"autoOpenShell":      value.AutoOpenShell,
			"autoStartAI":        value.AutoStartAI,
			"openaiBaseURL":      value.OpenAIBaseURL,
			"openaiModel":        value.OpenAIModel,
			"openaiTitleEnabled": value.OpenAITitleEnabled,
			"relay":              value.Relay,
			"publicTunnel":       value.PublicTunnel,
			"pairing":            pairing,
		})
	case "relay.reset":
		if err := p.requireOwner(); err != nil {
			return err
		}
		if err := p.server.resetRelayEnrollment(ctx); err != nil {
			return err
		}
		value := p.server.Service.SettingsSnapshot()
		p.server.pairingMu.Lock()
		pairing := p.server.pairingStatusLocked(time.Now())
		p.server.pairingMu.Unlock()
		return p.writeResult(command.ID, map[string]any{
			"reset":        true,
			"relay":        value.Relay,
			"publicTunnel": value.PublicTunnel,
			"pairing":      pairing,
		})
	case "public-access.status", "public-access.enable", "public-access.test", "public-access.disable", "public-access.reset", "public-access.restart":
		if err := p.requireOwner(); err != nil {
			return err
		}
		action := strings.TrimPrefix(command.Method, "public-access.")
		value, err := p.server.publicAccessRPC(ctx, action, stringParam(params, "publicHostname"), stringParam(params, "pathPrefix"))
		if err != nil {
			return err
		}
		return p.writeResult(command.ID, value)
	case "settings.testOpenAI":
		if err := p.requireOwner(); err != nil {
			return err
		}
		if err := p.server.Service.TestOpenAITitle(
			ctx,
			stringParam(params, "openaiBaseURL"),
			stringParam(params, "openaiModel"),
			stringParam(params, "openaiKey"),
		); err != nil {
			return err
		}
		return p.writeResult(command.ID, map[string]bool{"ok": true})
	case "settings.put":
		if err := p.requireOwner(); err != nil {
			return err
		}
		current := p.server.Service.SettingsSnapshot()
		runtimeEnv := stringMapParam(params, "runtimeEnv")
		if runtimeEnv == nil {
			runtimeEnv = current.RuntimeEnv
		}
		if err := p.server.Service.UpdateSettings(stringParam(params, "defaultRuntime"), runtimeEnv); err != nil {
			return err
		}
		if _, specified := params["autoOpenShell"]; specified {
			if err := p.server.Service.SetAutoOpenShell(boolParam(params, "autoOpenShell")); err != nil {
				return err
			}
		}
		if _, specified := params["autoStartAI"]; specified {
			if err := p.server.Service.SetAutoStartAI(boolParam(params, "autoStartAI")); err != nil {
				return err
			}
		}
		if _, specified := params["openaiBaseURL"]; specified {
			p.server.Service.Settings.OpenAIBaseURL = strings.TrimSpace(stringParam(params, "openaiBaseURL"))
		}
		if _, specified := params["openaiModel"]; specified {
			p.server.Service.Settings.OpenAIModel = strings.TrimSpace(stringParam(params, "openaiModel"))
		}
		if _, specified := params["openaiKey"]; specified {
			p.server.Service.Settings.OpenAIKey = strings.TrimSpace(stringParam(params, "openaiKey"))
		}
		if _, specified := params["openaiTitleEnabled"]; specified {
			p.server.Service.Settings.OpenAITitleEnabled = boolParam(params, "openaiTitleEnabled")
		}
		if _, specified := params["openaiBaseURL"]; specified || params["openaiModel"] != nil || params["openaiKey"] != nil || params["openaiTitleEnabled"] != nil {
			if p.server.Service.SettingsPath != "" {
				if err := settings.Save(p.server.Service.SettingsPath, p.server.Service.Settings); err != nil {
					return err
				}
			}
		}
		if value, specified := params["relay"]; specified {
			data, err := json.Marshal(value)
			var relayValue settings.RelaySettings
			if err != nil || json.Unmarshal(data, &relayValue) != nil {
				return errors.New("invalid relay settings")
			}
			if err := p.server.Service.UpdateRelaySettings(relayValue); err != nil {
				return err
			}
		}
		if value, specified := params["publicTunnel"]; specified {
			data, err := json.Marshal(value)
			var tunnelValue settings.PublicTunnelSettings
			if err != nil || json.Unmarshal(data, &tunnelValue) != nil {
				return errors.New("invalid public tunnel settings")
			}
			if err := p.server.Service.UpdatePublicTunnelSettings(tunnelValue); err != nil {
				return err
			}
		}
		if err := p.server.syncRelayLifecycle(); err != nil {
			return err
		}
		value := p.server.Service.SettingsSnapshot()
		p.server.pairingMu.Lock()
		pairing := p.server.pairingStatusLocked(time.Now())
		p.server.pairingMu.Unlock()
		return p.writeResult(command.ID, map[string]any{
			"defaultRuntime":     value.DefaultRuntime,
			"runtimeEnv":         value.RuntimeEnv,
			"autoOpenShell":      value.AutoOpenShell,
			"autoStartAI":        value.AutoStartAI,
			"openaiBaseURL":      value.OpenAIBaseURL,
			"openaiModel":        value.OpenAIModel,
			"openaiTitleEnabled": value.OpenAITitleEnabled,
			"relay":              value.Relay,
			"publicTunnel":       value.PublicTunnel,
			"pairing":            pairing,
		})
	case "project.add":
		value, err := p.server.Service.AddProjectWithOptions(
			stringParam(params, "path"),
			stringParam(params, "name"),
			boolParam(params, "autoImportGitWorktrees"),
		)
		if err != nil {
			return err
		}
		return p.writeResult(command.ID, value)
	case "task.create":
		value, err := p.server.Service.CreateTaskWithRequestID(
			stringParam(params, "name"),
			stringParam(params, "source"),
			stringParam(params, "externalID"),
			stringParam(params, "url"),
			stringParam(params, "requestId"),
		)
		if err != nil {
			return err
		}
		return p.writeResult(command.ID, value)
	case "task.remove":
		if err := p.server.Service.RemoveTask(stringParam(params, "id")); err != nil {
			return err
		}
		return p.writeResult(command.ID, map[string]bool{"removed": true})
	case "task.rename":
		if err := p.server.Service.RenameTask(stringParam(params, "id"), stringParam(params, "name")); err != nil {
			return err
		}
		return p.writeResult(command.ID, map[string]bool{"renamed": true})
	case "task.pin":
		if err := p.server.Service.SetTaskPinned(stringParam(params, "id"), boolParam(params, "pinned")); err != nil {
			return err
		}
		return p.writeResult(command.ID, map[string]bool{"pinned": boolParam(params, "pinned")})
	case "task.move":
		if err := p.server.Service.MoveTask(stringParam(params, "id"), stringParam(params, "before")); err != nil {
			return err
		}
		return p.writeResult(command.ID, map[string]bool{"moved": true})
	case "task.attach":
		if err := p.server.Service.AttachWorkspaceToTask(stringParam(params, "id"), stringParam(params, "workspace")); err != nil {
			return err
		}
		return p.writeResult(command.ID, map[string]bool{"attached": true})
	case "task.detach":
		if err := p.server.Service.DetachWorkspaceFromTask(stringParam(params, "id"), stringParam(params, "workspace")); err != nil {
			return err
		}
		return p.writeResult(command.ID, map[string]bool{"detached": true})
	case "project.worktrees":
		value, err := p.server.Service.ListProjectWorktrees(stringParam(params, "project"))
		if err != nil {
			return err
		}
		return p.writeResult(command.ID, value)
	case "project.worktrees.import":
		value, err := p.server.Service.ImportProjectWorktrees(
			stringParam(params, "project"),
			stringSliceParam(params, "paths"),
		)
		if err != nil {
			return err
		}
		return p.writeResult(command.ID, map[string]any{"workspaces": value})
	case "project.autoImportGitWorktrees":
		value, err := p.server.Service.SetProjectAutoImportGitWorktrees(
			stringParam(params, "project"),
			boolParam(params, "enabled"),
		)
		if err != nil {
			return err
		}
		return p.writeResult(command.ID, value)
	case "project.setupScript":
		value, err := p.server.Service.SetProjectSetupScript(
			stringParam(params, "project"),
			stringParam(params, "script"),
		)
		if err != nil {
			return err
		}
		return p.writeResult(command.ID, value)
	case "project.remove":
		if err := p.server.Service.RemoveProject(stringParam(params, "id"), boolParam(params, "force")); err != nil {
			return err
		}
		return p.writeResult(command.ID, map[string]bool{"removed": true})
	case "project.rename":
		if err := p.server.Service.RenameProject(stringParam(params, "id"), stringParam(params, "name")); err != nil {
			return err
		}
		return p.writeResult(command.ID, map[string]bool{"renamed": true})
	case "project.pin":
		if err := p.server.Service.SetProjectPinned(stringParam(params, "id"), boolParam(params, "pinned")); err != nil {
			return err
		}
		return p.writeResult(command.ID, map[string]bool{"pinned": boolParam(params, "pinned")})
	case "project.move":
		if err := p.server.Service.MoveProject(stringParam(params, "id"), stringParam(params, "before")); err != nil {
			return err
		}
		return p.writeResult(command.ID, map[string]bool{"moved": true})
	case "workspace.create":
		setupArgs := stringSliceParam(params, "setupArgs")
		runSetupScript := boolParam(params, "runSetupScript")
		value, err := p.server.Service.CreateTaskWorkspaceWithSetup(
			stringParam(params, "project"), stringParam(params, "task"),
			stringParam(params, "branch"), stringParam(params, "name"),
			stringParam(params, "path"), stringParam(params, "requestId"),
			runSetupScript, setupArgs,
		)
		if err != nil {
			return err
		}
		return p.writeResult(command.ID, value)
	case "workspace.remove":
		removeWorktree := true
		if value, specified, err := optionalBoolParam(params, "remove_worktree"); err != nil {
			return err
		} else if specified {
			removeWorktree = value
		}
		if err := p.server.Service.RemoveWorkspace(ctx, stringParam(params, "id"), RemoveWorkspaceOptions{
			Force:          boolParam(params, "force"),
			RemoveWorktree: removeWorktree,
		}); err != nil {
			return err
		}
		return p.writeResult(command.ID, map[string]bool{"removed": true})
	case "workspace.rename":
		if err := p.server.Service.RenameWorkspace(stringParam(params, "id"), stringParam(params, "name")); err != nil {
			return err
		}
		return p.writeResult(command.ID, map[string]bool{"renamed": true})
	case "workspace.pin":
		if err := p.server.Service.SetWorkspacePinned(stringParam(params, "id"), boolParam(params, "pinned")); err != nil {
			return err
		}
		return p.writeResult(command.ID, map[string]bool{"pinned": boolParam(params, "pinned")})
	case "workspace.move":
		if err := p.server.Service.MoveWorkspace(stringParam(params, "id"), stringParam(params, "before")); err != nil {
			return err
		}
		return p.writeResult(command.ID, map[string]bool{"moved": true})
	case "terminal-group.create":
		value, err := p.server.Service.CreateTerminalGroup(stringParam(params, "name"), stringParam(params, "home"))
		if err != nil {
			return err
		}
		return p.writeResult(command.ID, value)
	case "terminal-group.remove":
		if err := p.server.Service.RemoveTerminalGroup(ctx, stringParam(params, "id"), boolParam(params, "force")); err != nil {
			return err
		}
		return p.writeResult(command.ID, map[string]bool{"removed": true})
	case "terminal-group.rename":
		if err := p.server.Service.RenameTerminalGroup(stringParam(params, "id"), stringParam(params, "name")); err != nil {
			return err
		}
		return p.writeResult(command.ID, map[string]bool{"renamed": true})
	case "terminal-group.home":
		if err := p.server.Service.SetTerminalGroupHome(stringParam(params, "id"), stringParam(params, "path")); err != nil {
			return err
		}
		return p.writeResult(command.ID, map[string]bool{"updated": true})
	case "terminal-group.move":
		if err := p.server.Service.MoveTerminalGroup(stringParam(params, "id"), stringParam(params, "before")); err != nil {
			return err
		}
		return p.writeResult(command.ID, map[string]bool{"moved": true})
	case "pane-group.create":
		workspaceID := stringParam(params, "workspace")
		groupID := stringParam(params, "group")
		if workspaceID != "" && groupID != "" {
			return errors.New("workspace and terminal group are mutually exclusive")
		}
		ownerScope := api.SessionScopeWorkspace
		ownerID := workspaceID
		if groupID != "" {
			ownerScope = api.SessionScopeTerminalGroup
			ownerID = groupID
		}
		value, err := p.server.Service.CreatePaneGroup(
			ownerScope,
			ownerID,
			stringParam(params, "session"),
			stringParam(params, "name"),
			stringParam(params, "before"),
		)
		if err != nil {
			return err
		}
		return p.writeResult(command.ID, value)
	case "pane-group.rename":
		value, err := p.server.Service.RenamePaneGroup(stringParam(params, "id"), stringParam(params, "name"))
		if err != nil {
			return err
		}
		return p.writeResult(command.ID, value)
	case "pane-group.move":
		value, err := p.server.Service.MovePaneGroup(stringParam(params, "id"), stringParam(params, "before"))
		if err != nil {
			return err
		}
		return p.writeResult(command.ID, value)
	case "pane-group.remove":
		if err := p.server.Service.RemovePaneGroup(stringParam(params, "id")); err != nil {
			return err
		}
		return p.writeResult(command.ID, map[string]bool{"removed": true})
	case "pane-group.update":
		id := stringParam(params, "id")
		if id == "" {
			return errors.New("pane group ID is required")
		}
		tree, err := paneNodeParam(params)
		if err != nil {
			return err
		}
		expected, ok := uint64Param(params, "expectedRevision")
		if !ok {
			return errors.New("expectedRevision is required: a structural edit must name the revision it observed")
		}
		value, err := p.server.Service.UpdatePaneGroup(id, tree, expected)
		if err != nil {
			return err
		}
		return p.writeResult(command.ID, value)
	case "browser.session.create":
		headless, headlessErr := browserHeadlessFromParams(params)
		if headlessErr != nil {
			return headlessErr
		}
		var viewport api.BrowserViewport
		if err := decodeParam(params, "viewport", &viewport); err != nil {
			return err
		}
		session, err := p.server.Service.CreateBrowserSession(ctx, BrowserCreateOptions{
			WorkspaceID:     stringParam(params, "workspace"),
			TerminalGroupID: stringParam(params, "group"),
			Title:           stringParam(params, "title"),
			URL:             stringParam(params, "url"),
			Headless:        headless,
			Viewport:        viewport,
		})
		if err != nil {
			return err
		}
		// The Chromium is already running at this point, so the create answer is
		// the live projection rather than the durable record: a caller that
		// asked for a URL needs to know the browser is on it.
		projection, err := p.server.Service.BrowserSession(session.ID)
		if err != nil {
			return err
		}
		return p.writeResult(command.ID, projection)
	case "browser.session.list":
		return p.writeResult(command.ID, p.server.Service.BrowserSessions(
			stringParam(params, "workspace"),
			stringParam(params, "group"),
		))
	case "browser.session.get":
		id := stringParam(params, "id")
		if id == "" {
			return p.writeCanonicalError(command.ID, errors.New("id is required"))
		}
		projection, err := p.server.Service.BrowserSession(id)
		if err != nil {
			return p.writeCanonicalError(command.ID, err)
		}
		return p.writeResult(command.ID, projection)
	case "browser.session.close":
		id := stringParam(params, "id")
		if id == "" {
			return p.writeCanonicalError(command.ID, errors.New("id is required"))
		}
		if err := p.server.Service.CloseBrowserSession(ctx, id); err != nil {
			return p.writeCanonicalError(command.ID, err)
		}
		return p.writeResult(command.ID, map[string]bool{"closed": true})
	case "browser.action":
		id := stringParam(params, "id")
		if id == "" {
			return p.writeCanonicalError(command.ID, errors.New("id is required"))
		}
		var action api.BrowserAction
		if err := decodeParam(params, "action", &action); err != nil {
			return p.writeCanonicalError(command.ID, err)
		}
		result, err := p.server.Service.PerformBrowserAction(ctx, id, action)
		if err != nil {
			return p.writeCanonicalError(command.ID, err)
		}
		return p.writeResult(command.ID, result)
	case "browser.subscribe":
		id := stringParam(params, "id")
		if id == "" {
			return p.writeCanonicalError(command.ID, errors.New("id is required"))
		}
		return p.subscribeBrowser(command.ID, id)
	case "session.create":
		var value api.Session
		var err error
		groupID := stringParam(params, "group")
		workspaceID := stringParam(params, "workspace")
		if groupID != "" && workspaceID != "" {
			return errors.New("workspace and terminal group are mutually exclusive")
		}
		if groupID != "" {
			value, err = p.server.Service.CreateGroupSessionWithHandler(
				ctx,
				groupID,
				stringParam(params, "command"),
				stringParam(params, "kind"),
				stringParam(params, "title"),
				stringParam(params, "runtimeKind"),
				stringParam(params, "agentHandler"),
			)
		} else if workspaceID != "" {
			value, err = p.server.Service.CreateSessionWithHandler(
				ctx,
				workspaceID,
				stringParam(params, "command"),
				stringParam(params, "kind"),
				stringParam(params, "title"),
				stringParam(params, "runtimeKind"),
				stringParam(params, "agentHandler"),
			)
		} else {
			value, err = p.server.Service.CreateDefaultGroupSessionWithHandler(
				ctx,
				stringParam(params, "command"),
				stringParam(params, "kind"),
				stringParam(params, "title"),
				stringParam(params, "runtimeKind"),
				stringParam(params, "agentHandler"),
			)
		}
		if err != nil {
			return err
		}
		return p.writeResult(command.ID, publicSession(value))
	case "session.delete":
		id := stringParam(params, "id")
		if err := p.server.Service.DeleteSession(ctx, id); err != nil {
			return err
		}
		p.detachIfAttached(id)
		return p.writeResult(command.ID, map[string]bool{"deleted": true})
	case "session.handoff":
		value, err := p.server.Service.handoffACPSession(ctx, stringParam(params, "id"), stringParam(params, "command"))
		if err != nil {
			return err
		}
		p.detachIfAttached(stringParam(params, "id"))
		return p.writeResult(command.ID, publicSession(value))
	case "session.delete.preflight":
		id := stringParam(params, "id")
		if id == "" {
			return errors.New("session ID is required")
		}
		value, ok := p.server.Service.Session(id)
		if !ok {
			return fmt.Errorf("session not found: %s", id)
		}
		return p.writeResult(command.ID, map[string]any{
			"allowed": true, "resource": "session", "id": value.ID,
			"workspace": value.WorkspaceID, "terminalGroup": value.TerminalGroupID,
			"agentSessionId": value.AgentSessionID, "transcriptPath": value.TranscriptPath,
			"lifecycle": value.Lifecycle,
		})
	case "screen.report", "session.screen.report":
		var sessions []string
		if raw, ok := params["sessions"].([]any); ok {
			for _, item := range raw {
				if str, ok := item.(string); ok && strings.TrimSpace(str) != "" {
					sessions = append(sessions, strings.TrimSpace(str))
				}
			}
		} else if str := stringParam(params, "sessions"); str != "" {
			for _, part := range strings.Split(str, ",") {
				if trimmed := strings.TrimSpace(part); trimmed != "" {
					sessions = append(sessions, trimmed)
				}
			}
		}
		if err := p.setScreenSessions(sessions); err != nil {
			return err
		}
		return p.writeResult(command.ID, map[string]any{"reported": true, "screenSessions": p.screenSessionsSnapshot()})
	case "screen.panes", "session.screen.panes":
		id := stringParam(params, "id")
		if id == "" {
			return errors.New("session ID is required")
		}
		if _, ok := p.server.Service.Session(id); !ok {
			return fmt.Errorf("session not found: %s", id)
		}
		return p.writeResult(command.ID, api.ScreenPanesResult{
			SessionID: id,
			Screens:   p.server.screenLayouts(id),
		})
	case "session.current":
		id := stringParam(params, "id")
		if id == "" {
			return errors.New("session ID is required")
		}
		value, ok := p.server.Service.Session(id)
		if !ok {
			return fmt.Errorf("session not found: %s", id)
		}
		pub := publicSession(value)
		// Only the position, never the neighbours: a Session learns where its
		// own output sits on screen, and `screen.panes` answers who shares it.
		if layouts := p.server.screenLayouts(id); len(layouts) > 0 {
			pub.ScreenPosition = layouts[0].Position
			pub.ScreenPaneCount = layouts[0].PaneCount
		}
		return p.writeResult(command.ID, pub)
	case "session.rename":
		if err := p.server.Service.RenameSession(stringParam(params, "id"), stringParam(params, "title")); err != nil {
			return err
		}
		return p.writeResult(command.ID, map[string]bool{"renamed": true})
	case "session.pin":
		if err := p.server.Service.SetSessionPinned(stringParam(params, "id"), boolParam(params, "pinned")); err != nil {
			return err
		}
		return p.writeResult(command.ID, map[string]bool{"pinned": boolParam(params, "pinned")})
	case "session.move":
		id := stringParam(params, "id")
		if id == "" {
			return errors.New("session parameter required")
		}
		workspaceID := stringParam(params, "workspace")
		groupID := stringParam(params, "group")
		if workspaceID != "" && groupID != "" {
			return errors.New("workspace and terminal group are mutually exclusive")
		}
		expectations := sessionMoveExpectations(params)
		value, err := p.server.Service.MoveSessionWithExpectations(ctx, id, workspaceID, groupID, expectations)
		if err != nil {
			return err
		}
		return p.writeResult(command.ID, publicSession(value))
	case "session.move.preflight":
		id := stringParam(params, "id")
		if id == "" {
			return errors.New("session parameter required")
		}
		workspaceID := stringParam(params, "workspace")
		groupID := stringParam(params, "group")
		if workspaceID != "" && groupID != "" {
			return errors.New("workspace and terminal group are mutually exclusive")
		}
		value, err := p.server.Service.PreflightSessionMove(id, workspaceID, groupID, sessionMoveExpectations(params))
		if err != nil {
			return err
		}
		return p.writeResult(command.ID, publicSessionMovePreflight(value))
	case "session.undo":
		value, err := p.server.Service.UndoSessionMove(stringParam(params, "operation"))
		if err != nil {
			return err
		}
		return p.writeResult(command.ID, publicSession(value))
	case "session.subscribe":
		// Output-only subscription for one session. A peer may hold many at
		// once; focus, resize, and input ownership are untouched so several
		// endpoints can observe the same terminal without fighting over its
		// shared runtime size.
		id := stringParam(params, "id")
		subscriptionContext, finishSubscription := p.beginPendingSubscription(ctx, id)
		defer finishSubscription()
		ctx = subscriptionContext
		if err := ctx.Err(); err != nil {
			return err
		}
		session, ok := p.server.Service.Session(id)
		if !ok {
			return fmt.Errorf("session not found: %s", id)
		}
		if session.Lifecycle != "running" {
			return fmt.Errorf("session is not running: %s", id)
		}
		if session.Kind == sessionKindBrowser {
			// A browser Session has no terminal to attach to. A client that
			// subscribes to everything it displays reaches this branch, so it
			// must succeed rather than fail on a browser it is also viewing.
			return p.subscribeBrowser(command.ID, id)
		}
		if isACPSession(session) {
			// An ACP Session has no terminal stream. A client that subscribes
			// to everything it displays must not fail on one; its conversation
			// arrives through agent.events.subscribe.
			return p.writeResult(command.ID, map[string]any{"subscribed": true, "attachmentId": p.ensureAttachment(session.ID), "terminal": false})
		}
		anchor := anchorFromParams(params)
		anchorLabel := "none"
		if anchor != nil {
			anchorLabel = fmt.Sprintf("epoch=%d sequence=%d", anchor.Epoch, anchor.Sequence)
		}
		claimControl, claimSpecified, claimErr := optionalBoolParam(params, "claim")
		if claimErr != nil {
			return claimErr
		}
		columns, rows, sizeSpecified, sizeErr := attachSizeFromParams(params)
		if sizeErr != nil {
			return sizeErr
		}
		p.logInfo("subscribe: begin", "session", id, "anchor", anchorLabel,
			"claim", claimControl, "claimSpecified", claimSpecified,
			"size", fmt.Sprintf("%dx%d", columns, rows), "specified", sizeSpecified)
		stepStart := time.Now()
		markStep := func(step string) {
			p.logInfo("subscribe: step", "session", id, "step", step, "ms", time.Since(stepStart).Milliseconds())
		}
		lock, resume, err := p.server.Service.prepareAttach(ctx, session)
		if err != nil {
			return err
		}
		markStep("prepareAttach")
		if p.server.Service.cursorOutputRuntimeFor(session) != nil {
			p.server.Service.reservePeerCursorOutput(p, session.ID)
		}
		markStep("reservePeerCursorOutput")
		if err := ctx.Err(); err != nil {
			lock.Unlock()
			resume()
			p.server.Service.detachPeer(p, session.ID)
			return err
		}
		p.server.Service.registerPeer(session.ID, p)
		attachmentID := p.ensureAttachment(session.ID)
		if claimControl {
			if _, focusErr := p.server.Service.focusPeerLocked(ctx, p, session, true, columns, rows, sizeSpecified, false); focusErr != nil {
				lock.Unlock()
				resume()
				p.server.Service.detachPeer(p, session.ID)
				return focusErr
			}
			p.claimControl(session)
		}
		markStep("registerAndClaim")
		if err := ctx.Err(); err != nil {
			lock.Unlock()
			resume()
			p.detach()
			return err
		}
		// Passive subscribers never mutate the shared runtime. A selected
		// desktop attach may explicitly claim control; in that case the resize
		// above runs while the session output lock is held, before checkpoint.
		// A subscription response is deliberately acknowledged before replaying
		// the recovery payload. Desktop can claim the control lease and keep
		// input responsive while the staged terminal output drains in the
		// background; the `synced` marker remains the presentation boundary.
		if err := p.writeResult(command.ID, map[string]any{"subscribed": true, "attachmentId": attachmentID}); err != nil {
			lock.Unlock()
			resume()
			p.server.Service.detachPeer(p, session.ID)
			return err
		}
		markStep("writeSubscribed")
		if err := p.server.Service.attachOutputLocked(ctx, p, session, anchor, "session.subscribe"); err != nil {
			lock.Unlock()
			resume()
			p.server.Service.detachPeer(p, session.ID)
			return err
		}
		markStep("attachOutputLocked")
		lock.Unlock()
		resume()
		return nil
	case "session.unsubscribe":
		id := stringParam(params, "id")
		p.cancelPendingSubscription(id)
		p.server.Service.detachPeer(p, id)
		if p.attachedSessionID() == id {
			p.detach()
		}
		return p.writeResult(command.ID, map[string]bool{"unsubscribed": true})
	case "session.focus":
		agentOnly, _, agentErr := optionalBoolParam(params, "agent")
		if agentErr != nil {
			return agentErr
		}
		if agentOnly {
			requestedSessionID := stringParam(params, "id")
			if requestedSessionID == "" {
				return errors.New("session parameter required")
			}
			session, found := p.server.Service.Session(requestedSessionID)
			if !found {
				return fmt.Errorf("session not found: %s", requestedSessionID)
			}
			if session.Lifecycle != "running" {
				return fmt.Errorf("session is not running: %s", requestedSessionID)
			}
			focused, specified, focusErr := optionalBoolParam(params, "focused")
			if focusErr != nil {
				return focusErr
			}
			if !specified {
				focused = true
			}
			if focused {
				// Agent-only clients subscribe to the canonical stream, not to
				// terminal output. Record agent focus without contending with
				// or requiring the single-tenant Terminal PTY control lease.
				p.claimAgentControl(requestedSessionID)
			} else {
				p.releaseControl(requestedSessionID)
			}
			return p.writeResult(command.ID, map[string]bool{"focused": focused, "resized": false})
		}
		attached, ok := p.attachedSession()
		requestedSessionID := stringParam(params, "id")
		if requestedSessionID != "" {
			// Web can subscribe passively while hidden, so it has no attached
			// control pointer yet. Allow an explicit focus target only when this
			// peer already owns an output subscription for that session; a random
			// id must never become an input or resize lease.
			if attached.ID != requestedSessionID || !ok {
				session, found := p.server.Service.Session(requestedSessionID)
				if !found {
					return fmt.Errorf("session not found: %s", requestedSessionID)
				}
				if !p.hasOutput(requestedSessionID) {
					return fmt.Errorf("session is not subscribed: %s", requestedSessionID)
				}
				attached, ok = session, true
			}
		}
		if !ok {
			return fmt.Errorf("no attached session")
		}
		focused, specified, err := optionalBoolParam(params, "focused")
		if err != nil {
			return err
		}
		if !specified {
			focused = true
		}
		columns, rows, resizeSpecified, err := attachSizeFromParams(params)
		if err != nil {
			return err
		}
		isFocused, resized, err := p.server.Service.focusPeer(
			ctx,
			p,
			attached,
			focused,
			columns,
			rows,
			resizeSpecified && focused,
			// The lease is granted before the size is applied, so a slow PTY
			// resize can no longer delay the focus reply or the next command.
			true,
		)
		if err != nil {
			return err
		}
		if focused {
			if isFocused {
				// Keep the target attached for subsequent focus/resize/input
				// requests. This is a control-lease promotion, not a new output
				// subscription.
				p.claimControl(attached)
			}
		} else {
			p.releaseControl(attached.ID)
		}
		return p.writeResult(command.ID, map[string]bool{
			"focused": isFocused,
			"resized": resized,
		})
	case "session.resize":
		// New clients identify the target explicitly. This keeps resize tied to
		// the same session identity as focus and prevents a stale attached
		// pointer from routing a viewport update to another subscription. Keep
		// the implicit path for older clients until the protocol version moves.
		requestedSessionID := stringParam(params, "id")
		var attached api.Session
		var ok bool
		if requestedSessionID != "" {
			var found bool
			attached, found = p.server.Service.Session(requestedSessionID)
			if !found {
				return fmt.Errorf("session not found: %s", requestedSessionID)
			}
			if attached.Lifecycle != "running" {
				return fmt.Errorf("session is not running: %s", requestedSessionID)
			}
			if !p.hasOutput(requestedSessionID) {
				return fmt.Errorf("session is not subscribed: %s", requestedSessionID)
			}
			ok = true
		} else {
			attached, ok = p.attachedSession()
		}
		if !ok {
			return fmt.Errorf("no attached session")
		}
		columns := intParam(params, "cols")
		rows := intParam(params, "rows")
		if columns <= 0 || rows <= 0 {
			return fmt.Errorf("invalid terminal size")
		}
		resized, err := p.server.Service.resizeFocused(ctx, p, attached, columns, rows)
		if err != nil {
			return err
		}
		return p.writeResult(command.ID, map[string]bool{"resized": resized})
	case "git.panel":
		panel, err := p.server.Service.GitPanel(ctx, stringParam(params, "workspace"), boolParam(params, "fetch"), boolParam(params, "force"))
		if err != nil {
			return err
		}
		return p.writeResult(command.ID, panel)
	case "git.diff":
		diff, err := p.server.Service.GitDiff(ctx, stringParam(params, "workspace"), stringParam(params, "path"), boolParam(params, "staged"), stringParam(params, "commit"))
		if err != nil {
			return err
		}
		return p.writeResult(command.ID, diff)
	case "git.checkout":
		result, err := p.server.Service.GitCheckout(ctx, stringParam(params, "workspace"), stringParam(params, "branch"), boolParam(params, "create"))
		if err != nil {
			return err
		}
		return p.writeResult(command.ID, result)
	case "git.pull":
		result, err := p.server.Service.GitPull(ctx, stringParam(params, "workspace"))
		if err != nil {
			return err
		}
		return p.writeResult(command.ID, result)
	case "git.push":
		result, err := p.server.Service.GitPush(ctx, stringParam(params, "workspace"))
		if err != nil {
			return err
		}
		return p.writeResult(command.ID, result)
	case "git.commit":
		message := strings.TrimSpace(stringParam(params, "message"))
		if message == "" {
			return fmt.Errorf("commit message is required")
		}
		result, err := p.server.Service.GitCommit(ctx, stringParam(params, "workspace"), message)
		if err != nil {
			return err
		}
		return p.writeResult(command.ID, result)
	case "git.pr.create":
		title := strings.TrimSpace(stringParam(params, "title"))
		if title == "" {
			return fmt.Errorf("pull request title is required")
		}
		result, err := p.server.Service.GitCreatePullRequest(ctx, stringParam(params, "workspace"), title, stringParam(params, "body"))
		if err != nil {
			return err
		}
		return p.writeResult(command.ID, result)
	default:
		return fmt.Errorf("unknown method: %s", command.Method)
	}
}
