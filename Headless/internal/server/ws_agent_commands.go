package server

import (
	"context"
	"errors"
	"fmt"
	"strconv"
	"strings"

	"github.com/abcdlsj/warren/Headless/internal/api"
)

func (p *wsPeer) canonicalCommandSession(ctx context.Context, command api.AgentCommand) (api.Session, api.AgentExecution, error) {
	if strings.TrimSpace(command.CommandID) == "" || strings.TrimSpace(command.ExecutionID) == "" {
		return api.Session{}, api.AgentExecution{}, errors.New("commandId and executionId are required")
	}
	session, ok := p.server.Service.sessionForCanonicalStream(command.ExecutionID)
	if !ok {
		return api.Session{}, api.AgentExecution{}, fmt.Errorf("agent execution not found: %s", command.ExecutionID)
	}
	execution, ok := p.server.Service.canonicalExecutionForSession(session.ID)
	if !ok || execution.ID != command.ExecutionID {
		return api.Session{}, api.AgentExecution{}, fmt.Errorf("agent execution not found: %s", command.ExecutionID)
	}
	// Canonical Agent View operations (turns, interactions, goals, attachments)
	// operate through structured idempotent RPCs and do not require the
	// single-tenant Terminal PTY control lease.
	admitted, err := p.server.Service.canonicalCommandAdmitted(ctx, command.ExecutionID, command.CommandID)
	if err != nil {
		return api.Session{}, api.AgentExecution{}, fmt.Errorf("load canonical command admission: %w", err)
	}
	if !admitted && command.ExpectedVersion > 0 && command.ExpectedVersion != execution.HeadSequence {
		return api.Session{}, api.AgentExecution{}, fmt.Errorf("stale expectedVersion: got %d, current %d", command.ExpectedVersion, execution.HeadSequence)
	}
	return session, execution, nil
}

func (p *wsPeer) handleCanonicalExecutionResume(ctx context.Context, command api.Envelope) error {
	base, err := decodeCanonicalCommand(command.Params)
	if err != nil {
		return p.writeCanonicalError(command.ID, err)
	}
	session, _, err := p.canonicalCommandSession(ctx, base)
	if err != nil {
		return p.writeCanonicalError(command.ID, err)
	}
	result, runErr := p.server.Service.runCanonicalCommand(
		ctx, base.ExecutionID, base.CommandID, base,
		func() (any, error) {
			_, err := p.server.Service.ensureAgent(ctx, session)
			if err != nil {
				return nil, err
			}
			return api.AgentCommandReceipt{CommandID: base.CommandID, Accepted: true}, nil
		},
	)
	if runErr != nil {
		return p.writeCanonicalError(command.ID, runErr)
	}
	return p.writeResult(command.ID, result)
}

func (p *wsPeer) handleCanonicalTurnStart(ctx context.Context, command api.Envelope) error {
	request, err := decodeAgentParams[api.AgentTurnStartCommand](command.Params)
	if err != nil {
		return p.writeCanonicalError(command.ID, err)
	}
	session, _, err := p.canonicalCommandSession(ctx, request.AgentCommand)
	if err != nil {
		return p.writeCanonicalError(command.ID, err)
	}
	result, runErr := p.server.Service.runCanonicalCommand(
		ctx, request.ExecutionID, request.CommandID, request,
		func() (any, error) {
			result, err := p.server.Service.sendAgentMessage(ctx, api.AgentMessageSendRequest{
				Session: session.ID, ClientMessageID: request.CommandID,
				Text: request.Text, Attachments: request.Attachments,
			})
			if err != nil {
				return nil, err
			}
			return api.AgentCommandReceipt{CommandID: request.CommandID, Accepted: result.Accepted}, nil
		},
	)
	if runErr != nil {
		return p.writeCanonicalError(command.ID, runErr)
	}
	return p.writeResult(command.ID, result)
}

