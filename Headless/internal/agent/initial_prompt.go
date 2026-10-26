package agent

import "strings"

// AppendInitialPrompt adds a provider CLI's startup prompt to an executable
// command that may already contain arbitrary arguments, using that
// provider's convention: a positional argument for Codex, Claude, Pi, and
// Qoder, --prompt for OpenCode, and -i for Antigravity. The command is
// evaluated by a POSIX shell inside the terminal runtime, so the prompt is
// quoted as one shell word instead of being interpolated literally.
func AppendInitialPrompt(command, provider, prompt string) string {
	command = strings.TrimSpace(command)
	switch strings.ToLower(strings.TrimSpace(provider)) {
	case "opencode":
		return command + " --prompt " + ShellQuote(prompt)
	case "antigravity":
		return command + " -i " + ShellQuote(prompt)
	}
	return command + " " + ShellQuote(prompt)
}

// ShellQuote quotes value as one POSIX shell word.
func ShellQuote(value string) string {
	return "'" + strings.ReplaceAll(value, "'", "'\"'\"'") + "'"
}
