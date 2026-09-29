package server

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/abcdlsj/warren/Headless/internal/acp"
	"github.com/abcdlsj/warren/Headless/internal/api"
)

const (
	// acpTerminalDefaultOutputLimit and acpTerminalMaxOutputLimit bound the
	// output the Host keeps per terminal for terminal/output.
	acpTerminalDefaultOutputLimit = 1 << 20
	acpTerminalMaxOutputLimit     = 4 << 20
	acpTerminalCreateTimeout      = 30 * time.Second
	acpTerminalTitleLimit         = 80
)

var acpEnvNamePattern = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*$`)

// acpTerminal is one terminal an agent created. It is backed by a visible
// terminal Session whose process is the command itself (RFC 0023 §6.6). The
// Host keeps the command's output as plain text, because the agent reads it
// after the command may have ended and its Session with it.
type acpTerminal struct {
	id          string
	sessionID   string
	runtimeName string
	limit       int

	mu        sync.Mutex
	output    []byte
	truncated bool
	stripper  vtStripper
	exit      *RuntimeExit
	done      chan struct{}
}

func (terminal *acpTerminal) append(data []byte) {
	terminal.mu.Lock()
	defer terminal.mu.Unlock()
	terminal.output = terminal.stripper.write(terminal.output, data)
	if len(terminal.output) > terminal.limit {
		// Keep the tail, cut at a character boundary.
		cut := len(terminal.output) - terminal.limit
		for cut < len(terminal.output) && !utf8.RuneStart(terminal.output[cut]) {
			cut++
		}
		terminal.output = append(terminal.output[:0], terminal.output[cut:]...)
		terminal.truncated = true
	}
}

func (terminal *acpTerminal) finish(exit RuntimeExit) {
	terminal.mu.Lock()
	if terminal.exit == nil {
		terminal.exit = &exit
		close(terminal.done)
	}
	terminal.mu.Unlock()
}

func (terminal *acpTerminal) snapshot() acp.TerminalOutputResponse {
	terminal.mu.Lock()
	defer terminal.mu.Unlock()
	response := acp.TerminalOutputResponse{Output: string(terminal.output), Truncated: terminal.truncated}
	if terminal.exit != nil {
		status := acpExitStatus(*terminal.exit)
		response.ExitStatus = &status
	}
	return response
}

func acpExitStatus(exit RuntimeExit) acp.TerminalExitStatus {
	var status acp.TerminalExitStatus
	if exit.Signal != "" {
		signal := exit.Signal
		status.Signal = &signal
	} else {
		code := exit.Code
		status.ExitCode = &code
	}
	return status
}

// handleTerminalRequest serves the client terminal methods. Each runs off the
// connection's read goroutine, because creating a Session and waiting for a
// command both take time.
func (handle *acpAgentHandle) handleTerminalRequest(request *acp.Request) {
	go func() {
		result, err := handle.terminalCall(request)
		if err != nil {
			_ = request.ReplyError(acp.CodeInvalidParams, err.Error())
			return
		}
		_ = request.Reply(result)
	}()
}

func (handle *acpAgentHandle) terminalCall(request *acp.Request) (any, error) {
	if request.Method == acp.MethodTerminalCreate {
		var params acp.CreateTerminalRequest
		if err := json.Unmarshal(request.Params, &params); err != nil {
			return nil, errors.New("invalid terminal/create request")
		}
		return handle.createTerminal(params)
	}
	var params acp.TerminalRequest
	if err := json.Unmarshal(request.Params, &params); err != nil {
		return nil, fmt.Errorf("invalid %s request", request.Method)
	}
	handle.mu.Lock()
	terminal := handle.terminals[params.TerminalID]
	handle.mu.Unlock()
	if terminal == nil {
		return nil, fmt.Errorf("unknown terminal %q", params.TerminalID)
	}
	switch request.Method {
	case acp.MethodTerminalOutput:
		return terminal.snapshot(), nil
	case acp.MethodTerminalWaitForExit:
		select {
		case <-terminal.done:
		case <-handle.connDone():
			return nil, acp.ErrClosed
		}
		terminal.mu.Lock()
		status := acpExitStatus(*terminal.exit)
		terminal.mu.Unlock()
		return status, nil
	case acp.MethodTerminalKill:
		if runtime := handle.service.processRuntime(); runtime != nil {
			ctx, cancel := context.WithTimeout(context.Background(), handle.service.commandTimeout())
			defer cancel()
			if err := runtime.TerminateProcess(ctx, terminal.runtimeName); err != nil {
				return nil, err
			}
		}
		return map[string]any{}, nil
	case acp.MethodTerminalRelease:
		handle.mu.Lock()
		delete(handle.terminals, terminal.id)
		handle.mu.Unlock()
		handle.releaseTerminals([]*acpTerminal{terminal})
		return map[string]any{}, nil
	}
	return nil, fmt.Errorf("method not supported by Warren: %s", request.Method)
}

// connDone is closed when the current agent connection ends, or already
// closed when there is none.
func (handle *acpAgentHandle) connDone() <-chan struct{} {
	handle.mu.Lock()
	conn := handle.conn
	handle.mu.Unlock()
	if conn == nil {
		closed := make(chan struct{})
		close(closed)
		return closed
	}
	return conn.Done()
}

func (s *Service) processRuntime() ProcessRuntime {
	processRuntime, _ := s.runtimeFor(api.Session{}).(ProcessRuntime)
	return processRuntime
}

func (handle *acpAgentHandle) createTerminal(params acp.CreateTerminalRequest) (acp.CreateTerminalResponse, error) {
	command := strings.TrimSpace(params.Command)
	if command == "" {
		return acp.CreateTerminalResponse{}, errors.New("terminal command is required")
	}
	directory := handle.cwd
	if cwd := strings.TrimSpace(params.CWD); cwd != "" {
		if !filepath.IsAbs(cwd) {
			return acp.CreateTerminalResponse{}, errors.New("terminal cwd must be an absolute path")
		}
		directory = filepath.Clean(cwd)
	}
	env := make([]string, 0, len(params.Env))
	for _, variable := range params.Env {
		if !acpEnvNamePattern.MatchString(variable.Name) || strings.ContainsRune(variable.Value, 0) {
			return acp.CreateTerminalResponse{}, fmt.Errorf("invalid environment variable %q", variable.Name)
		}
		env = append(env, variable.Name+"="+variable.Value)
	}
	limit := acpTerminalDefaultOutputLimit
	if params.OutputByteLimit != nil && *params.OutputByteLimit > 0 {
		limit = int(min(*params.OutputByteLimit, int64(acpTerminalMaxOutputLimit)))
	}
	processRuntime := handle.service.processRuntime()
	if processRuntime == nil {
		return acp.CreateTerminalResponse{}, errors.New("this Host cannot run agent terminals")
	}
	owner, ok := handle.service.Session(handle.sessionID)
	if !ok {
		return acp.CreateTerminalResponse{}, errors.New("the chat Session is gone")
	}
	shell, _, _ := handle.service.acpShell()
	display := acpTerminalDisplay(command, params.Args)
	ctx, cancel := context.WithTimeout(context.Background(), acpTerminalCreateTimeout)
	defer cancel()
	created, err := handle.service.createSessionWith(ctx, sessionCreateRequest{
		workspaceID: owner.WorkspaceID, groupID: owner.TerminalGroupID,
		command: display, kind: "shell", title: clipACPText(display, acpTerminalTitleLimit),
		processArgv: acpTerminalArgv(shell, command, params.Args), processDirectory: directory, processEnv: env,
	})
	if err != nil {
		return acp.CreateTerminalResponse{}, err
	}
	terminal := &acpTerminal{
		id:          "term-" + randomACPID(),
		sessionID:   created.ID,
		runtimeName: created.Runtime,
		limit:       limit,
		done:        make(chan struct{}),
	}
	handle.mu.Lock()
	if handle.closed {
		handle.mu.Unlock()
		handle.releaseTerminals([]*acpTerminal{terminal})
		return acp.CreateTerminalResponse{}, errors.New("agent handle is closed")
	}
	handle.terminals[terminal.id] = terminal
	handle.mu.Unlock()
	go handle.watchTerminal(processRuntime, terminal)
	return acp.CreateTerminalResponse{TerminalID: terminal.id}, nil
}

// watchTerminal copies the command's output until it ends, then records how
// it ended.
func (handle *acpAgentHandle) watchTerminal(processRuntime ProcessRuntime, terminal *acpTerminal) {
	ctx := context.Background()
	if reader, err := processRuntime.ProcessOutput(ctx, terminal.runtimeName); err == nil {
		buffer := make([]byte, 32*1024)
		for {
			n, readErr := reader.Read(buffer)
			if n > 0 {
				terminal.append(buffer[:n])
			}
			if readErr != nil {
				break
			}
		}
		_ = reader.Close()
	} else {
		handle.service.logWarn("acp terminal output unavailable", "session", handle.sessionID, "terminal", terminal.id, "error", err)
	}
	exit, err := processRuntime.WaitProcess(ctx, terminal.runtimeName)
	if err != nil {
		exit = RuntimeExit{Code: -1}
	}
	// A terminal Session ends with its process, like any other; the agent
	// still reads the output kept above until it releases the terminal.
	handle.service.markEnded(terminal.sessionID)
	terminal.finish(exit)
}

// releaseTerminals ends each terminal's command and removes its Session.
func (handle *acpAgentHandle) releaseTerminals(terminals []*acpTerminal) {
	for _, terminal := range terminals {
		ctx, cancel := context.WithTimeout(context.Background(), handle.service.commandTimeout())
		if err := handle.service.DeleteSession(ctx, terminal.sessionID); err != nil {
			handle.service.logWarn("acp terminal release failed", "session", handle.sessionID, "terminal", terminal.id, "error", err)
		}
		cancel()
		terminal.finish(RuntimeExit{Code: -1, Signal: "SIGKILL"})
	}
}

// takeTerminalsLocked removes every terminal from the handle for release.
func (handle *acpAgentHandle) takeTerminalsLocked() []*acpTerminal {
	terminals := make([]*acpTerminal, 0, len(handle.terminals))
	for _, terminal := range handle.terminals {
		terminals = append(terminals, terminal)
	}
	handle.terminals = make(map[string]*acpTerminal)
	return terminals
}

// terminalLinkLocked returns the Session behind a tool's terminal and its
// output so far.
func (handle *acpAgentHandle) terminalLinkLocked(terminalID string) (string, string, bool) {
	terminal := handle.terminals[terminalID]
	if terminal == nil {
		return "", "", false
	}
	terminal.mu.Lock()
	output := string(terminal.output)
	terminal.mu.Unlock()
	return terminal.sessionID, output, true
}

// acpTerminalArgv runs the command through the user's login shell, so it
// sees the environment a terminal Session sees. With arguments the command
// is exec'd directly; a bare command line is evaluated by /bin/sh, the shell
// agents write command lines for, whatever the user's login shell is. The
// quoting is valid in POSIX shells and in fish.
func acpTerminalArgv(shell, command string, args []string) []string {
	if shell == "" {
		if len(args) == 0 {
			return []string{"/bin/sh", "-c", command}
		}
		return append([]string{command}, args...)
	}
	script := "exec /bin/sh -c " + portableShellQuote(command)
	if len(args) > 0 {
		parts := make([]string, 0, len(args)+2)
		parts = append(parts, "exec", portableShellQuote(command))
		for _, arg := range args {
			parts = append(parts, portableShellQuote(arg))
		}
		script = strings.Join(parts, " ")
	}
	return []string{shell, "-l", "-c", script}
}

func acpTerminalDisplay(command string, args []string) string {
	if len(args) == 0 {
		return command
	}
	parts := []string{command}
	for _, arg := range args {
		switch {
		case arg != "" && !strings.ContainsAny(arg, " \t\n'\"\\$`;&|<>()*?#~"):
			parts = append(parts, arg)
		case !strings.Contains(arg, "'"):
			parts = append(parts, "'"+arg+"'")
		case !strings.ContainsAny(arg, "\"\\$`"):
			parts = append(parts, "\""+arg+"\"")
		default:
			parts = append(parts, portableShellQuote(arg))
		}
	}
	return strings.Join(parts, " ")
}

