package server

import (
	"os"
	"os/exec"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/abcdlsj/warren/Headless/internal/agent"
	"github.com/abcdlsj/warren/Headless/internal/api"
)

// homesInOrder is the engine homes Warren knows of, per provider, in the order
// it learned them: the daemon's own first, then each directory a session
// reported. A session with no binding is matched against them in that order, so
// a directory already known answers at once instead of waiting for the next
// look at the process table.
type homesInOrder struct {
	mu    sync.Mutex
	order map[string][]string
}

// homesFor lists the candidate engine homes for one provider, ambient first,
// then every one learned, each once.
func (s *Service) homesFor(kind string) []string {
	out := []string{}
	add := func(home string) {
		home = strings.TrimSpace(home)
		if home == "" {
			return
		}
		for _, seen := range out {
			if seen == home {
				return
			}
		}
		out = append(out, home)
	}
	add(ambientHome(kind))
	s.agentHomes.mu.Lock()
	for _, home := range s.agentHomes.order[kind] {
		add(home)
	}
	s.agentHomes.mu.Unlock()
	return out
}

// maxLearnedHomes bounds how many directories Warren keeps per provider. The
// order is the order it learned them, so the oldest is the one to drop: a home
// nobody has used since is not worth a lookup on every session.
const maxLearnedHomes = 16

// rememberHome records a directory a session reported, after the ambient one,
// so later sessions try it too.
func (s *Service) rememberHome(kind, home string) {
	home = strings.TrimSpace(home)
	if kind == "" || home == "" {
		return
	}
	s.agentHomes.mu.Lock()
	defer s.agentHomes.mu.Unlock()
	if s.agentHomes.order == nil {
		s.agentHomes.order = map[string][]string{}
	}
	for _, seen := range s.agentHomes.order[kind] {
		if seen == home {
			return
		}
	}
	order := append(s.agentHomes.order[kind], home)
	if len(order) > maxLearnedHomes {
		order = order[len(order)-maxLearnedHomes:]
	}
	s.agentHomes.order[kind] = order
}

// claimable reports whether a transcript found by workspace and time may be
// bound: another running session in this state may already hold it, and two
// sessions sharing one conversation is worse than one that waits for its own
// hook. It is the same rule the fallback finder's result goes through, so a
// directory lookup cannot bind what a scan would have refused.
func (s *Service) claimable(state api.State, sessionID, transcriptPath string) bool {
	return transcriptPath != "" && !s.transcriptTakenByOtherInState(state, transcriptPath, sessionID)
}

// homeScanInterval bounds how often the known directories are searched for one
// session. Each search reads the conversation summaries of every directory, so
// it runs on its own cadence rather than on every reconcile tick.
const homeScanInterval = 2 * time.Second

// homeScanDue reports whether this session's directories may be searched now,
// and records that they were.
func (s *Service) homeScanDue(sessionID string) bool {
	now := time.Now()
	if value, ok := s.homeScans.Load(sessionID); ok {
		if at, ok := value.(time.Time); ok && now.Sub(at) < homeScanInterval {
			return false
		}
	}
	s.homeScans.Store(sessionID, now)
	return true
}

// ambientHome is the engine's home as the daemon itself sees it: what the
// engine's own variable or default points at.
func ambientHome(kind string) string {
	switch kind {
	case "claude":
		return agent.ClaudeConfigDir()
	case "codex":
		return agent.CodexHome()
	case "antigravity":
		return agent.AntigravityGeminiDir()
	case "qoder":
		return agent.QoderConfigDir()
	}
	return ""
}

// learnInterval bounds how often one session's processes are inspected. The
// engine writes its home into the environment before it starts, so a session
// that has not been started yet is worth asking again; a running one answers
// the same way every time.
const learnInterval = 5 * time.Second

// learnAgentHomes arms Warren's hook in every engine home the processes of a
// workspace report, and returns the ones it found.
//
// A launcher that gives each provider its own claude config_dir, codex_home or
// agy gemini_dir states it in that session's environment, which Warren cannot
// see from its own: the daemon's startup installation therefore covers the
// shared home only, and a session in a directory of its own would bind nothing
// until someone told Warren where to look. Reading the directory off the running
// engine closes that gap without Warren knowing which launcher put it there, and
// without reading the launcher's configuration.
func (s *Service) learnAgentHomes(workspacePath string) []string {
	workspacePath = strings.TrimSpace(workspacePath)
	if workspacePath == "" {
		return nil
	}
	if !s.takeLearnSlot(workspacePath) {
		return nil
	}
	var homes []string
	seen := map[string]bool{}
	// Only processes that name an engine are candidates, so the cwd of a
	// handful is checked instead of walking the workspace's tree, which is what
	// lsof would do on macOS.
	for _, pid := range engineProcesses() {
		cwd, err := processCwd(pid)
		if err != nil || cwd == "" || !samePath(cwd, workspacePath) {
			continue
		}
		kind, home, ok := engineHomeOf(pid)
		if !ok || seen[home] {
			continue
		}
		seen[home] = true
		if _, err := agent.EnsureBindHookForHome(kind, home); err != nil {
			s.logInfo("agent home hook install failed", "provider", kind, "home", home, "error", err.Error())
			continue
		}
		s.rememberHome(kind, home)
		s.logInfo("learned an agent home from the running engine", "provider", kind, "home", home)
		homes = append(homes, home)
	}
	return homes
}

