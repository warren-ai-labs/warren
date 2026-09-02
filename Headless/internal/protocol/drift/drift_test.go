// Package drift verifies that the protocol bindings in every language stay
// in sync with protocol/warren.schema.json. Run via `go test ./...` from
// the Headless module. A failure here means a constant moved in one
// binding but not the others.
package drift

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"
)

type schemaDoc struct {
	Properties struct {
		LogicalVersion struct {
			Const string `json:"const"`
		} `json:"logicalVersion"`
		BinaryEnvelope struct {
			Properties struct {
				Magic struct {
					Const []int `json:"const"`
				} `json:"magic"`
				WireVersion struct {
					Const int `json:"const"`
				} `json:"wireVersion"`
				Directions struct {
					Properties struct {
						ClientToHost struct {
							Const int `json:"const"`
						} `json:"clientToHost"`
						HostToClient struct {
							Const int `json:"const"`
						} `json:"hostToClient"`
					} `json:"properties"`
				} `json:"directions"`
				Kinds struct {
					Properties struct {
						Input struct {
							Const int `json:"const"`
						} `json:"input"`
						Output struct {
							Const int `json:"const"`
						} `json:"output"`
						AtomicState struct {
							Const int `json:"const"`
						} `json:"atomicState"`
					} `json:"properties"`
				} `json:"kinds"`
				Limits struct {
					Properties struct {
						MaxHeader struct {
							Const int `json:"const"`
						} `json:"maxHeader"`
						MaxPayload struct {
							Const int `json:"const"`
						} `json:"maxPayload"`
						MaxAtomicStatePayload struct {
							Const int `json:"const"`
						} `json:"maxAtomicStatePayload"`
					} `json:"properties"`
				} `json:"limits"`
				Layout struct {
					Properties struct {
						PrefixLength struct {
							Const int `json:"const"`
						} `json:"prefixLength"`
					} `json:"properties"`
				} `json:"layout"`
			} `json:"properties"`
		} `json:"binaryEnvelope"`
		Capabilities struct {
			Items struct {
				Enum []string `json:"enum"`
			} `json:"items"`
		} `json:"capabilities"`
		TerminalStateFormats struct {
			Items struct {
				Enum []string `json:"enum"`
			} `json:"items"`
		} `json:"terminalStateFormats"`
		RelayStream struct {
			Properties struct {
				Magic struct {
					Const string `json:"const"`
				} `json:"magic"`
				WireVersion struct {
					Const int `json:"const"`
				} `json:"wireVersion"`
				HeaderSize struct {
					Const int `json:"const"`
				} `json:"headerSize"`
				Frames struct {
					Properties struct {
						Open struct {
							Const int `json:"const"`
						} `json:"open"`
						Close struct {
							Const int `json:"const"`
						} `json:"close"`
						Text struct {
							Const int `json:"const"`
						} `json:"text"`
						Binary struct {
							Const int `json:"const"`
						} `json:"binary"`
						HTTPHeaders struct {
							Const int `json:"const"`
						} `json:"httpHeaders"`
						Data struct {
							Const int `json:"const"`
						} `json:"data"`
						End struct {
							Const int `json:"const"`
						} `json:"end"`
						WindowUpdate struct {
							Const int `json:"const"`
						} `json:"windowUpdate"`
						Error struct {
							Const int `json:"const"`
						} `json:"error"`
					} `json:"properties"`
				} `json:"frames"`
				Limits struct {
					Properties struct {
						MaxMessageBytes struct {
							Const int `json:"const"`
						} `json:"maxMessageBytes"`
						InitialStreamWindow struct {
							Const int `json:"const"`
						} `json:"initialStreamWindow"`
						MaxHostStreams struct {
							Const int `json:"const"`
						} `json:"maxHostStreams"`
						MaxPublicStreams struct {
							Const int `json:"const"`
						} `json:"maxPublicStreams"`
					} `json:"properties"`
				} `json:"limits"`
			} `json:"properties"`
		} `json:"relayStream"`
	} `json:"properties"`
}