// portableShellQuote quotes value for POSIX shells and fish alike. Single
// quotes differ only in how they treat a backslash or a single quote, so
// those two characters are written inside double quotes instead.
func portableShellQuote(value string) string {
	if value == "" {
		return "''"
	}
	var builder strings.Builder
	run := strings.Builder{}
	flush := func() {
		if run.Len() > 0 {
			builder.WriteByte('\'')
			builder.WriteString(run.String())
			builder.WriteByte('\'')
			run.Reset()
		}
	}
	for _, character := range value {
		switch character {
		case '\'':
			flush()
			builder.WriteString(`"'"`)
		case '\\':
			flush()
			builder.WriteString(`"\\"`)
		default:
			run.WriteRune(character)
		}
	}
	flush()
	return builder.String()
}

// vtStripper turns terminal output into plain text across chunk boundaries:
// escape sequences are dropped, CRLF becomes LF, and a bare carriage return
// rewrites the current line the way a terminal shows it.
type vtStripper struct {
	state     int
	pendingCR bool
}

const (
	vtNormal = iota
	vtEscape
	vtEscapeIntermediate
	vtCSI
	vtString
	vtStringEscape
)

func (stripper *vtStripper) write(output, data []byte) []byte {
	for _, value := range data {
		switch stripper.state {
		case vtEscape:
			switch {
			case value == '[':
				stripper.state = vtCSI
			case value == ']' || value == 'P' || value == 'X' || value == '^' || value == '_':
				stripper.state = vtString
			case value >= 0x20 && value <= 0x2f:
				stripper.state = vtEscapeIntermediate
			default:
				stripper.state = vtNormal
			}
			continue
		case vtEscapeIntermediate:
			if value < 0x20 || value > 0x2f {
				stripper.state = vtNormal
			}
			continue
		case vtCSI:
			if value >= 0x40 && value <= 0x7e {
				stripper.state = vtNormal
			}
			continue
		case vtString:
			switch value {
			case 0x07:
				stripper.state = vtNormal
			case 0x1b:
				stripper.state = vtStringEscape
			}
			continue
		case vtStringEscape:
			if value == '\\' {
				stripper.state = vtNormal
			} else {
				stripper.state = vtString
			}
			continue
		}
		if stripper.pendingCR && value != '\r' {
			// A PTY writes a program's CRLF as CR CR LF, so only a CR followed
			// by text rewrites the line.
			stripper.pendingCR = false
			if value != '\n' {
				// A bare carriage return: the next text overwrites the line.
				output = output[:lastLineStart(output)]
			}
		}
		switch {
		case value == 0x1b:
			stripper.state = vtEscape
		case value == '\r':
			stripper.pendingCR = true
		case value == '\n':
			output = append(output, '\n')
		case value == '\t' || value >= 0x20 && value != 0x7f:
			output = append(output, value)
		}
	}
	return output
}

// lastLineStart finds where the last line of output begins.
func lastLineStart(output []byte) int {
	for index := len(output) - 1; index >= 0; index-- {
		if output[index] == '\n' {
			return index + 1
		}
	}
	return 0
}
