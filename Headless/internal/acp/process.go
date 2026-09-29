package acp

import (
	"bufio"
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"
	"sync"
	"syscall"
	"time"
)

// stderrTailBytes bounds the agent stderr kept for diagnostics.
const stderrTailBytes = 64 << 10

// terminateGrace is how long a closed agent gets to exit after SIGTERM.
const terminateGrace = 3 * time.Second

// interactiveSentinelTimeout bounds how long an interactive login shell may
// take to reach exec before the launcher falls back to a non-interactive one.
const interactiveSentinelTimeout = 10 * time.Second

// sentinelTimeout bounds how long the fallback login shell may take.
const sentinelTimeout = 30 * time.Second

// errNoSentinel means the shell ended or stalled before exec'ing the agent.
var errNoSentinel = errors.New("agent shell did not start the agent")

// LaunchOptions describe one agent process.
type LaunchOptions struct {
	// Shell is the login shell used to launch Command. Empty runs Argv
	// directly without a shell, which tests use.
	Shell string
	// ShellArgs precede "-c"; normally the login and interactive flags, so the
	// agent sees the environment a terminal Session sees.
	ShellArgs []string
	// FallbackShellArgs are tried when the first shell never reaches exec, for
	// example because an interactive startup file execs another shell.
	FallbackShellArgs []string
	// Command is the ACP server command line in shell syntax.
	Command string
	// Argv runs a program directly when Shell is empty.
	Argv []string
	Dir  string
	Env  []string
}

// Process is a running agent with its stdio.
type Process struct {
	cmd    *exec.Cmd
	stdin  io.WriteCloser
	stdout io.Reader

	stderr *tailBuffer

	waitOnce sync.Once
	waitErr  error
	exited   chan struct{}
}

// Start launches the agent.
//
// Through a shell, two things keep the user's startup files from interfering
// with the JSON-RPC stream. The shell's own stdin is /dev/null and the agent's
// stdin arrives on fd 3, moved into place by the exec, so a startup file that
// reads input (or execs another interactive shell) cannot consume protocol
// messages. And stdout is handed to the caller only after a per-launch
// sentinel line, so anything a startup file prints is discarded.
func Start(ctx context.Context, options LaunchOptions) (*Process, error) {
	if options.Shell == "" {
		if len(options.Argv) == 0 {
			return nil, errors.New("acp argv is required")
		}
		return startDirect(options)
	}
	if strings.TrimSpace(options.Command) == "" {
		return nil, errors.New("acp command is required")
	}
	process, err := startInShell(ctx, options, options.ShellArgs, interactiveSentinelTimeout)
	if err != nil && errors.Is(err, errNoSentinel) && len(options.FallbackShellArgs) > 0 {
		process, err = startInShell(ctx, options, options.FallbackShellArgs, sentinelTimeout)
	}
	return process, err
}

func newProcess(cmd *exec.Cmd) *Process {
	return &Process{cmd: cmd, stderr: &tailBuffer{limit: stderrTailBytes}, exited: make(chan struct{})}
}

func (p *Process) start() error {
	p.cmd.Stderr = p.stderr
	if err := p.cmd.Start(); err != nil {
		return err
	}
	go func() {
		p.waitErr = p.cmd.Wait()
		close(p.exited)
	}()
	return nil
}

func prepare(cmd *exec.Cmd, options LaunchOptions) {
	cmd.Dir = options.Dir
	if options.Env != nil {
		cmd.Env = options.Env
	}
	// A new session detaches the agent from any controlling terminal (an
	// interactive login shell in a background process group of a terminal
	// would stop on SIGTTOU), and makes it a process group leader so Close
	// ends the adapter and everything it spawned together.
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
}

func startDirect(options LaunchOptions) (*Process, error) {
	cmd := exec.Command(options.Argv[0], options.Argv[1:]...)
	prepare(cmd, options)
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	process := newProcess(cmd)
	process.stdin, process.stdout = stdin, stdout
	if err := process.start(); err != nil {
		return nil, err
	}
	return process, nil
}

func startInShell(ctx context.Context, options LaunchOptions, shellArgs []string, timeout time.Duration) (*Process, error) {
	token := make([]byte, 12)
	if _, err := rand.Read(token); err != nil {
		return nil, err
	}
	sentinel := "__WARREN_ACP_" + hex.EncodeToString(token) + "__"
	script := fmt.Sprintf("printf '\\n%%s\\n' %s; exec %s <&3 3<&-", sentinel, options.Command)
	args := append(append([]string(nil), shellArgs...), "-c", script)
	cmd := exec.Command(options.Shell, args...)
	prepare(cmd, options)
	stdinReader, stdinWriter, err := os.Pipe()
	if err != nil {
		return nil, err
	}
	cmd.ExtraFiles = []*os.File{stdinReader}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		stdinReader.Close()
		stdinWriter.Close()
		return nil, err
	}
	process := newProcess(cmd)
	process.stdin = stdinWriter
	startErr := process.start()
	stdinReader.Close()
	if startErr != nil {
		stdinWriter.Close()
		return nil, startErr
	}
	reader := bufio.NewReaderSize(stdout, 64*1024)
	found := make(chan error, 1)
	go func() {
		for {
			line, err := reader.ReadString('\n')
			if strings.TrimSpace(line) == sentinel {
				found <- nil
				return
			}
			if err != nil {
				found <- err
				return
			}
		}
	}()
	timer := time.NewTimer(timeout)
	defer timer.Stop()
	select {
	case err := <-found:
		if err != nil {
			process.Close()
			return nil, fmt.Errorf("%w: the shell exited first (%s)", errNoSentinel, process.describeExit(err))
		}
	case <-timer.C:
		process.Close()
		return nil, fmt.Errorf("%w within %s", errNoSentinel, timeout)
	case <-ctx.Done():
		process.Close()
		return nil, ctx.Err()
	}
	process.stdout = reader
	return process, nil
}

