package runtime

import "context"

// RuntimeMetadata is the live OS-level foreground process snapshot for one
// session, rendered into roster snapshots when the runtime adapter supports
// it.
type RuntimeMetadata struct {
	Process     string
	CommandLine string
	Directory   string
}

// RuntimeMetadataProvider is implemented by runtime adapters that can report
// foreground process metadata for a session.
type RuntimeMetadataProvider interface {
	Metadata(context.Context, string) (RuntimeMetadata, error)
}
