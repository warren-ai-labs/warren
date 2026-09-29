package main

import (
	"fmt"
)

func relayUsageText() string {
	return `Usage:
  warren relay connect [SETTINGS_URL] [--url RELAY_URL --key ENROLLMENT_KEY]
  warren relay join [SETTINGS_URL] [--url RELAY_URL --key ENROLLMENT_KEY]
  warren relay share [--qr [PATH]] [--open]

The Relay administrator creates a short-lived enrollment key. 'relay connect'
passes the Relay URL and key to the selected local Host daemon; the daemon
allocates its Host identity and keeps the long-lived Host credential locally.
It also accepts a canonical warren://settings link containing relayUrl and
enrollmentKey. The Relay administrator token never enters this CLI.

Automation may pass --url and --key instead of SETTINGS_URL. The key is a
short-lived, bounded-use bootstrap credential and is never written to the
Warren endpoint configuration.

'relay share' asks the selected local Host for one opaque, reusable pairing
link. It is the normal Desktop-to-iPhone flow; --qr writes a protected PNG
(warren-relay-pairing.png by default), and --open opens the link in a browser.

Relay administration, Host provisioning, revocation, routes, and the pairing
code exchange are service-owned APIs. They are not Warren client concepts.
`
}

func usageText() string {
	return `Warren CLI

Usage:
  warren [--endpoint NAME | --server URL --token TOKEN] [--json] [-q] <command>

Commands:
  relay connect|share
  agent create|list|current|send|read|wait|attach|remove|rename|pin|move
  endpoint list|add|use|remove|current
  display list|add|remove|move|set|reset
  task list|create|remove|rename|pin|move|attach|detach|workspace
  project list|add|remove|rename|pin|move
  workspace list|create|remove|rename|pin|move  (alias: worktree)
  terminal-group list|create|remove|rename|home|move  (alias: group)
  pane list|create|split|close|rename|move|remove
  session list|current|panes|create|remove|rename|pin|move|send|read|undo
  browser list|create|get|action|close  drive an embedded Chromium
  ssh list|TARGET                   list SSH aliases or start a tunnel
  headless [FLAGS]                  run the installed daemon

Global flags:
  --json                            machine-readable JSON output
  -q, --quiet                       only print resource IDs/names
  --endpoint NAME                   endpoint name from the local config (required when multiple are configured)
  --server URL --token TOKEN        connect directly to a server
  --config PATH                     config file (default ~/.warren/config.json)

Run 'warren <command> --help' for command-specific help.

List filtering & display:
  List commands show up to 10 rows by default; long fields are truncated for compact display.
  • Narrow results: --search TEXT, --current, --status running|ended, or pass context IDs.
  • Full / raw:     --all (display all rows), --json (complete un-truncated JSON).
  • Quiet / IDs:    -q, --quiet (print IDs only; minimal output for scripts and AI agents).

Best practices:
  warren session list --current                # active workspace sessions only
  warren session list --search <term>          # quickly locate sessions by keyword
  warren session list -q --status running      # pipe running session IDs to shell scripts
  warren workspace list -q                     # feed workspace IDs to agents with minimal tokens
  warren session list --json | jq .            # inspect complete, raw details

Examples:
  warren agent create WORKSPACE_ID --provider codex --prompt "Run the tests"
  warren agent create WORKSPACE_ID --provider codex --command codex-alias --prompt "Fix the bug"
  warren agent list
  warren agent read AGENT_ID --text-only
  warren agent wait AGENT_ID --timeout 30m
  warren endpoint add vps --url http://127.0.0.1:8789 --token TOKEN --use
  warren display set local vps
  warren project add /srv/my-repo
  warren project move PROJECT_ID --before OTHER_PROJECT_ID
  warren workspace create PROJECT_ID --branch release/feature
    --path is optional; omit it to create under ~/.warren/worktrees/
    (pass --path only when the worktree must live somewhere specific)
  warren workspace remove WORKSPACE_ID --force
    --keep-worktree keeps the local Git worktree on disk
  warren workspace move WORKSPACE_ID --before OTHER_WORKSPACE_ID
  warren task workspace create TASK_ID PROJECT_ID --branch release/feature
  warren terminal-group create --name NAME [--home PATH]
  warren terminal-group move GROUP_ID --before OTHER_GROUP_ID
  warren terminal-group remove GROUP_ID --force
  warren session create WORKSPACE_ID --kind shell --command bash
  warren session create --group GROUP_ID
  warren session create
  warren session current
  warren session panes
  warren session move SESSION_ID --workspace WORKSPACE_ID [--confirm] [--expected-workspace ID] [--expected-agent-session ID]
  warren session move --current --workspace WORKSPACE_ID [--dry-run]
  warren session move SESSION_ID --group GROUP_ID [--confirm] [--dry-run]
  warren session undo OPERATION_ID
`
}

