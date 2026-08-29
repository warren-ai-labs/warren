package server

import (
	"errors"
	"fmt"
	"net/url"
	"slices"
	"strings"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/store"
)

func (s *Service) CreateTask(name, source, externalID, rawURL string) (api.Task, error) {
	return s.CreateTaskWithRequestID(name, source, externalID, rawURL, "")
}

func (s *Service) CreateTaskWithRequestID(name, source, externalID, rawURL, requestID string) (api.Task, error) {
	var err error
	requestID, err = normalizeCreationRequestID(requestID)
	if err != nil {
		return api.Task{}, err
	}
	name = strings.TrimSpace(name)
	if name == "" {
		return api.Task{}, errors.New("task name cannot be empty")
	}
	source = strings.ToLower(strings.TrimSpace(source))
	externalID = strings.TrimSpace(externalID)
	if (source == "") != (externalID == "") {
		return api.Task{}, errors.New("task source and external ID must be provided together")
	}
	rawURL, err = normalizeTaskURL(rawURL)
	if err != nil {
		return api.Task{}, err
	}
	requestHash := ""
	if requestID != "" {
		requestHash = creationRequestHash("task.create", name, source, externalID, rawURL)
	}
	task := api.Task{
		ID:                  store.NewID(),
		Name:                name,
		Source:              source,
		ExternalID:          externalID,
		URL:                 rawURL,
		CreationRequestID:   requestID,
		CreationRequestHash: requestHash,
		CreatedAt:           time.Now().UTC(),
	}
	err = s.Store.Update(func(state *api.State) error {
		if existing, found, err := taskCreationReplay(state, requestID, requestHash); err != nil {
			return err
		} else if found {
			task = existing
			return nil
		}
		for _, existing := range state.Tasks {
			if source != "" && existing.Source == source && existing.ExternalID == externalID {
				return fmt.Errorf("task already exists for %s %q: %s", source, externalID, existing.ID)
			}
		}
		task.Order = nextTaskOrder(state.Tasks)
		state.Tasks = append(state.Tasks, task)
		return nil
	})
	return withoutTaskCreationMetadata(task), err
}

func (s *Service) RemoveTask(id string) error {
	return s.Store.Update(func(state *api.State) error {
		found := false
		state.Tasks = filter(state.Tasks, func(task api.Task) bool {
			if task.ID == id {
				found = true
				return false
			}
			return true
		})
		if !found {
			return fmt.Errorf("task not found: %s", id)
		}
		for index := range state.Tasks {
			state.Tasks[index].Order = index
		}
		for index := range state.Workspaces {
			if state.Workspaces[index].TaskID == id {
				state.Workspaces[index].TaskID = ""
			}
		}
		return nil
	})
}

func (s *Service) RenameTask(id, name string) error {
	name = strings.TrimSpace(name)
	if name == "" {
		return errors.New("task name cannot be empty")
	}
	return s.Store.Update(func(state *api.State) error {
		for index := range state.Tasks {
			if state.Tasks[index].ID == id {
				state.Tasks[index].Name = name
				return nil
			}
		}
		return fmt.Errorf("task not found: %s", id)
	})
}

func (s *Service) SetTaskPinned(id string, pinned bool) error {
	return s.Store.Update(func(state *api.State) error {
		for index := range state.Tasks {
			if state.Tasks[index].ID == id {
				state.Tasks[index].Pinned = pinned
				return nil
			}
		}
		return fmt.Errorf("task not found: %s", id)
	})
}

func (s *Service) MoveTask(id, before string) error {
	return s.Store.Update(func(state *api.State) error {
		sortTasks(state.Tasks)
		index := slices.IndexFunc(state.Tasks, func(task api.Task) bool { return task.ID == id })
		if index < 0 {
			return fmt.Errorf("task not found: %s", id)
		}
		target := len(state.Tasks)
		if before != "" {
			target = slices.IndexFunc(state.Tasks, func(task api.Task) bool { return task.ID == before })
			if target < 0 {
				return fmt.Errorf("before task not found: %s", before)
			}
		}
		task := state.Tasks[index]
		state.Tasks = append(state.Tasks[:index], state.Tasks[index+1:]...)
		if index < target {
			target--
		}
		state.Tasks = slices.Insert(state.Tasks, target, task)
		for index := range state.Tasks {
			state.Tasks[index].Order = index
		}
		return nil
	})
}

func (s *Service) AttachWorkspaceToTask(taskID, workspaceID string) error {
	return s.Store.Update(func(state *api.State) error {
		if !slices.ContainsFunc(state.Tasks, func(task api.Task) bool { return task.ID == taskID }) {
			return fmt.Errorf("task not found: %s", taskID)
		}
		for index := range state.Workspaces {
			workspace := &state.Workspaces[index]
			if workspace.ID != workspaceID {
				continue
			}
			if workspace.TaskID == taskID {
				return nil
			}
			if workspace.TaskID != "" {
				return fmt.Errorf("workspace %s already belongs to task %s; detach it first", workspaceID, workspace.TaskID)
			}
			workspace.TaskID = taskID
			return nil
		}
		return fmt.Errorf("workspace not found: %s", workspaceID)
	})
}

func (s *Service) DetachWorkspaceFromTask(taskID, workspaceID string) error {
	return s.Store.Update(func(state *api.State) error {
		for index := range state.Workspaces {
			workspace := &state.Workspaces[index]
			if workspace.ID != workspaceID {
				continue
			}
			if workspace.TaskID == "" {
				return fmt.Errorf("workspace %s is not attached to a task", workspaceID)
			}
			if workspace.TaskID != taskID {
				return fmt.Errorf("workspace %s belongs to task %s, not %s", workspaceID, workspace.TaskID, taskID)
			}
			workspace.TaskID = ""
			return nil
		}
		return fmt.Errorf("workspace not found: %s", workspaceID)
	})
}

func normalizeTaskURL(rawURL string) (string, error) {
	rawURL = strings.TrimSpace(rawURL)
	if rawURL == "" {
		return "", nil
	}
	parsed, err := url.ParseRequestURI(rawURL)
	if err != nil || (!strings.EqualFold(parsed.Scheme, "http") && !strings.EqualFold(parsed.Scheme, "https")) || parsed.Host == "" {
		return "", errors.New("task URL must be an absolute HTTP(S) URL")
	}
	parsed.Scheme = strings.ToLower(parsed.Scheme)
	return parsed.String(), nil
}

func nextTaskOrder(tasks []api.Task) int {
	next := 0
	for _, task := range tasks {
		if task.Order >= next {
			next = task.Order + 1
		}
	}
	return next
}
