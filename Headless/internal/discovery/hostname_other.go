//go:build !darwin

package discovery

import "os"

// LocalDNSHostName reports the name the platform's mDNS responder publishes.
// Linux and Windows responders announce the host name as <host>.local, so the
// POSIX host name is already the DNS-SD host name.
func LocalDNSHostName() (string, error) {
	return os.Hostname()
}