func displayUsageText() string {
	return `Usage:
  warren display list
  warren display add NAME [--before NAME]
  warren display remove NAME
  warren display move NAME --before NAME
  warren display set NAME [NAME ...]
  warren display reset

The display set is local Desktop configuration. It stores endpoint names and
optional display labels; URLs, tokens, SSH metadata, and Relay credentials
remain in the endpoint catalog. A missing display section keeps the legacy
single-current behavior.
The current endpoint is independent from the explicit set, so switching it
does not change sidebar membership. An explicit set cannot be empty. Use
--json for an object containing endpoints, current, version, and custom names;
use --quiet to print one endpoint alias per line.
`
}

func agentUsageText() string {
	return `Usage:
  warren agent create [WORKSPACE_ID] --provider codex|claude|opencode|pi|qoder|antigravity [--agent-handler tui|cli|acp] [--command CMD] [--prompt TEXT | --no-prompt]
  warren agent list [--all | --ended] [WORKSPACE_ID] [--workspace ID] [--project ID] [--provider PROVIDER] [--status STATUS] [--activity ACTIVITY] [--search TEXT] [--current] [--pinned] [--limit N] [-q]
  warren agent current
  warren agent send AGENT_ID [TEXT...] [--current] [--wait] [--timeout DURATION]
  warren agent read AGENT_ID [--current] [--recent N | --all] [--tools] [--tool-output] [--include TYPE,...] [--filter TYPE,...] [--chars N | --full] [--text-only]
  warren agent wait AGENT_ID [--timeout DURATION] [--current]
  warren agent attach AGENT_ID [--current]
  warren agent remove AGENT_ID [--force] [--current] [--dry-run]
  warren agent rename AGENT_ID --title TITLE [--current]
  warren agent pin AGENT_ID --pinned BOOL [--current]
  warren agent move AGENT_ID --workspace WORKSPACE_ID [--confirm] [--dry-run]

Run 'warren agent <command> --help' for command-specific help.
`
}

func agentCreateUsageText() string {
	return `Usage:
  warren agent create [WORKSPACE_ID]
      --provider codex|claude|opencode|pi|qoder|antigravity
      [--agent-handler tui|cli|acp]
      [--command CMD]
      [--prompt TEXT | --no-prompt]
      [--group GROUP_ID] [--title TITLE] [--wait] [--timeout DURATION]

Create an Agent backed by a Codex, Claude, OpenCode, Pi, Qoder, or Antigravity session. --prompt is
passed with the provider's startup syntax (positional for Codex/Claude/Pi/Qoder,
--prompt for OpenCode, and -i for Antigravity). Use --no-prompt to create an idle Agent explicitly.
--command defaults to the provider executable and may name an alias or wrapper
command with options, but must not include a positional prompt or prompt option.

--agent-handler acp (codex, claude, opencode) drives the Agent over the Agent
Client Protocol instead of a terminal: the Session has no PTY, and --prompt is
sent as the first turn. --command then names the ACP server and defaults to
claude-agent-acp, codex-acp, or "opencode acp". Read and continue it with
'warren agent read' and 'warren agent send'.
`
}

