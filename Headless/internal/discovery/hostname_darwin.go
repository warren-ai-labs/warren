//go:build darwin

package discovery

import (
	"os"
	"os/exec"
	"strings"
)

// LocalDNSHostName reports the name the system's mDNS responder publishes for
// this machine. macOS keeps the local host name apart from the POSIX host name
// and renames it whenever it detects a conflict, so only the local host name is
// guaranteed to match the address records the resolver already maintains.
func LocalDNSHostName() (string, error) {
	if output, err := exec.Command("scutil", "--get", "LocalHostName").Output(); err == nil {
		if value := strings.TrimSpace(string(output)); value != "" {
			return value, nil
		}
	}
	return os.Hostname()
}