func (p *wsPeer) handleCanonicalTurnSteer(ctx context.Context, command api.Envelope) error {
	request, err := decodeAgentParams[api.AgentTurnSteerCommand](command.Params)
	if err != nil {
		return p.writeCanonicalError(command.ID, err)
	}
	session, _, err := p.canonicalCommandSession(ctx, request.AgentCommand)
	if err != nil {
		return p.writeCanonicalError(command.ID, err)
	}
	if request.TurnID == "" {
		return p.writeCanonicalError(command.ID, errors.New("turnId is required"))
	}
	turnID, parseErr := strconv.ParseUint(request.TurnID, 10, 64)
	if parseErr != nil || turnID == 0 {
		return p.writeCanonicalError(command.ID, errors.New("turnId must be a positive integer"))
	}
	result, runErr := p.server.Service.runCanonicalCommand(
		ctx, request.ExecutionID, request.CommandID, request,
		func() (any, error) {
			_, err := p.server.Service.interruptAgentTurn(ctx, api.AgentTurnInterruptRequest{
				CommandID: request.CommandID, Session: session.ID, Turn: turnID, Reason: "send_now",
				Replacement: &api.AgentMessageSendRequest{
					Session: session.ID, ClientMessageID: request.CommandID,
					Text: request.Text, Attachments: request.Attachments,
				},
			})
			if err != nil {
				return nil, err
			}
			return api.AgentCommandReceipt{CommandID: request.CommandID, Accepted: true}, nil
		},
	)
	if runErr != nil {
		return p.writeCanonicalError(command.ID, runErr)
	}
	return p.writeResult(command.ID, result)
}

func (p *wsPeer) handleCanonicalTurnCancel(ctx context.Context, command api.Envelope) error {
	request, err := decodeAgentParams[api.AgentTurnCancelCommand](command.Params)
	if err != nil {
		return p.writeCanonicalError(command.ID, err)
	}
	session, _, err := p.canonicalCommandSession(ctx, request.AgentCommand)
	if err != nil {
		return p.writeCanonicalError(command.ID, err)
	}
	turnID, parseErr := strconv.ParseUint(strings.TrimSpace(request.TurnID), 10, 64)
	if parseErr != nil || turnID == 0 {
		return p.writeCanonicalError(command.ID, errors.New("turnId must be a positive integer"))
	}
	result, runErr := p.server.Service.runCanonicalCommand(
		ctx, request.ExecutionID, request.CommandID, request,
		func() (any, error) {
			_, err := p.server.Service.interruptAgentTurn(ctx, api.AgentTurnInterruptRequest{
				CommandID: request.CommandID, Session: session.ID, Turn: turnID, Reason: "cancel",
			})
			if err != nil {
				return nil, err
			}
			return api.AgentCommandReceipt{CommandID: request.CommandID, Accepted: true}, nil
		},
	)
	if runErr != nil {
		return p.writeCanonicalError(command.ID, runErr)
	}
	return p.writeResult(command.ID, result)
}

func (p *wsPeer) handleCanonicalInteractionResolve(ctx context.Context, command api.Envelope) error {
	request, err := decodeAgentParams[api.AgentInteractionResolveCommand](command.Params)
	if err != nil {
		return p.writeCanonicalError(command.ID, err)
	}
	session, _, err := p.canonicalCommandSession(ctx, request.AgentCommand)
	if err != nil {
		return p.writeCanonicalError(command.ID, err)
	}
	result, runErr := p.server.Service.runCanonicalCommand(
		ctx, request.ExecutionID, request.CommandID, request,
		func() (any, error) {
			// Keep all mutable interaction checks inside the canonical command
			// callback. A retry with the same command ID must replay the durable
			// result before the interaction's state/version can become stale.
			if strings.TrimSpace(request.InteractionID) == "" || request.Version == 0 {
				return nil, errors.New("interactionId and version are required")
			}
			interaction, found := p.server.Service.canonicalInteraction(session.ID, request.InteractionID)
			if !found {
				return nil, fmt.Errorf("interaction not found: %s", request.InteractionID)
			}
			if request.Version != interaction.version {
				return nil, &canonicalProtocolError{
					code:    "stale_interaction",
					message: fmt.Sprintf("interaction %s is version %d, not %d", request.InteractionID, interaction.version, request.Version),
					details: map[string]any{"interactionId": request.InteractionID, "currentVersion": interaction.version, "state": interaction.state},
				}
			}
			if interaction.state != "" && interaction.state != "pending" && interaction.state != "submitting" {
				return nil, &canonicalProtocolError{
					code:    "stale_interaction",
					message: fmt.Sprintf("interaction %s is %s", request.InteractionID, interaction.state),
					details: map[string]any{"interactionId": request.InteractionID, "currentVersion": interaction.version, "state": interaction.state},
				}
			}
			if err := validateCanonicalInteractionResolution(interaction, request.Resolution); err != nil {
				return nil, &canonicalProtocolError{
					code:    "invalid_interaction_resolution",
					message: err.Error(),
					details: map[string]any{"interactionId": request.InteractionID, "kind": interaction.kind, "version": interaction.version},
				}
			}
			_, err := p.server.Service.respondAgentInteraction(ctx, api.AgentInteractionResponse{
				CommandID: request.CommandID, Session: session.ID, RequestID: request.InteractionID,
				Kind: interaction.kind, Response: request.Resolution,
			})
			if err != nil {
				return nil, err
			}
			return api.AgentCommandReceipt{CommandID: request.CommandID, Accepted: true}, nil
		},
	)
	if runErr != nil {
		return p.writeCanonicalError(command.ID, runErr)
	}
	return p.writeResult(command.ID, result)
}

