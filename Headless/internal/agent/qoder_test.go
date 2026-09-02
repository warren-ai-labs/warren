package agent

import (
	"testing"
)

func TestValidateQoderCommand(t *testing.T) {
	tests := []struct {
		name    string
		command string
		wantErr bool
		errMsg  string
	}{
		{
			name:    "valid basic command",
			command: "qoder --new-session",
			wantErr: false,
		},
		{
			name:    "valid with workspace",
			command: "qoder --workspace /path/to/workspace",
			wantErr: false,
		},
		{
			name:    "rejects resume flag",
			command: "qoder --resume abc123",
			wantErr: true,
			errMsg:  "session resume or fork flags are not supported",
		},
		{
			name:    "rejects fork flag",
			command: "qoder --fork def456",
			wantErr: true,
			errMsg:  "session resume or fork flags are not supported",
		},
		{
			name:    "rejects session reuse",
			command: "qoder -c existing-session",
			wantErr: true,
			errMsg:  "session resume or fork flags are not supported",
		},
		{
			name:    "rejects shell operators",
			command: "qoder; ls",
			wantErr: true,
			errMsg:  "shell operators and substitutions are not supported",
		},
		{
			name:    "rejects command substitution",
			command: "qoder $(whoami)",
			wantErr: true,
			errMsg:  "shell operators and substitutions are not supported",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := ValidateQoderCommand(tt.command)
			if tt.wantErr {
				if err == nil {
					t.Errorf("expected error, got nil")
				} else if tt.errMsg != "" {
					if !contains(err.Error(), tt.errMsg) {
						t.Errorf("expected error containing %q, got %q", tt.errMsg, err.Error())
					}
				}
			} else {
				if err != nil {
					t.Errorf("expected no error, got %v", err)
				}
			}
		})
	}
}

func TestSplitQoderCommandWords(t *testing.T) {
	tests := []struct {
		name    string
		command string
		want    []string
		wantErr bool
	}{
		{
			name:    "simple command",
			command: "qoder new-session",
			want:    []string{"qoder", "new-session"},
			wantErr: false,
		},
		{
			name:    "with quotes",
			command: `qoder --name "my session"`,
			want:    []string{"qoder", "--name", "my session"},
			wantErr: false,
		},
		{
			name:    "nested single quotes",
			command: "qoder 'single' \"double\"",
			want:    []string{"qoder", "single", "double"},
			wantErr: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := splitQoderCommandWords(tt.command)
			if (err != nil) != tt.wantErr {
				t.Fatalf("splitQoderCommandWords() error = %v, wantErr %v", err, tt.wantErr)
			}
			if !equals(got, tt.want) {
				t.Errorf("splitQoderCommandWords() = %v, want %v", got, tt.want)
			}
		})
	}
}

func TestInjectQoderSessionID(t *testing.T) {
	tests := []struct {
		name           string
		command        string
		sessionID      string
		expected       string
		skipIfContains []string
	}{
		{
			name:      "basic injection",
			command:   "qoder",
			sessionID: "test-123",
			expected:  "qoder --session-id test-123",
		},
		{
			name:      "existing flags preserved",
			command:   "qoder --workspace /path",
			sessionID: "abc-456",
			expected:  "qoder --session-id abc-456 --workspace /path",
		},
		{
			name:      "skip if already has session id",
			command:   "qoder --session-id existing",
			sessionID: "new-id",
			expected:  "qoder --session-id existing",
		},
		{
			name:      "non-qoder command unchanged",
			command:   "other-command",
			sessionID: "any-id",
			expected:  "other-command",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := InjectQoderSessionID(tt.command, tt.sessionID)
			if result != tt.expected {
				t.Errorf("InjectQoderSessionID() = %q, want %q", result, tt.expected)
			}
		})
	}
}

// Helper functions
func contains(s, substr string) bool {
	return len(s) >= len(substr) && (s == substr || len(s) > len(substr) && findSubstring(s, substr))
}

func findSubstring(s, substr string) bool {
	for i := 0; i <= len(s)-len(substr); i++ {
		if s[i:i+len(substr)] == substr {
			return true
		}
	}
	return false
}

func equals(a, b []string) bool {
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