func agentListUsageText() string {
	return `Usage:
  warren agent list [--all | --ended] [WORKSPACE_ID] [--workspace ID] [--project ID] [--provider PROVIDER] [--status STATUS] [--activity ACTIVITY] [--search TEXT] [--current] [--pinned] [--limit N] [-q]

Lists are limited to 10 Agents by default with long fields truncated.
Use --search TEXT or filters to narrow down, --all for the complete list, and -q for IDs only.
`
}

func agentCurrentUsageText() string {
	return `Usage:
  warren agent current

Read the Agent bound to WARREN_SESSION_ID.
`
}

func agentSendUsageText() string {
	return `Usage:
  warren agent send AGENT_ID [TEXT...] [--current] [--wait] [--timeout DURATION]

If TEXT is omitted, Warren reads the prompt from stdin.
`
}

func agentReadUsageText() string {
	return `Usage:
  warren agent read AGENT_ID [--current]
      [--recent N | --all]
      [--tools] [--tool-output]
      [--include TYPE,...] [--filter TYPE,...]
      [--chars N | --full] [--text-only]

Read the normalized transcript for a Warren Agent. By default, only the
newest 20 user, assistant, and error activities are returned and text fields
are limited to 2000 characters. --tools adds tool-call summaries;
--tool-output additionally includes bounded tool results. --all returns all
matching activities (up to 100000). --text-only prints user and assistant
text. --full returns the complete canonical event history and cannot be combined
with projection flags.
`
}

func agentWaitUsageText() string {
	return `Usage:
  warren agent wait AGENT_ID [--timeout DURATION] [--current]

Wait for an active Agent turn to finish. Exits 0 on turn completion, 1 on turn error.
`
}

func agentAttachUsageText() string {
	return `Usage:
  warren agent attach AGENT_ID [--current]

Connect stdout and stdin to the live interactive PTY for an agent session.
`
}

func agentActionUsageText(action string) string {
	switch action {
	case "remove", "delete":
		return "Usage:\n  warren agent remove AGENT_ID [--force] [--current] [--dry-run]\n"
	case "rename":
		return "Usage:\n  warren agent rename AGENT_ID --title TITLE [--current]\n"
	case "pin":
		return "Usage:\n  warren agent pin AGENT_ID --pinned BOOL [--current]\n"
	case "move":
		return "Usage:\n  warren agent move AGENT_ID --workspace WORKSPACE_ID [--confirm] [--dry-run]\n"
	default:
		return "Usage:\n  warren agent remove|rename|pin|move AGENT_ID ...\n"
	}
}

