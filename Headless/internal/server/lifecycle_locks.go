package server

import (
	"sync"
)

func (s *Service) projectLifecycleLock(projectID string) *sync.RWMutex {
	s.workspaceLifecycleMu.Lock()
	defer s.workspaceLifecycleMu.Unlock()
	if s.projectLifecycleLocks == nil {
		s.projectLifecycleLocks = make(map[string]*sync.RWMutex)
	}
	if lock := s.projectLifecycleLocks[projectID]; lock != nil {
		return lock
	}
	lock := &sync.RWMutex{}
	s.projectLifecycleLocks[projectID] = lock
	return lock
}

func (s *Service) lockWorkspaceForSession(workspaceID string) *sync.RWMutex {
	state := s.Store.Snapshot()
	for _, workspace := range state.Workspaces {
		if workspace.ID != workspaceID {
			continue
		}
		lock := s.projectLifecycleLock(workspace.ProjectID)
		lock.RLock()
		return lock
	}
	return nil
}

func (s *Service) lockWorkspaceLifecycle(workspaceID string) *sync.RWMutex {
	state := s.Store.Snapshot()
	for _, workspace := range state.Workspaces {
		if workspace.ID != workspaceID {
			continue
		}
		lock := s.projectLifecycleLock(workspace.ProjectID)
		lock.Lock()
		return lock
	}
	return nil
}

func (s *Service) lockGitMutation(workspaceID string) func() {
	s.gitMutationMu.Lock()
	if s.gitMutationLocks == nil {
		s.gitMutationLocks = make(map[string]*sync.Mutex)
	}
	lock := s.gitMutationLocks[workspaceID]
	if lock == nil {
		lock = &sync.Mutex{}
		s.gitMutationLocks[workspaceID] = lock
	}
	s.gitMutationMu.Unlock()
	lock.Lock()
	return lock.Unlock
}
