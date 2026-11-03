package drift

import (
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"

	"github.com/abcdlsj/warren/Headless/internal/protocol"
)

// TestAgentEventTypes keeps the canonical Agent event vocabulary in one place.
//
// The schema's `agentEvents.types` is the authority; protocolgen copies it into
// Go, and every client folds the same events by name. Nothing here generates
// client code, so the test guards the two ways the three clients drift apart:
// the generated Go list falling behind the schema, and a client handling an
// event type the schema never declared.
func TestAgentEventTypes(t *testing.T) {
	s, root := loadSchema(t)
	declared := s.Properties.AgentEvents.Properties.Types.Items.Enum
	if len(declared) == 0 {
		t.Fatal("schema declares no agentEvents.types")
	}

	t.Run("generated_go_list_matches_schema", func(t *testing.T) {
		if strings.Join(protocol.AgentEventTypes, "\n") != strings.Join(declared, "\n") {
			t.Fatalf("protocol.AgentEventTypes is stale; run go generate ./Headless/internal/protocol")
		}
	})

	t.Run("host_and_clients_only_name_declared_types", func(t *testing.T) {
		namespaces := map[string]bool{}
		for _, name := range declared {
			namespaces[strings.SplitN(name, ".", 2)[0]] = true
		}

		patterns := []string{
			"Headless/internal/agent/*.go",
			"Headless/internal/server/agent_*.go",
			"Sources/Warren/WarrenRemoteApplicationModel+Agent.swift",
			"Web/src/agent.js",
			"Web/src/agent.jsx",
			"Web/src/conversation.js",
			"Web/src/conversation.jsx",
		}
		paths := []string{}
		for _, pattern := range patterns {
			matches, err := filepath.Glob(filepath.Join(root, pattern))
			if err != nil {
				t.Fatalf("glob %s: %v", pattern, err)
			}
			paths = append(paths, matches...)
		}
		if len(paths) == 0 {
			t.Fatal("no Agent sources found to scan")
		}

		literal := regexp.MustCompile(`"([a-z]+(?:\.[a-z]+)+)"`)
		known := map[string]bool{}
		for _, name := range declared {
			known[name] = true
		}

		var undeclared []string
		for _, path := range paths {
			data, err := os.ReadFile(path)
			if err != nil {
				t.Fatalf("read %s: %v", path, err)
			}
			seen := map[string]bool{}
			for _, match := range literal.FindAllStringSubmatch(string(data), -1) {
				name := match[1]
				if !namespaces[strings.SplitN(name, ".", 2)[0]] || known[name] || seen[name] {
					continue
				}
				seen[name] = true
				relative, _ := filepath.Rel(root, path)
				undeclared = append(undeclared, relative+": "+name)
			}
		}
		sort.Strings(undeclared)
		if len(undeclared) > 0 {
			t.Fatalf("event types used but not declared in protocol/warren.schema.json:\n%s",
				strings.Join(undeclared, "\n"))
		}
	})
}