// takeLearnSlot reports whether this workspace may be inspected now, and
// records that it was.
func (s *Service) takeLearnSlot(key string) bool {
	now := time.Now()
	if value, ok := s.learnedHomes.Load(key); ok {
		if at, ok := value.(time.Time); ok && now.Sub(at) < learnInterval {
			return false
		}
	}
	s.learnedHomes.Store(key, now)
	return true
}

// engineProcesses lists the pids whose command line names an agent engine, in
// one pass of the process table.
func engineProcesses() []int {
	output, err := exec.Command("ps", "-axo", "pid=,command=").Output()
	if err != nil {
		return nil
	}
	var pids []int
	for _, line := range strings.Split(string(output), "\n") {
		pidField, command, ok := strings.Cut(strings.TrimSpace(line), " ")
		if !ok || !namesEngine(command) {
			continue
		}
		if pid, err := strconv.Atoi(pidField); err == nil {
			pids = append(pids, pid)
		}
	}
	return pids
}

// namesEngine reports whether a command line runs one of the engines Warren
// binds, judged by the program it names.
func namesEngine(command string) bool {
	for _, field := range strings.Fields(command) {
		name := field
		if i := strings.LastIndexByte(name, '/'); i >= 0 {
			name = name[i+1:]
		}
		if _, ok := engineNames[name]; ok {
			return true
		}
	}
	return false
}

// engineNames are the programs whose environment can name an engine home.
var engineNames = map[string]string{
	"claude": "claude",
	"codex":  "codex",
	"agy":    "antigravity",
	"pi":     "pi",
	"qoder":  "qoder",
}

// engineHomeOf reads one process's environment and arguments for the engine
// home it runs in, and the engine's kind. It reports false for a process that
// is not an agent engine or says nothing about its home.
func engineHomeOf(pid int) (kind, home string, ok bool) {
	argv := processArgv(pid)
	if argv == "" {
		return "", "", false
	}
	for _, field := range strings.Fields(argv) {
		name := field
		if i := strings.LastIndexByte(name, '/'); i >= 0 {
			name = name[i+1:]
		}
		if k, found := engineNames[name]; found {
			kind = k
			break
		}
	}
	if kind == "" {
		return "", "", false
	}
	// agy states its directory as a flag, the other engines as an environment
	// variable.
	if home = geminiDirFlag(argv); home == "" {
		env := processEnv(pid)
		for _, key := range []string{agent.EnvAgentHome, "CLAUDE_CONFIG_DIR", "CODEX_HOME", "PI_CODING_AGENT_DIR", "QODER_CONFIG_DIR"} {
			if value := env[key]; value != "" {
				home = value
				break
			}
		}
	}
	if home == "" || !strings.HasPrefix(home, "/") {
		return "", "", false
	}
	return kind, home, true
}

// geminiDirFlag reads agy's --gemini_dir from a command line, in either the
// separate-argument or the --flag=value form.
func geminiDirFlag(argv string) string {
	fields := strings.Fields(argv)
	for i, field := range fields {
		if value, ok := strings.CutPrefix(field, "--gemini_dir="); ok {
			return value
		}
		if field == "--gemini_dir" && i+1 < len(fields) {
			return fields[i+1]
		}
	}
	return ""
}

// processArgv is a process's command line, with every argument.
func processArgv(pid int) string {
	output, err := exec.Command("ps", "-o", "command=", "-p", strconv.Itoa(pid)).Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(output))
}

// processEnv is a process's environment, where the platform lets another
// process of the same user read it.
//
// Linux hands it over through /proc. macOS does not: KERN_PROCARGS2 answers for
// another process with its path and arguments only, and `ps eww` shows the
// arguments it can read, not the environment, so a launcher's variable stays
// invisible there. On macOS a relocated home is therefore learned from the
// engine's own arguments (agy states one) or from the hook the engine runs,
// which inherits the variable — not before the first turn.
func processEnv(pid int) map[string]string {
	env := map[string]string{}
	if runtime.GOOS != "linux" {
		return env
	}
	data, err := os.ReadFile("/proc/" + strconv.Itoa(pid) + "/environ")
	if err != nil {
		return env
	}
	for _, entry := range strings.Split(string(data), "\x00") {
		if key, value, ok := strings.Cut(entry, "="); ok {
			env[key] = value
		}
	}
	return env
}