func resourceUsageText(commandName string) string {
	aliasNote := ""
	if commandName == "worktree" {
		aliasNote = "\nworktree is an alias for workspace."
	}
	if commandName == "group" {
		aliasNote = "\ngroup is an alias for terminal-group."
	}
	switch canonicalResource(commandName) {
	case "task":
		return fmt.Sprintf(`Usage:
  warren %s list [--all] [--source SOURCE] [--has-workspaces | --unattached] [--search TEXT] [--pinned] [--limit N] [-q]
  warren %s create --name NAME [--source SOURCE --external-id ID] [--url URL]
  warren %s remove TASK_ID
  warren %s rename TASK_ID --name NAME
  warren %s pin TASK_ID --pinned BOOL
  warren %s move TASK_ID [--before OTHER_TASK_ID]
  warren %s attach TASK_ID WORKSPACE_ID
  warren %s detach TASK_ID WORKSPACE_ID
  warren %s workspace list TASK_ID [--available] [--all] [--limit N] [-q]
  warren %s workspace attach TASK_ID WORKSPACE_ID
  warren %s workspace detach TASK_ID WORKSPACE_ID
  warren %s workspace create TASK_ID PROJECT_ID --branch BRANCH [--name NAME] [--path PATH]
`, commandName, commandName, commandName, commandName, commandName, commandName, commandName, commandName, commandName, commandName, commandName, commandName)
	case "project":
		return fmt.Sprintf(`Usage:
  warren %s list [--all] [--search TEXT] [--has-workspaces] [--pinned] [--limit N] [-q]
  warren %s add PATH [--name NAME] [--auto-import-worktrees]
  warren %s remove PROJECT_ID [--force]
  warren %s rename PROJECT_ID --name NAME
  warren %s pin PROJECT_ID --pinned BOOL
  warren %s move PROJECT_ID [--before OTHER_PROJECT_ID]
`, commandName, commandName, commandName, commandName, commandName, commandName)
	case "workspace":
		return fmt.Sprintf(`Usage:
  warren %s list [--all] [PROJECT_ID] [--project ID] [--task ID] [--branch BRANCH] [--merged | --unmerged] [--unattached] [--has-sessions] [--search TEXT] [--pinned] [--limit N] [-q]
  warren %s create PROJECT_ID --branch BRANCH [--name NAME] [--path PATH]
  warren %s remove WORKSPACE_ID [--force] [--keep-worktree]
  warren %s rename WORKSPACE_ID --name NAME
  warren %s pin WORKSPACE_ID --pinned BOOL
  warren %s move WORKSPACE_ID [--before OTHER_WORKSPACE_ID]
%s`, commandName, commandName, commandName, commandName, commandName, commandName, aliasNote)
	case "terminal-group":
		return fmt.Sprintf(`Usage:
  warren %s list [--all] [--search TEXT] [--limit N] [-q]
  warren %s create [--name NAME] [--home PATH]
  warren %s remove GROUP_ID [--force]
  warren %s rename GROUP_ID --name NAME
  warren %s home GROUP_ID --path PATH
  warren %s move GROUP_ID [--before OTHER_GROUP_ID]
%s`, commandName, commandName, commandName, commandName, commandName, commandName, aliasNote)
	case "session":
		return `Usage:
  warren session list [--all | --ended] [WORKSPACE_ID] [--workspace ID] [--project ID] [--group ID] [--kind KIND] [--status STATUS] [--activity ACTIVITY] [--search TEXT] [--current] [--pinned] [--limit N] [-q]
  warren session current
  warren session panes [SESSION_ID] [-q]
  warren session create [WORKSPACE_ID] [--group GROUP_ID] [--kind KIND] [--command CMD] [--title TITLE]
  warren session remove SESSION_ID [--force] [--current] [--dry-run]
  warren session rename SESSION_ID --title TITLE [--current]
  warren session pin SESSION_ID --pinned BOOL [--current]
  warren session move SESSION_ID --workspace WORKSPACE_ID [--confirm] [--expected-workspace ID] [--expected-agent-session ID] [--dry-run]
  warren session move --current --workspace WORKSPACE_ID [--dry-run]
  warren session move SESSION_ID --group GROUP_ID [--confirm] [--dry-run]
  warren session send SESSION_ID [TEXT...] [--current] [--raw]
  warren session read SESSION_ID [--timeout DURATION] [--contains TEXT] [--current]
  warren session undo OPERATION_ID

Session is a generic PTY resource. Use agent create for Codex, Claude, OpenCode,
Pi, Qoder, or Antigravity; Trae is only a shell preset and has no Agent
transcript/activity semantics.
`
	case "browser":
		return `Usage:
  warren browser list [--workspace ID | --group ID] [--search TEXT] [--limit N] [-q]
  warren browser create [--workspace ID | --group GROUP_ID] [--url URL] [--title TITLE] [--window] [--width N] [--height N]
  warren browser get SESSION_ID
  warren browser action SESSION_ID ACTION [flags]
  warren browser close SESSION_ID

A browser is a Warren Session that owns a Chromium rather than a PTY, so it
appears in the session and agent rosters and lives in a Workspace or Terminal
Group like anything else. The action subcommand drives it; the common actions
are navigate, snapshot, click, fill, text, evaluate, screenshot, and tabs.

The page is drawn inside Warren from the browser's own frame stream, so Chromium
runs with no window of its own. --window opts into a visible one, which is for
debugging the browser runtime rather than for ordinary use.

Run "warren browser action --help" for the action list and their flags.
`
	case "pane":
		return `Usage:
  warren pane list [--workspace WORKSPACE_ID | --group GROUP_ID] [--search TEXT] [--all] [--limit N] [-q]
  warren pane create (--workspace WORKSPACE_ID | --group GROUP_ID) --session SESSION_ID [--name NAME] [--before PANE_GROUP_ID]
  warren pane split --pane PANE_ID --session SESSION_ID [--axis horizontal|vertical] [--before]
  warren pane close --pane PANE_ID
  warren pane rename PANE_GROUP_ID --name NAME
  warren pane move PANE_GROUP_ID [--before OTHER_PANE_GROUP_ID]
  warren pane remove PANE_GROUP_ID

A pane is one whole-screen arrangement of Sessions, and several arrangements may
coexist in one Workspace or Terminal Group. Only one is rendered at a time, so
switching arrangements never changes how the others are laid out.
Splitting and closing panes edit the arrangement only: a Session keeps running
and stays reachable as an ordinary Tab. Use --json for the tree itself.
`
	}
	return ""
}