func (p *wsPeer) handleCanonicalGoalSet(ctx context.Context, command api.Envelope) error {
	request, err := decodeAgentParams[api.AgentGoalSetCommand](command.Params)
	if err != nil {
		return p.writeCanonicalError(command.ID, err)
	}
	session, _, err := p.canonicalCommandSession(ctx, request.AgentCommand)
	if err != nil {
		return p.writeCanonicalError(command.ID, err)
	}
	result, runErr := p.server.Service.runCanonicalCommand(
		ctx, request.ExecutionID, request.CommandID, request,
		func() (any, error) {
			goal, err := p.server.Service.setAgentGoal(ctx, api.AgentGoalSetRequest{
				CommandID:       request.CommandID,
				Session:         session.ID,
				Objective:       request.Objective,
				Status:          request.Status,
				TokenBudget:     request.TokenBudget,
				ReplaceExisting: request.ReplaceExisting,
			})
			if err != nil {
				return nil, err
			}
			return api.AgentCommandReceipt{CommandID: request.CommandID, Accepted: goal.Accepted}, nil
		},
	)
	if runErr != nil {
		return p.writeCanonicalError(command.ID, runErr)
	}
	return p.writeResult(command.ID, result)
}

func (p *wsPeer) handleCanonicalGoalClear(ctx context.Context, command api.Envelope) error {
	request, err := decodeAgentParams[api.AgentGoalClearCommand](command.Params)
	if err != nil {
		return p.writeCanonicalError(command.ID, err)
	}
	session, _, err := p.canonicalCommandSession(ctx, request.AgentCommand)
	if err != nil {
		return p.writeCanonicalError(command.ID, err)
	}
	result, runErr := p.server.Service.runCanonicalCommand(
		ctx, request.ExecutionID, request.CommandID, request,
		func() (any, error) {
			goal, err := p.server.Service.clearAgentGoal(ctx, api.AgentGoalClearRequest{
				CommandID: request.CommandID,
				Session:   session.ID,
			})
			if err != nil {
				return nil, err
			}
			return api.AgentCommandReceipt{CommandID: request.CommandID, Accepted: goal.Accepted}, nil
		},
	)
	if runErr != nil {
		return p.writeCanonicalError(command.ID, runErr)
	}
	return p.writeResult(command.ID, result)
}
func (p *wsPeer) handleCanonicalConfigSet(ctx context.Context, command api.Envelope) error {
	request, err := decodeAgentParams[api.AgentConfigSetCommand](command.Params)
	if err != nil {
		return p.writeCanonicalError(command.ID, err)
	}
	session, _, err := p.canonicalCommandSession(ctx, request.AgentCommand)
	if err != nil {
		return p.writeCanonicalError(command.ID, err)
	}
	result, runErr := p.server.Service.runCanonicalCommand(
		ctx, request.ExecutionID, request.CommandID, request,
		func() (any, error) {
			if err := p.server.Service.setAgentConfig(ctx, session.ID, request.ConfigID, request.Value); err != nil {
				return nil, err
			}
			return api.AgentCommandReceipt{CommandID: request.CommandID, Accepted: true}, nil
		},
	)
	if runErr != nil {
		return p.writeCanonicalError(command.ID, runErr)
	}
	return p.writeResult(command.ID, result)
}

func (p *wsPeer) canonicalAttachmentSession(ctx context.Context, command api.AgentCommand) (api.Session, error) {
	session, _, err := p.canonicalCommandSession(ctx, command)
	if err != nil {
		return api.Session{}, err
	}
	return session, nil
}

func (p *wsPeer) requireCanonicalAttachmentCapability(session api.Session) error {
	if !p.server.Service.sessionSupportsCapability(session.ID, CapabilityAttachments) {
		return fmt.Errorf("capability %s is not available for session %s", api.CapabilityAgentAttachments, session.ID)
	}
	return nil
}