// Stdin is the agent's standard input.
func (p *Process) Stdin() io.Writer { return p.stdin }

// Stdout is the agent's standard output, positioned after the sentinel.
func (p *Process) Stdout() io.Reader { return p.stdout }

// Exited is closed when the process has exited.
func (p *Process) Exited() <-chan struct{} { return p.exited }

// ExitError is the process's wait result, valid after Exited is closed.
func (p *Process) ExitError() error {
	select {
	case <-p.exited:
		return p.waitErr
	default:
		return nil
	}
}

// PID is the process ID.
func (p *Process) PID() int {
	if p.cmd.Process == nil {
		return 0
	}
	return p.cmd.Process.Pid
}

// StderrTail returns the last bytes the agent wrote to stderr.
func (p *Process) StderrTail() string { return p.stderr.String() }

// Close ends the process group: close stdin, SIGTERM, then SIGKILL after a
// grace period. It is safe to call more than once.
func (p *Process) Close() {
	p.waitOnce.Do(func() {
		_ = p.stdin.Close()
		pid := p.PID()
		if pid <= 0 {
			return
		}
		// Most agents exit on stdin EOF; give them a moment before signaling.
		select {
		case <-p.exited:
			return
		case <-time.After(time.Second):
		}
		_ = syscall.Kill(-pid, syscall.SIGTERM)
		select {
		case <-p.exited:
		case <-time.After(terminateGrace):
			_ = syscall.Kill(-pid, syscall.SIGKILL)
			<-p.exited
		}
	})
}

func (p *Process) describeExit(err error) string {
	select {
	case <-p.exited:
		err = p.waitErr
	case <-time.After(500 * time.Millisecond):
	}
	message := "exited"
	if err != nil && !errors.Is(err, io.EOF) {
		message = err.Error()
	}
	if tail := strings.TrimSpace(p.StderrTail()); tail != "" {
		message += ": " + lastLines(tail, 5)
	}
	return message
}

// DescribeExit summarizes an exited process for an error event.
func (p *Process) DescribeExit() string { return p.describeExit(nil) }

func lastLines(value string, count int) string {
	lines := strings.Split(value, "\n")
	if len(lines) > count {
		lines = lines[len(lines)-count:]
	}
	return clip(strings.Join(lines, "\n"), 2048)
}

// tailBuffer keeps the last limit bytes written.
type tailBuffer struct {
	mu    sync.Mutex
	limit int
	data  []byte
}

func (b *tailBuffer) Write(value []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.data = append(b.data, value...)
	if len(b.data) > b.limit {
		b.data = append([]byte(nil), b.data[len(b.data)-b.limit:]...)
	}
	return len(value), nil
}

func (b *tailBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return string(bytes.ToValidUTF8(b.data, nil))
}

// LookPathInShell reports whether executable resolves on the PATH the login
// shell builds, trying the same shell flags the launcher tries. A marker on
// stdout proves the check itself ran: an interactive startup file that execs
// another shell also exits successfully without running it.
func LookPathInShell(ctx context.Context, shell string, shellArgs, fallbackShellArgs []string, dir string, env []string, executable string) bool {
	if shell == "" {
		_, err := exec.LookPath(executable)
		return err == nil
	}
	const marker = "__WARREN_ACP_FOUND__"
	check := func(args []string, timeout time.Duration) (found, ran bool) {
		checkContext, cancel := context.WithTimeout(ctx, timeout)
		defer cancel()
		// Written in the subset fish, zsh, bash, and sh share.
		script := "printf '" + marker + "'; command -v " + shellQuote(executable) + " >/dev/null 2>&1 && printf '" + marker + "found'"
		cmd := exec.CommandContext(checkContext, shell, append(append([]string(nil), args...), "-c", script)...)
		cmd.Dir = dir
		if env != nil {
			cmd.Env = env
		}
		cmd.Stderr = io.Discard
		cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
		output, _ := cmd.Output()
		text := string(output)
		if !strings.Contains(text, marker) {
			return false, false
		}
		return strings.Contains(text, marker+"found"), true
	}
	if found, ran := check(shellArgs, interactiveSentinelTimeout); ran {
		return found
	}
	if len(fallbackShellArgs) == 0 {
		return false
	}
	found, _ := check(fallbackShellArgs, sentinelTimeout)
	return found
}

func shellQuote(value string) string {
	return "'" + strings.ReplaceAll(value, "'", `'\''`) + "'"
}