func loadSchema(t *testing.T) (schemaDoc, string) {
	t.Helper()
	root := repoRoot(t)
	schemaPath := filepath.Join(root, "protocol", "warren.schema.json")
	data, err := os.ReadFile(schemaPath)
	if err != nil {
		t.Fatalf("read schema at %s: %v", schemaPath, err)
	}
	var s schemaDoc
	if err := json.Unmarshal(data, &s); err != nil {
		t.Fatalf("parse schema: %v", err)
	}
	return s, root
}

func repoRoot(t *testing.T) string {
	t.Helper()
	// Walk up from the test file looking for protocol/warren.schema.json. The
	// test is built into Headless/internal/protocol/drift, so two ../ jumps
	// land at the repo root.
	cwd, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	dir := cwd
	for i := 0; i < 6; i++ {
		if _, err := os.Stat(filepath.Join(dir, "protocol", "warren.schema.json")); err == nil {
			return dir
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			break
		}
		dir = parent
	}
	t.Fatalf("could not find protocol/warren.schema.json from %s", cwd)
	return ""
}

func TestProtocolBindings(t *testing.T) {
	s, root := loadSchema(t)
	be := s.Properties.BinaryEnvelope.Properties
	rs := s.Properties.RelayStream.Properties

	t.Run("go_generated_matches_schema", func(t *testing.T) {
		path := filepath.Join(root, "Headless/internal/protocol/wire.go")
		contents := mustRead(t, path)
		magic := mustExtractHexBytes(t, path, contents,
			regexp.MustCompile(`var BinaryMagic = \[\]byte\{([^}]+)\}`))
		if !sameBytes(magic, be.Magic.Const) {
			t.Errorf("BinaryMagic = %v, want %v", magic, be.Magic.Const)
		}
		mustIntEqual(t, path, contents, `BinaryWireVersion uint8 = (\d+)`, be.WireVersion.Const)
		mustIntEqual(t, path, contents, `DirectionClientToHost uint8 = (\d+)`, be.Directions.Properties.ClientToHost.Const)
		mustIntEqual(t, path, contents, `DirectionHostToClient uint8 = (\d+)`, be.Directions.Properties.HostToClient.Const)
		mustIntEqual(t, path, contents, `KindInput\s+uint8 = (\d+)`, be.Kinds.Properties.Input.Const)
		mustIntEqual(t, path, contents, `KindOutput\s+uint8 = (\d+)`, be.Kinds.Properties.Output.Const)
		mustIntEqual(t, path, contents, `KindAtomicState uint8 = (\d+)`, be.Kinds.Properties.AtomicState.Const)
		mustIntEqual(t, path, contents, `MaxHeader\s+= (\d+)`, be.Limits.Properties.MaxHeader.Const)
		mustIntEqual(t, path, contents, `MaxPayload\s+= (\d+)`, be.Limits.Properties.MaxPayload.Const)
		mustIntEqual(t, path, contents, `MaxAtomicStatePayload = (\d+)`, be.Limits.Properties.MaxAtomicStatePayload.Const)
		mustIntEqual(t, path, contents, `BinaryPrefixLength = (\d+)`, be.Layout.Properties.PrefixLength.Const)
		if !strings.Contains(contents, fmt.Sprintf("LogicalVersion = %q", s.Properties.LogicalVersion.Const)) {
			t.Errorf("LogicalVersion literal not found")
		}
		capList := extractStringSlice(t, path, contents, regexp.MustCompile(`var Capabilities = \[\]string\{([\s\S]*?)\}`))
		if !stringSlicesEqual(capList, s.Properties.Capabilities.Items.Enum) {
			t.Errorf("Capabilities = %v, want %v", capList, s.Properties.Capabilities.Items.Enum)
		}
		fmtList := extractStringSlice(t, path, contents, regexp.MustCompile(`var TerminalStateFormats = \[\]string\{([\s\S]*?)\}`))
		if !stringSlicesEqual(fmtList, s.Properties.TerminalStateFormats.Items.Enum) {
			t.Errorf("TerminalStateFormats = %v, want %v", fmtList, s.Properties.TerminalStateFormats.Items.Enum)
		}
	})

	t.Run("go_output_wire_aliases_generated", func(t *testing.T) {
		// output/wire.go should not redeclare the literals; it must alias
		// the generated protocol package. This keeps a single source of
		// truth and ensures the binary envelope stays correct if the schema
		// is updated.
		path := filepath.Join(root, "Headless/internal/output/wire.go")
		contents := mustRead(t, path)
		aliases := map[string]string{
			"BinaryMagic":              "protocol.BinaryMagic",
			"Version":                  "protocol.BinaryWireVersion",
			"DirectionClientToHost":    "protocol.DirectionClientToHost",
			"DirectionHostToClient":    "protocol.DirectionHostToClient",
			"KindInput":                "protocol.KindInput",
			"KindOutput":               "protocol.KindOutput",
			"KindAtomicState":          "protocol.KindAtomicState",
			"MaxHeader":                "protocol.MaxHeader",
			"MaxPayload":               "protocol.MaxPayload",
			"MaxAtomicStatePayload":    "protocol.MaxAtomicStatePayload",
		}
		for name, target := range aliases {
			pattern := `\b` + name + `\b\s*=\s*` + regexp.QuoteMeta(target)
			if !regexp.MustCompile(pattern).MatchString(contents) {
				t.Errorf("%s: %q does not alias %s (must come from the generated package)", path, name, target)
			}
		}
	})

	t.Run("swift_wire_codec_matches_schema", func(t *testing.T) {
		path := filepath.Join(root, "Packages/Transport/Sources/WarrenTransport/WarrenWireCodec.swift")
		contents := mustRead(t, path)
		magic := mustExtractHexBytes(t, path, contents,
			regexp.MustCompile(`binaryMagic:\s*\[UInt8\]\s*=\s*\[([^\]]+)\]`))
		if !sameBytes(magic, be.Magic.Const) {
			t.Errorf("binaryMagic = %v, want %v", magic, be.Magic.Const)
		}
		mustIntEqual(t, path, contents, `binaryVersion:\s*UInt8\s*=\s*(\d+)`, be.WireVersion.Const)
		mustIntEqual(t, path, contents, `defaultMaxHeader\s*=\s*(\d+)\s*\*\s*1024`, be.Limits.Properties.MaxHeader.Const/1024)
		mustIntEqual(t, path, contents, `defaultMaxPayload\s*=\s*(\d+)\s*\*\s*1024\s*\*\s*1024`, be.Limits.Properties.MaxPayload.Const/(1024*1024))
		mustIntEqual(t, path, contents, `defaultMaxAtomicStatePayload\s*=\s*(\d+)\s*\*\s*1024\s*\*\s*1024`, be.Limits.Properties.MaxAtomicStatePayload.Const/(1024*1024))
	})

	t.Run("swift_binary_frame_kind_matches_schema", func(t *testing.T) {
		path := filepath.Join(root, "Packages/Protocol/Sources/WarrenProtocol/BinaryFrameKind.swift")
		contents := mustRead(t, path)
		mustIntEqual(t, path, contents, `case\s+clientToHost\s*=\s*(\d+)`, be.Directions.Properties.ClientToHost.Const)
		mustIntEqual(t, path, contents, `case\s+hostToClient\s*=\s*(\d+)`, be.Directions.Properties.HostToClient.Const)
		mustIntEqual(t, path, contents, `case\s+input\s*=\s*(\d+)`, be.Kinds.Properties.Input.Const)
		mustIntEqual(t, path, contents, `case\s+output\s*=\s*(\d+)`, be.Kinds.Properties.Output.Const)
		mustIntEqual(t, path, contents, `case\s+atomicState\s*=\s*(\d+)`, be.Kinds.Properties.AtomicState.Const)
	})

	t.Run("ts_wire_matches_schema", func(t *testing.T) {
		path := filepath.Join(root, "Web/src/wire.js")
		contents := mustRead(t, path)
		magic := mustExtractHexBytes(t, path, contents,
			regexp.MustCompile(`MAGIC\s*=\s*\[([^\]]+)\]`))
		if !sameBytes(magic, be.Magic.Const) {
			t.Errorf("MAGIC = %v, want %v", magic, be.Magic.Const)
		}
		mustIntEqual(t, path, contents, `VERSION\s*=\s*(\d+)`, be.WireVersion.Const)
		mustIntEqual(t, path, contents, `DIRECTION_CLIENT_TO_HOST\s*=\s*(\d+)`, be.Directions.Properties.ClientToHost.Const)
		mustIntEqual(t, path, contents, `DIRECTION_HOST_TO_CLIENT\s*=\s*(\d+)`, be.Directions.Properties.HostToClient.Const)
		mustIntEqual(t, path, contents, `KIND_INPUT\s*=\s*(\d+)`, be.Kinds.Properties.Input.Const)
		mustIntEqual(t, path, contents, `KIND_OUTPUT\s*=\s*(\d+)`, be.Kinds.Properties.Output.Const)
		mustIntEqual(t, path, contents, `KIND_ATOMIC_STATE\s*=\s*(\d+)`, be.Kinds.Properties.AtomicState.Const)
		mustIntEqual(t, path, contents, `MAX_HEADER\s*=\s*(\d+)\s*\*\s*1024`, be.Limits.Properties.MaxHeader.Const/1024)
		mustIntEqual(t, path, contents, `MAX_PAYLOAD\s*=\s*(\d+)\s*\*\s*1024\s*\*\s*1024`, be.Limits.Properties.MaxPayload.Const/(1024*1024))
		mustIntEqual(t, path, contents, `MAX_ATOMIC_STATE_PAYLOAD\s*=\s*(\d+)\s*\*\s*1024\s*\*\s*1024`, be.Limits.Properties.MaxAtomicStatePayload.Const/(1024*1024))
		mustIntEqual(t, path, contents, `PREFIX_LENGTH\s*=\s*(\d+)`, be.Layout.Properties.PrefixLength.Const)
	})

	t.Run("relay_protocol_matches_schema", func(t *testing.T) {
		path := filepath.Join(root, "RelayService/internal/controlplane/protocol.go")
		contents := mustRead(t, path)
		if !strings.Contains(contents, fmt.Sprintf("relayMagic = [4]byte{%q, %q, %q, %q}",
			rune(rs.Magic.Const[0]), rune(rs.Magic.Const[1]),
			rune(rs.Magic.Const[2]), rune(rs.Magic.Const[3]))) &&
			!strings.Contains(contents, fmt.Sprintf("relayMagic = [4]byte{'%c', '%c', '%c', '%c'}",
				rs.Magic.Const[0], rs.Magic.Const[1], rs.Magic.Const[2], rs.Magic.Const[3])) {
			t.Errorf("relayMagic = %q not found in %s", rs.Magic.Const, path)
		}
		mustIntEqual(t, path, contents, `relayVersion\s+byte\s*=\s*(\d+)`, rs.WireVersion.Const)
		mustIntEqual(t, path, contents, `headerSize\s+= (\d+)`, rs.HeaderSize.Const)
		mustIntEqual(t, path, contents, `frameOpen\s+byte\s*=\s*(\d+)`, rs.Frames.Properties.Open.Const)
		mustIntEqual(t, path, contents, `frameClose\s+byte\s*=\s*(\d+)`, rs.Frames.Properties.Close.Const)
		mustIntEqual(t, path, contents, `frameText\s+byte\s*=\s*(\d+)`, rs.Frames.Properties.Text.Const)
		mustIntEqual(t, path, contents, `frameBinary\s+byte\s*=\s*(\d+)`, rs.Frames.Properties.Binary.Const)
		mustIntEqual(t, path, contents, `frameHTTPHeaders\s+byte\s*=\s*(\d+)`, rs.Frames.Properties.HTTPHeaders.Const)
		mustIntEqual(t, path, contents, `frameData\s+byte\s*=\s*(\d+)`, rs.Frames.Properties.Data.Const)
		mustIntEqual(t, path, contents, `frameEnd\s+byte\s*=\s*(\d+)`, rs.Frames.Properties.End.Const)
		mustIntEqual(t, path, contents, `frameWindowUpdate\s+byte\s*=\s*(\d+)`, rs.Frames.Properties.WindowUpdate.Const)
		mustIntEqual(t, path, contents, `frameError\s+byte\s*=\s*(\d+)`, rs.Frames.Properties.Error.Const)
		mustIntEqual(t, path, contents, `maxRelayMessageBytes\s+=\s*(\d+)\s*\*\s*1024\s*\*\s*1024`, rs.Limits.Properties.MaxMessageBytes.Const/(1024*1024))
		mustIntEqual(t, path, contents, `initialStreamWindow\s+=\s*(\d+)\s*\*\s*1024\s*\*\s*1024`, rs.Limits.Properties.InitialStreamWindow.Const/(1024*1024))
		mustIntEqual(t, path, contents, `maxHostStreams\s+=\s*(\d+)`, rs.Limits.Properties.MaxHostStreams.Const)
		mustIntEqual(t, path, contents, `maxPublicStreams\s+=\s*(\d+)`, rs.Limits.Properties.MaxPublicStreams.Const)
	})
}

