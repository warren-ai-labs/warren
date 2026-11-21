package server

import (
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// processTerminateGrace is how long a process gets to exit after SIGTERM
// before worktree removal escalates to SIGKILL.
const processTerminateGrace = 3 * time.Second

// terminateProcessesUnder terminates every process whose current working
// directory is inside root. Agent shells (Codex, Claude, ...) started inside
// a worktree keep their cwd there; deleting the directory underneath them
// strands their exec session on a removed cwd. Warren-owned sessions are
// already stopped by removeWorkspaceRuntime, so this only targets external
// processes.
func terminateProcessesUnder(root string) (int, error) {
	pids, err := processesWithCwdUnder(root)
	if err != nil {
		return 0, err
	}
	terminated := 0
	for _, pid := range pids {
		if syscall.Kill(pid, syscall.SIGTERM) == nil {
			terminated++
		}
	}
	if terminated == 0 {
		return 0, nil
	}
	deadline := time.Now().Add(processTerminateGrace)
	survivors := pids
	for time.Now().Before(deadline) {
		remaining := survivors[:0]
		for _, pid := range survivors {
			if processAlive(pid) {
				remaining = append(remaining, pid)
			}
		}
		if len(remaining) == 0 {
			return terminated, nil
		}
		survivors = remaining
		time.Sleep(50 * time.Millisecond)
	}
	for _, pid := range survivors {
		_ = syscall.Kill(pid, syscall.SIGKILL)
	}
	return terminated, nil
}

func processAlive(pid int) bool {
	err := syscall.Kill(pid, 0)
	return err == nil || err == syscall.EPERM
}

// processesWithCwdUnder returns PIDs of processes whose current working
// directory is inside root. Only the cwd counts: an editor that merely holds
// a file open in the worktree is left alone.
func processesWithCwdUnder(root string) ([]int, error) {
	rootPath := resolvePath(root)
	if runtime.GOOS == "darwin" {
		if pids, ok := darwinProcessesWithCwdUnder(rootPath); ok {
			return pids, nil
		}
	}
	candidates, err := candidateProcesses(rootPath)
	if err != nil {
		return nil, err
	}
	pids := make([]int, 0, len(candidates))
	for _, pid := range candidates {
		if pid == os.Getpid() {
			continue
		}
		cwd, err := processCwd(pid)
		if err != nil || cwd == "" {
			continue
		}
		if pathWithin(rootPath, cwd) {
			pids = append(pids, pid)
		}
	}
	return pids, nil
}

// darwinProcessesWithCwdUnder resolves every process cwd in a single lsof
// invocation instead of walking the worktree with `+D` (which exits 1 when no
// process matches and used to fall back to one lsof subprocess per PID).
func darwinProcessesWithCwdUnder(rootPath string) ([]int, bool) {
	output, err := exec.Command("lsof", "-d", "cwd", "-Fpn").Output()
	if err != nil && len(output) == 0 {
		return nil, false
	}
	selfPID := os.Getpid()
	seen := make(map[int]struct{})
	var pids []int
	currentPID := 0
	for _, line := range strings.Split(string(output), "\n") {
		if len(line) < 2 {
			continue
		}
		switch line[0] {
		case 'p':
			if pid, parseErr := strconv.Atoi(line[1:]); parseErr == nil {
				currentPID = pid
			} else {
				currentPID = 0
			}
		case 'n':
			if currentPID <= 0 || currentPID == selfPID {
				continue
			}
			if _, exists := seen[currentPID]; exists {
				continue
			}
			if pathWithin(rootPath, line[1:]) {
				seen[currentPID] = struct{}{}
				pids = append(pids, currentPID)
			}
		}
	}
	return pids, true
}

// candidateProcesses prefers lsof's directory scan so the per-process cwd
// check only runs against a handful of PIDs; Linux scans /proc directly.
func candidateProcesses(root string) ([]int, error) {
	if runtime.GOOS == "linux" {
		entries, err := os.ReadDir("/proc")
		if err != nil {
			return nil, err
		}
		var pids []int
		for _, entry := range entries {
			if pid, err := strconv.Atoi(entry.Name()); err == nil {
				pids = append(pids, pid)
			}
		}
		return pids, nil
	}
	if output, err := exec.Command("lsof", "-t", "+D", root).Output(); err == nil {
		return parsePids(string(output)), nil
	}
	output, err := exec.Command("ps", "-axo", "pid=").Output()
	if err != nil {
		return nil, err
	}
	return parsePids(string(output)), nil
}

func parsePids(output string) []int {
	fields := strings.Fields(output)
	pids := make([]int, 0, len(fields))
	for _, field := range fields {
		if pid, err := strconv.Atoi(field); err == nil {
			pids = append(pids, pid)
		}
	}
	return pids
}

// processCwd resolves the current working directory of a process. It returns
// an empty string on platforms without a supported resolver so callers can
// skip those processes instead of failing the whole cleanup.
func processCwd(pid int) (string, error) {
	switch runtime.GOOS {
	case "linux":
		return os.Readlink("/proc/" + strconv.Itoa(pid) + "/cwd")
	case "darwin":
		output, err := exec.Command("lsof", "-a", "-p", strconv.Itoa(pid), "-d", "cwd", "-Fn").Output()
		if err != nil {
			return "", err
		}
		for _, line := range strings.Split(string(output), "\n") {
			if strings.HasPrefix(line, "n") {
				return strings.TrimPrefix(line, "n"), nil
			}
		}
		return "", nil
	default:
		return "", nil
	}
}

func pathWithin(root, path string) bool {
	path = resolvePath(path)
	return path == root || strings.HasPrefix(path, root+string(os.PathSeparator))
}

func resolvePath(path string) string {
	absolute, err := filepath.Abs(path)
	if err != nil {
		absolute = path
	}
	if resolved, err := filepath.EvalSymlinks(absolute); err == nil {
		absolute = resolved
	}
	return filepath.Clean(absolute)
}
