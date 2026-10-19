package runtime

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"

	"github.com/abcdlsj/ghostline"
)

// A live end-to-end check of the shell integration: a real interactive shell,
// loaded through Warren's generated scripts, must produce the OSC 133 prompt
// state ghostline exposes. The unit tests in this file check the scripts' text;
// this one checks that a shell actually runs them and that the exit status
// survives a failing command.
//
// It is skipped where the shell is not installed.
func TestShellIntegrationReportsOSC133FromALiveShell(t *testing.T) {
	shellPath, err := exec.LookPath("zsh")
	if err != nil {
		t.Skip("zsh is not installed")
	}
	integrationDir := t.TempDir()
	if err := WriteShellIntegration(integrationDir); err != nil {
		t.Fatalf("WriteShellIntegration: %v", err)
	}
	t.Setenv(ShellIntegrationDirEnv, integrationDir)

	env := ApplyShellIntegration(shellPath, []string{
		"HOME=" + t.TempDir(),
		"PATH=" + os.Getenv("PATH"),
		"TERM=xterm-256color",
	}).Env

	hub, err := ghostline.New(ghostline.Options{OutputDir: t.TempDir(), ProbeForeground: true})
	if err != nil {
		t.Fatalf("ghostline.New: %v", err)
	}
	t.Cleanup(func() { _ = hub.Close() })

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	session, err := hub.Start(ctx, ghostline.SessionOptions{
		Name: "warren-live-shell",
		Process: ghostline.ProcessSpec{
			Path:        shellPath,
			Args:        []string{"-il"},
			Directory:   t.TempDir(),
			Environment: env,
		},
	})
	if err != nil {
		t.Fatalf("hub.Start: %v", err)
	}
	t.Cleanup(func() { _ = session.Terminate(context.Background()) })

	waitForShell(t, session, "the first prompt", func(shell *ghostline.ShellMetadata) bool {
		return shell.AtPrompt
	})

	if err := session.WriteInput(ctx, []byte("echo hi\r")); err != nil {
		t.Fatalf("WriteInput echo: %v", err)
	}
	waitForShell(t, session, "a successful command", func(shell *ghostline.ShellMetadata) bool {
		return shell.LastCommand == "echo hi" && shell.LastExitCode != nil && *shell.LastExitCode == 0
	})

	if err := session.WriteInput(ctx, []byte("false\r")); err != nil {
		t.Fatalf("WriteInput false: %v", err)
	}
	completed := waitForShell(t, session, "a failing command", func(shell *ghostline.ShellMetadata) bool {
		return shell.LastCommand == "false" && shell.LastExitCode != nil && *shell.LastExitCode == 1
	})
	if completed.AtPrompt != true {
		t.Fatalf("AtPrompt = false after the failing command finished: %+v", completed)
	}
	if completed.LastExitAt == nil {
		t.Fatal("LastExitAt = nil after a command finished")
	}
}

// A shell with no integration must report no OSC 133 state at all, so a client
// can tell "never reported" from "at an empty prompt".
func TestShellMetadataIsUnknownWithoutMarkers(t *testing.T) {
	shPath, err := exec.LookPath("sh")
	if err != nil {
		t.Skip("sh is not installed")
	}
	hub, err := ghostline.New(ghostline.Options{OutputDir: t.TempDir()})
	if err != nil {
		t.Fatalf("ghostline.New: %v", err)
	}
	t.Cleanup(func() { _ = hub.Close() })
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	session, err := hub.Start(ctx, ghostline.SessionOptions{
		Name: "warren-plain-sh",
		Process: ghostline.ProcessSpec{
			Path:      shPath,
			Directory: t.TempDir(),
		},
	})
	if err != nil {
		t.Fatalf("hub.Start: %v", err)
	}
	t.Cleanup(func() { _ = session.Terminate(context.Background()) })
	if err := session.WriteInput(ctx, []byte("echo hi\r")); err != nil {
		t.Fatalf("WriteInput: %v", err)
	}
	// Give the shell a moment to run and print; a marker would have arrived by
	// then. The assertion is that none ever does.
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		metadata, err := session.Metadata(ctx)
		if err != nil {
			t.Fatalf("Metadata: %v", err)
		}
		if metadata.Shell != nil {
			t.Fatalf("a shell with no integration reported %+v", metadata.Shell)
		}
		time.Sleep(25 * time.Millisecond)
	}
}

func waitForShell(
	t *testing.T,
	session *ghostline.Session,
	what string,
	done func(*ghostline.ShellMetadata) bool,
) *ghostline.ShellMetadata {
	t.Helper()
	ctx := context.Background()
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		metadata, err := session.Metadata(ctx)
		if err != nil {
			t.Fatalf("Metadata while waiting for %s: %v", what, err)
		}
		if metadata.Shell != nil && done(metadata.Shell) {
			return metadata.Shell
		}
		time.Sleep(25 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %s", what)
	return nil
}

// A native prompt that already emits OSC 133 must be left alone. Emitting a
// second set would interleave with the first and corrupt the input region
// ghostline captures at 133;C, so the integration backs off entirely and the
// last command stays unknown.
func TestShellIntegrationBacksOffFromAUsersSemanticPrompt(t *testing.T) {
	shellPath, err := exec.LookPath("zsh")
	if err != nil {
		t.Skip("zsh is not installed")
	}
	integrationDir := t.TempDir()
	if err := WriteShellIntegration(integrationDir); err != nil {
		t.Fatalf("WriteShellIntegration: %v", err)
	}
	t.Setenv(ShellIntegrationDirEnv, integrationDir)

	home := t.TempDir()
	zshrc := "__user_prompt() { printf '\\033]133;A\\007' }\n" +
		"autoload -Uz add-zsh-hook\n" +
		"add-zsh-hook precmd __user_prompt\n"
	if err := os.WriteFile(filepath.Join(home, ".zshrc"), []byte(zshrc), 0o644); err != nil {
		t.Fatalf("write .zshrc: %v", err)
	}
	env := ApplyShellIntegration(shellPath, []string{
		"HOME=" + home,
		"PATH=" + os.Getenv("PATH"),
		"TERM=xterm-256color",
	}).Env

	hub, err := ghostline.New(ghostline.Options{OutputDir: t.TempDir(), ProbeForeground: true})
	if err != nil {
		t.Fatalf("ghostline.New: %v", err)
	}
	t.Cleanup(func() { _ = hub.Close() })
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	session, err := hub.Start(ctx, ghostline.SessionOptions{
		Name: "warren-foreign-prompt",
		Process: ghostline.ProcessSpec{
			Path:        shellPath,
			Args:        []string{"-il"},
			Directory:   t.TempDir(),
			Environment: env,
		},
	})
	if err != nil {
		t.Fatalf("hub.Start: %v", err)
	}
	t.Cleanup(func() { _ = session.Terminate(context.Background()) })

	if err := session.WriteInput(ctx, []byte("echo hi\r")); err != nil {
		t.Fatalf("WriteInput: %v", err)
	}
	// Give the shell time to run the command and draw the next prompt. If the
	// integration had emitted its own 133;C/133;D, the command would be known.
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		metadata, err := session.Metadata(ctx)
		if err != nil {
			t.Fatalf("Metadata: %v", err)
		}
		if metadata.Shell != nil && metadata.Shell.LastCommand != "" {
			t.Fatalf("warren emitted a duplicate marker set: %+v", metadata.Shell)
		}
		time.Sleep(25 * time.Millisecond)
	}
}
