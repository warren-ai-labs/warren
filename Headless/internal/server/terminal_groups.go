package server

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"strings"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/api"
	"github.com/abcdlsj/warren/Headless/internal/store"
)

func (s *Service) CreateTerminalGroup(name, home string) (api.TerminalGroup, error) {
	name = strings.TrimSpace(name)
	if name == "" {
		name = "Terminal Group"
	}
	home, err := normalizeTerminalGroupHome(home)
	if err != nil {
		return api.TerminalGroup{}, err
	}
	group := api.TerminalGroup{
		ID:        store.NewID(),
		Name:      name,
		Home:      home,
		CreatedAt: time.Now().UTC(),
	}
	err = s.Store.Update(func(state *api.State) error {
		group.Order = len(state.TerminalGroups)
		state.TerminalGroups = append(state.TerminalGroups, group)
		return nil
	})
	return group, err
}

func (s *Service) RenameTerminalGroup(id, name string) error {
	name = strings.TrimSpace(name)
	if name == "" {
		return errors.New("terminal group name cannot be empty")
	}
	return s.Store.Update(func(state *api.State) error {
		for index := range state.TerminalGroups {
			if state.TerminalGroups[index].ID == id {
				state.TerminalGroups[index].Name = name
				return nil
			}
		}
		return fmt.Errorf("terminal group not found: %s", id)
	})
}

func (s *Service) SetTerminalGroupHome(id, home string) error {
	home, err := normalizeTerminalGroupHome(home)
	if err != nil {
		return err
	}
	return s.Store.Update(func(state *api.State) error {
		for index := range state.TerminalGroups {
			if state.TerminalGroups[index].ID == id {
				state.TerminalGroups[index].Home = home
				return nil
			}
		}
		return fmt.Errorf("terminal group not found: %s", id)
	})
}

func (s *Service) MoveTerminalGroup(id, before string) error {
	return s.Store.Update(func(state *api.State) error {
		sortTerminalGroups(state.TerminalGroups)
		index := -1
		for i := range state.TerminalGroups {
			if state.TerminalGroups[i].ID == id {
				index = i
				break
			}
		}
		if index < 0 {
			return fmt.Errorf("terminal group not found: %s", id)
		}
		target := len(state.TerminalGroups)
		if before != "" {
			found := false
			for i := range state.TerminalGroups {
				if state.TerminalGroups[i].ID == before {
					target = i
					found = true
					break
				}
			}
			if !found {
				return fmt.Errorf("before terminal group not found: %s", before)
			}
		}
		group := state.TerminalGroups[index]
		state.TerminalGroups = append(state.TerminalGroups[:index], state.TerminalGroups[index+1:]...)
		if index < target {
			target--
		}
		state.TerminalGroups = slices.Insert(state.TerminalGroups, target, group)
		for i := range state.TerminalGroups {
			state.TerminalGroups[i].Order = i
		}
		return nil
	})
}

func (s *Service) RemoveTerminalGroup(ctx context.Context, id string, force bool) error {
	s.terminalGroupLifecycleMu.Lock()
	defer s.terminalGroupLifecycleMu.Unlock()

	state := s.Store.Snapshot()
	found := false
	for _, group := range state.TerminalGroups {
		if group.ID == id {
			found = true
			break
		}
	}
	if !found {
		return fmt.Errorf("terminal group not found: %s", id)
	}
	for _, session := range state.Sessions {
		if session.TerminalGroupID == id && !force {
			return errors.New("terminal group has sessions; use --force")
		}
	}
	if force {
		s.removeTerminalGroupRuntimes(ctx, state, id)
	}
	return s.Store.Update(func(value *api.State) error {
		value.TerminalGroups = filter(value.TerminalGroups, func(group api.TerminalGroup) bool {
			return group.ID != id
		})
		value.Sessions = filter(value.Sessions, func(session api.Session) bool {
			return session.TerminalGroupID != id
		})
		for index := range value.TerminalGroups {
			value.TerminalGroups[index].Order = index
		}
		// The owner is gone from this snapshot, so its arrangements go with it.
		reconcilePaneGroups(value)
		return nil
	})
}

func (s *Service) ensureTerminalGroup() (api.TerminalGroup, error) {
	state := s.Store.Snapshot()
	if len(state.TerminalGroups) > 0 {
		sortTerminalGroups(state.TerminalGroups)
		return state.TerminalGroups[0], nil
	}
	var group api.TerminalGroup
	err := s.Store.Update(func(state *api.State) error {
		if len(state.TerminalGroups) == 0 {
			group = api.TerminalGroup{
				ID:        store.NewID(),
				Name:      "Inbox",
				Order:     0,
				CreatedAt: time.Now().UTC(),
			}
			state.TerminalGroups = append(state.TerminalGroups, group)
		} else {
			sortTerminalGroups(state.TerminalGroups)
			group = state.TerminalGroups[0]
		}
		return nil
	})
	return group, err
}