func (p *wsPeer) handleCanonicalAttachmentPrepare(ctx context.Context, command api.Envelope) error {
	request, err := decodeAgentParams[api.AgentAttachmentPrepareCommand](command.Params)
	if err != nil {
		return p.writeCanonicalError(command.ID, err)
	}
	session, err := p.canonicalAttachmentSession(ctx, request.AgentCommand)
	if err != nil {
		return p.writeCanonicalError(command.ID, err)
	}
	result, runErr := p.server.Service.runCanonicalCommand(
		ctx, request.ExecutionID, request.CommandID, request,
		func() (any, error) {
			if err := p.requireCanonicalAttachmentCapability(session); err != nil {
				return nil, err
			}
			return p.server.Service.prepareAgentAttachment(ctx, session.ID, api.AgentAttachmentPrepareRequest{
				Session: session.ID, Name: request.Name, MIME: request.MIME, Size: request.Size, SHA256: request.SHA256,
			})
		},
	)
	if runErr != nil {
		return p.writeCanonicalError(command.ID, runErr)
	}
	return p.writeResult(command.ID, result)
}

func (p *wsPeer) handleCanonicalAttachmentChunk(ctx context.Context, command api.Envelope) error {
	request, err := decodeAgentParams[api.AgentAttachmentChunkCommand](command.Params)
	if err != nil {
		return p.writeCanonicalError(command.ID, err)
	}
	session, err := p.canonicalAttachmentSession(ctx, request.AgentCommand)
	if err != nil {
		return p.writeCanonicalError(command.ID, err)
	}
	result, runErr := p.server.Service.runCanonicalCommand(
		ctx, request.ExecutionID, request.CommandID, request,
		func() (any, error) {
			if err := p.requireCanonicalAttachmentCapability(session); err != nil {
				return nil, err
			}
			return p.server.Service.putAgentAttachmentChunk(ctx, api.AgentAttachmentChunkRequest{
				Session: session.ID, UploadID: request.UploadID, Sequence: request.Chunk,
				Length: request.Length, SHA256: request.SHA256, Data: request.Data,
			})
		},
	)
	if runErr != nil {
		return p.writeCanonicalError(command.ID, runErr)
	}
	return p.writeResult(command.ID, result)
}

func (p *wsPeer) handleCanonicalAttachmentComplete(ctx context.Context, command api.Envelope) error {
	request, err := decodeAgentParams[api.AgentAttachmentCompleteCommand](command.Params)
	if err != nil {
		return p.writeCanonicalError(command.ID, err)
	}
	session, err := p.canonicalAttachmentSession(ctx, request.AgentCommand)
	if err != nil {
		return p.writeCanonicalError(command.ID, err)
	}
	result, runErr := p.server.Service.runCanonicalCommand(
		ctx, request.ExecutionID, request.CommandID, request,
		func() (any, error) {
			if err := p.requireCanonicalAttachmentCapability(session); err != nil {
				return nil, err
			}
			return p.server.Service.completeAgentAttachment(ctx, api.AgentAttachmentCompleteRequest{
				Session: session.ID, UploadID: request.UploadID, Length: request.Length, SHA256: request.SHA256,
			})
		},
	)
	if runErr != nil {
		return p.writeCanonicalError(command.ID, runErr)
	}
	return p.writeResult(command.ID, result)
}

func (p *wsPeer) handleCanonicalAttachmentAbort(ctx context.Context, command api.Envelope) error {
	request, err := decodeAgentParams[api.AgentAttachmentAbortCommand](command.Params)
	if err != nil {
		return p.writeCanonicalError(command.ID, err)
	}
	session, err := p.canonicalAttachmentSession(ctx, request.AgentCommand)
	if err != nil {
		return p.writeCanonicalError(command.ID, err)
	}
	result, runErr := p.server.Service.runCanonicalCommand(
		ctx, request.ExecutionID, request.CommandID, request,
		func() (any, error) {
			if err := p.requireCanonicalAttachmentCapability(session); err != nil {
				return nil, err
			}
			return p.server.Service.abortAgentAttachment(ctx, api.AgentAttachmentAbortRequest{Session: session.ID, UploadID: request.UploadID})
		},
	)
	if runErr != nil {
		return p.writeCanonicalError(command.ID, runErr)
	}
	return p.writeResult(command.ID, result)
}