func taskWorkspaceUsageText(action string) string {
	switch action {
	case "list":
		return "Usage:\n  warren task workspace list TASK_ID [--available] [--all] [--limit N] [-q]\n\nDefault output is limited to 10 rows. Use --all for the complete list.\n"
	case "attach", "detach":
		return fmt.Sprintf("Usage:\n  warren task workspace %s TASK_ID WORKSPACE_ID\n", action)
	case "create":
		return "Usage:\n  warren task workspace create TASK_ID PROJECT_ID --branch BRANCH [--name NAME] [--path PATH]\n"
	default:
		return `Usage:
  warren task workspace list TASK_ID [--available] [--all] [--limit N] [-q]
  warren task workspace attach TASK_ID WORKSPACE_ID
  warren task workspace detach TASK_ID WORKSPACE_ID
  warren task workspace create TASK_ID PROJECT_ID --branch BRANCH [--name NAME] [--path PATH]
`
	}
}

func actionUsageText(commandName, action string) string {
	name := commandName
	switch canonicalResource(commandName) + "." + action {
	case "browser.list":
		return fmt.Sprintf("Usage:\n  warren %s %s [--workspace ID | --group ID] [--search TEXT] [--limit N] [-q]\n\nDefault output is limited to 10 rows. The list is projected from the roster, so it costs no extra round trip and cannot disagree with `warren session list`.\n", name, action)
	case "browser.create":
		return fmt.Sprintf("Usage:\n  warren %s create [--workspace ID | --group GROUP_ID] [--url URL] [--title TITLE] [--window] [--width N] [--height N]\n\nExactly one scope is required. The page is drawn inside Warren from the browser's frame stream, so Chromium runs with no window of its own; --window opts into a visible one for debugging the browser runtime. The URL, if given, is opened before the command returns.\n", name)
	case "browser.get":
		return fmt.Sprintf("Usage:\n  warren %s get SESSION_ID\n", name)
	case "browser.action":
		return fmt.Sprintf(`Usage:
  warren %s action SESSION_ID ACTION [flags]

The action name is positional, and every action answers with the page URL and
title it left behind:
  navigate --url URL [--wait-until load|domcontentloaded|networkidle|none]
  snapshot [--interactive] [--max-nodes N]
  click --selector SELECTOR
  hover --selector SELECTOR
  type --selector SELECTOR [--text TEXT | --value VALUE] [--clear] [--delay MS]
  press --selector SELECTOR --value KEY
  select --selector SELECTOR --value VALUE [--values A,B]
  scroll [--dy N] [--dx N]
  wait --selector SELECTOR [--state visible|hidden|attached|detached] [--timeout MS]
  evaluate --expression JS
  screenshot [--path FILE] [--full-page] [--quality N]
  console [--level log|warn|error] [--limit N]
  cookies
  back | forward | reload [--hard]
  viewport --width N --height N
  tabs.list | tabs.new [--url URL] | tabs.select --tab TAB_ID | tabs.close --tab TAB_ID
`, name)
	case "browser.close", "browser.remove", "browser.delete":
		return fmt.Sprintf("Usage:\n  warren %s close SESSION_ID\n\nThe Chromium and its profile directory are removed, and the Session ends. Use `warren session remove SESSION_ID` to reach the same end through the session resource.\n", name)
	case "task.list", "project.list", "workspace.list", "session.list":
		if canonicalResource(commandName) == "session" {
			return fmt.Sprintf("Usage:\n  warren %s %s [--all | --ended] [WORKSPACE_ID] [--workspace ID] [--project ID] [--group ID] [--kind KIND] [--status STATUS] [--activity ACTIVITY] [--search TEXT] [--current] [--pinned] [--limit N] [-q]\n\nDefault output is limited to 10 rows with long fields truncated. Use --search or filters to narrow down, --all for the complete list, and -q for IDs only.\n", name, action)
		}
		if canonicalResource(commandName) == "workspace" {
			return fmt.Sprintf("Usage:\n  warren %s %s [--all] [PROJECT_ID] [--project ID] [--task ID] [--branch BRANCH] [--merged | --unmerged] [--unattached] [--has-sessions] [--search TEXT] [--pinned] [--limit N] [-q]\n\nDefault output is limited to 10 rows with long fields truncated. Use --search or filters to narrow down, --all for the complete list, and -q for IDs only.\n", name, action)
		}
		if canonicalResource(commandName) == "task" {
			return fmt.Sprintf("Usage:\n  warren %s %s [--all] [--source SOURCE] [--has-workspaces | --unattached] [--search TEXT] [--pinned] [--limit N] [-q]\n\nDefault output is limited to 10 rows with long fields truncated. Use --search or filters to narrow down, --all for the complete list, and -q for IDs only.\n", name, action)
		}
		return fmt.Sprintf("Usage:\n  warren %s %s [--all] [--search TEXT] [--has-workspaces] [--pinned] [--limit N] [-q]\n\nDefault output is limited to 10 rows with long fields truncated. Use --search or filters to narrow down, --all for the complete list, and -q for IDs only.\n", name, action)
	case "terminal-group.list":
		return fmt.Sprintf("Usage:\n  warren %s %s [--all] [--search TEXT] [--limit N] [-q]\n\nDefault output is limited to 10 rows with long fields truncated. Use --search or filters to narrow down, --all for the complete list, and -q for IDs only.\n", name, action)
	case "pane.list":
		return fmt.Sprintf("Usage:\n  warren %s %s [--workspace WORKSPACE_ID | --group GROUP_ID] [--search TEXT] [--all] [--limit N] [-q]\n\nDefault output is limited to 10 rows. Use --all for the complete list, and -q for IDs only.\n", name, action)
	case "pane.create":
		return fmt.Sprintf("Usage:\n  warren %s create (--workspace WORKSPACE_ID | --group GROUP_ID) --session SESSION_ID [--name NAME] [--before PANE_GROUP_ID]\n", name)
	case "pane.split":
		return fmt.Sprintf("Usage:\n  warren %s split --pane PANE_ID --session SESSION_ID [--axis horizontal|vertical] [--before]\n\nThe new pane goes after the named pane unless --before is given.\n", name)
	case "pane.close":
		return fmt.Sprintf("Usage:\n  warren %s close --pane PANE_ID\n\nClosing the last pane of an arrangement removes the arrangement. The Session keeps running.\n", name)
	case "pane.rename":
		return fmt.Sprintf("Usage:\n  warren %s rename PANE_GROUP_ID --name NAME\n", name)
	case "pane.move":
		return fmt.Sprintf("Usage:\n  warren %s move PANE_GROUP_ID [--before OTHER_PANE_GROUP_ID]\n", name)
	case "pane.remove", "pane.delete":
		return fmt.Sprintf("Usage:\n  warren %s remove PANE_GROUP_ID\n\nThe arrangement is deleted; its Sessions keep running and stay reachable as Tabs.\n", name)
	case "task.create", "task.add":
		return fmt.Sprintf("Usage:\n  warren %s create --name NAME [--source SOURCE --external-id ID] [--url URL]\n", name)
	case "task.remove", "task.delete":
		return fmt.Sprintf("Usage:\n  warren %s remove TASK_ID\n", name)
	case "task.rename":
		return fmt.Sprintf("Usage:\n  warren %s rename TASK_ID --name NAME\n", name)
	case "task.pin":
		return fmt.Sprintf("Usage:\n  warren %s pin TASK_ID --pinned BOOL\n", name)
	case "task.move":
		return fmt.Sprintf("Usage:\n  warren %s move TASK_ID [--before OTHER_TASK_ID]\n", name)
	case "task.attach", "task.detach":
		return fmt.Sprintf("Usage:\n  warren %s %s TASK_ID WORKSPACE_ID\n", name, action)
	case "project.add":
		return fmt.Sprintf("Usage:\n  warren %s add PATH [--name NAME] [--auto-import-worktrees]\n", name)
	case "project.remove", "project.delete":
		return fmt.Sprintf("Usage:\n  warren %s remove PROJECT_ID [--force]\n", name)
	case "project.rename":
		return fmt.Sprintf("Usage:\n  warren %s rename PROJECT_ID --name NAME\n", name)
	case "project.pin":
		return fmt.Sprintf("Usage:\n  warren %s pin PROJECT_ID --pinned BOOL\n", name)
	case "project.move":
		return fmt.Sprintf("Usage:\n  warren %s move PROJECT_ID [--before OTHER_PROJECT_ID]\n", name)
	case "workspace.create", "workspace.add":
		return fmt.Sprintf("Usage:\n  warren %s create PROJECT_ID --branch BRANCH [--name NAME] [--path PATH]\n", name)
	case "workspace.remove", "workspace.delete":
		return fmt.Sprintf("Usage:\n  warren %s remove WORKSPACE_ID [--force] [--keep-worktree]\n", name)
	case "workspace.rename":
		return fmt.Sprintf("Usage:\n  warren %s rename WORKSPACE_ID --name NAME\n", name)
	case "workspace.pin":
		return fmt.Sprintf("Usage:\n  warren %s pin WORKSPACE_ID --pinned BOOL\n", name)
	case "workspace.move":
		return fmt.Sprintf("Usage:\n  warren %s move WORKSPACE_ID [--before OTHER_WORKSPACE_ID]\n", name)
	case "terminal-group.create", "terminal-group.add":
		return fmt.Sprintf("Usage:\n  warren %s create [--name NAME] [--home PATH]\n", name)
	case "terminal-group.remove", "terminal-group.delete":
		return fmt.Sprintf("Usage:\n  warren %s remove GROUP_ID [--force]\n", name)
	case "terminal-group.rename":
		return fmt.Sprintf("Usage:\n  warren %s rename GROUP_ID --name NAME\n", name)
	case "terminal-group.home":
		return fmt.Sprintf("Usage:\n  warren %s home GROUP_ID --path PATH\n", name)
	case "terminal-group.move":
		return fmt.Sprintf("Usage:\n  warren %s move GROUP_ID [--before OTHER_GROUP_ID]\n", name)
	case "session.create", "session.add":
		return fmt.Sprintf("Usage:\n  warren %s create [WORKSPACE_ID] [--group GROUP_ID] [--kind KIND] [--command CMD] [--title TITLE]\n", name)
	case "session.remove", "session.delete", "session.kill":
		return fmt.Sprintf("Usage:\n  warren %s remove SESSION_ID [--force] [--current] [--dry-run]\n", name)
	case "session.rename":
		return fmt.Sprintf("Usage:\n  warren %s rename SESSION_ID --title TITLE [--current]\n", name)
	case "session.pin":
		return fmt.Sprintf("Usage:\n  warren %s pin SESSION_ID --pinned BOOL [--current]\n", name)
	case "session.move":
		return fmt.Sprintf("Usage:\n  warren %s move SESSION_ID --workspace WORKSPACE_ID [--confirm] [--expected-workspace ID] [--expected-agent-session ID] [--dry-run]\n  warren %s move --current --workspace WORKSPACE_ID [--dry-run]\n  warren %s move SESSION_ID --group GROUP_ID [--confirm] [--dry-run]\n", name, name, name)
	case "session.send":
		return fmt.Sprintf("Usage:\n  warren %s send SESSION_ID [TEXT...] [--current] [--raw]\n", name)
	case "session.read":
		return fmt.Sprintf("Usage:\n  warren %s read SESSION_ID [--timeout DURATION] [--contains TEXT] [--current]\n", name)
	case "session.current":
		return fmt.Sprintf("Usage:\n  warren %s current\n", name)
	case "session.panes":
		return fmt.Sprintf("Usage:\n  warren %s panes [SESSION_ID] [--json] [-q]\n\nGROUP/PANE columns come from the Host's arrangement; SCREEN names a connected client\nthat is displaying the Session right now, and is empty when none is.\n", name)
	case "session.undo":
		return fmt.Sprintf("Usage:\n  warren %s undo OPERATION_ID\n", name)
	}
	return resourceUsageText(commandName)
}