func mustRead(t *testing.T, path string) string {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	return string(data)
}

func mustIntEqual(t *testing.T, path, contents, pattern string, want int) {
	t.Helper()
	re := regexp.MustCompile(pattern)
	match := re.FindStringSubmatch(contents)
	if len(match) < 2 {
		t.Errorf("%s: pattern %q not found", path, pattern)
		return
	}
	got, err := strconv.Atoi(strings.TrimSpace(match[1]))
	if err != nil {
		t.Errorf("%s: parse %q: %v", path, match[1], err)
		return
	}
	if got != want {
		t.Errorf("%s: %s = %d, want %d", path, pattern, got, want)
	}
}

func mustExtractHexBytes(t *testing.T, path, contents string, re *regexp.Regexp) []int {
	t.Helper()
	match := re.FindStringSubmatch(contents)
	if len(match) < 2 {
		t.Fatalf("%s: pattern %q not found", path, re.String())
	}
	parts := strings.Split(match[1], ",")
	out := make([]int, 0, len(parts))
	for _, p := range parts {
		p = strings.TrimSpace(p)
		if p == "" {
			continue
		}
		// accept 0xNN, 0XNN, 'X', "X"
		if strings.HasPrefix(p, "0x") || strings.HasPrefix(p, "0X") {
			v, err := strconv.ParseInt(p[2:], 16, 16)
			if err != nil {
				t.Fatalf("%s: parse hex %q: %v", path, p, err)
			}
			out = append(out, int(v))
		} else if len(p) == 3 && p[0] == '\'' && p[2] == '\'' {
			out = append(out, int(p[1]))
		} else {
			t.Fatalf("%s: cannot parse byte literal %q", path, p)
		}
	}
	return out
}

func sameBytes(a, b []int) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func stringSlicesEqual(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// extractStringSlice pulls every "quoted" element out of a Go slice literal
// body. Whitespace and trailing commas are tolerated.
func extractStringSlice(t *testing.T, path, contents string, re *regexp.Regexp) []string {
	t.Helper()
	match := re.FindStringSubmatch(contents)
	if len(match) < 2 {
		t.Fatalf("%s: pattern %q not found", path, re.String())
	}
	quoted := regexp.MustCompile(`"((?:[^"\\]|\\.)*)"`)
	raw := quoted.FindAllStringSubmatch(match[1], -1)
	out := make([]string, 0, len(raw))
	for _, m := range raw {
		v, err := strconv.Unquote(`"` + m[1] + `"`)
		if err != nil {
			t.Fatalf("%s: unquote %q: %v", path, m[0], err)
		}
		out = append(out, v)
	}
	return out
}
