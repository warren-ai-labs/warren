package server

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"github.com/abcdlsj/warren/Headless/internal/api"
)

func normalizeCreationRequestID(value string) (string, error) {
	value = strings.ToLower(strings.TrimSpace(value))
	if value == "" {
		return "", nil
	}
	if len(value) != 36 || value[8] != '-' || value[13] != '-' || value[18] != '-' || value[23] != '-' {
		return "", errors.New("request ID must be a UUID")
	}
	if _, err := hex.DecodeString(strings.ReplaceAll(value, "-", "")); err != nil {
		return "", errors.New("request ID must be a UUID")
	}
	return value, nil
}

func creationRequestHash(method string, parameters ...string) string {
	encoded, _ := json.Marshal(append([]string{method}, parameters...))
	digest := sha256.Sum256(encoded)
	return hex.EncodeToString(digest[:])
}

func taskCreationReplay(state *api.State, requestID, requestHash string) (api.Task, bool, error) {
	if requestID == "" {
		return api.Task{}, false, nil
	}
	for _, task := range state.Tasks {
		if task.CreationRequestID != requestID {
			continue
		}
		if task.CreationRequestHash != requestHash {
			return api.Task{}, false, fmt.Errorf(
				"request ID %q was already used for task.create with conflicting parameters", requestID,
			)
		}
		return task, true, nil
	}
	for _, workspace := range state.Workspaces {
		if workspace.CreationRequestID == requestID {
			return api.Task{}, false, fmt.Errorf("request ID %q was already used by workspace.create", requestID)
		}
	}
	return api.Task{}, false, nil
}

func workspaceCreationReplay(state *api.State, requestID, requestHash string) (api.WorkspaceCreateResult, bool, error) {
	if requestID == "" {
		return api.WorkspaceCreateResult{}, false, nil
	}
	for _, workspace := range state.Workspaces {
		if workspace.CreationRequestID != requestID {
			continue
		}
		if workspace.CreationRequestHash != requestHash {
			return api.WorkspaceCreateResult{}, false, fmt.Errorf(
				"request ID %q was already used for workspace.create with conflicting parameters", requestID,
			)
		}
		return workspaceCreateResult(workspace), true, nil
	}
	for _, task := range state.Tasks {
		if task.CreationRequestID == requestID {
			return api.WorkspaceCreateResult{}, false, fmt.Errorf("request ID %q was already used by task.create", requestID)
		}
	}
	return api.WorkspaceCreateResult{}, false, nil
}

func workspaceCreateResult(workspace api.Workspace) api.WorkspaceCreateResult {
	return api.WorkspaceCreateResult{
		Workspace:   workspace,
		Created:     true,
		GitWorktree: workspace.ManagedWorktree,
	}
}

func withoutTaskCreationMetadata(task api.Task) api.Task {
	task.CreationRequestID = ""
	task.CreationRequestHash = ""
	return task
}

func withoutWorkspaceCreationMetadata(result api.WorkspaceCreateResult) api.WorkspaceCreateResult {
	result.CreationRequestID = ""
	result.CreationRequestHash = ""
	return result
}