func endpointUsageText() string {
	return `Usage:
  warren endpoint list
  warren endpoint add NAME --url URL --token TOKEN [--use]
  warren endpoint add NAME --ssh SSH [--ssh-remote 127.0.0.1:8789] [--use]
  warren endpoint add NAME --type relay --url RELAY_URL --token ACCESS_TOKEN --host-id HOST_ID [--route-id ROUTE_ID] [--use]
  warren endpoint use NAME
  warren endpoint remove NAME
  warren endpoint current
`
}

func sshUsageText() string {
	return `Usage:
  warren ssh list [PATTERN] [--search TEXT] [--limit N] [--ssh-config PATH] [--json] [-q]
  warren ssh TARGET [--local-port PORT] [--remote-port PORT] [--name NAME] [--ssh-config PATH] [--known-hosts PATH]

TARGET is an SSH alias from ~/.ssh/config or user@host. The embedded client
resolves OpenSSH config (Host, Include, HostName, User, Port, IdentityFile,
UserKnownHostsFile, GlobalKnownHostsFile, IdentityAgent, HostKeyAlias), verifies
host keys against known_hosts, and authenticates via ssh-agent or IdentityFile.
It bootstraps warren-headless on the remote host
and forwards a loopback port to 127.0.0.1:8789.

Unsupported ProxyJump/ProxyCommand aliases are reported by 'warren ssh list';
use a direct host or keep an external 'ssh -L' tunnel with 'warren endpoint add'.

Options:
  --local-port PORT     local loopback port (default 0 = ephemeral random port)
  --remote-port PORT    remote daemon port (default 8789)
  --name NAME           endpoint name (default TARGET with @/: replaced by -)
  --ssh-config PATH     SSH config path (default ~/.ssh/config)
  --known-hosts PATH    known_hosts path (default OpenSSH user/system files)

Examples:
  warren ssh list
  warren ssh tenc_sh
  warren ssh user@vps --local-port 8789 --name vps
`
}
