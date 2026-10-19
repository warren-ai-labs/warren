package runtime

import (
	"context"
	"time"
)

// RuntimeMetadata is the live OS-level foreground process snapshot for one
// session, rendered into roster snapshots when the runtime adapter supports
// it.
type RuntimeMetadata struct {
	Process     string
	CommandLine string
	Directory   string
	// Shell is the semantic prompt state the shell reported through OSC 133.
	// It is nil when the runtime observed no marker, and then every subfield is
	// unknown rather than false or empty.
	Shell *ShellMetadata
}

// ShellMetadata is the OSC 133 semantic prompt state of a shell session. It
// tells a consumer whether the shell is waiting for input or running a command,
// which command it is running or last ran, and how that command exited, without
// inferring any of it from the foreground process.
type ShellMetadata struct {
	// AtPrompt is true while the shell is at its prompt or in its input area.
	AtPrompt bool
	// RunningCommand is the command line the shell started executing. It is
	// empty when no command is running or the runtime could not capture the
	// text.
	RunningCommand string
	// LastCommand is the command line of the most recently completed command.
	// It is empty when the text was unavailable.
	LastCommand string
	// LastExitCode is the status the shell reported for the last command. It
	// is nil when no status has been reported.
	LastExitCode *int
	// LastExitAt is when the last command finished. It is nil until the shell
	// reports a command end.
	LastExitAt *time.Time
}

// RuntimeMetadataProvider is implemented by runtime adapters that can report
// foreground process metadata for a session.
type RuntimeMetadataProvider interface {
	Metadata(context.Context, string) (RuntimeMetadata, error)
}
