// Package discovery publishes the local Warren Host as a DNS-SD service.
package discovery

import (
	"fmt"
	"net"
	"os"
	"sort"
	"strings"

	"github.com/hashicorp/mdns"
	"github.com/miekg/dns"
)

const (
	ServiceType   = "_warren._tcp"
	ServiceDomain = "local."
	TXTVersion    = "1"
)

// Config describes the public, non-secret part of a Warren Host
// advertisement. Authentication credentials and private filesystem paths are
// deliberately absent from this type.
type Config struct {
	HostID      string
	HostName    string
	DNSHostName string
	Protocol    string
	Build       string
	Port        int
	TLS         bool
	PairingOpen bool
	// PairingOpenFunc optionally supplies the live state of the explicit Host
	// pairing window. When absent, PairingOpen is used as a static value.
	PairingOpenFunc func() bool
	Candidates      []net.IP
	InstanceName    string
}

// Advertisement contains the normalized values used to register a Host.
// Keeping this separate from mdns.MDNSService makes metadata testable without
// opening a multicast socket.
type Advertisement struct {
	InstanceName string
	HostName     string
	Port         int
	IPs          []net.IP
	TXT          []string
}

// BuildAdvertisement validates and normalizes a Host advertisement.
func BuildAdvertisement(config Config) (Advertisement, error) {
	hostID := strings.TrimSpace(config.HostID)
	if hostID == "" {
		return Advertisement{}, fmt.Errorf("host ID is required")
	}
	if config.Port < 1 || config.Port > 65535 {
		return Advertisement{}, fmt.Errorf("invalid Host port %d", config.Port)
	}
	displayName := strings.TrimSpace(config.HostName)
	if displayName == "" {
		displayName, _ = os.Hostname()
	}
	if displayName == "" {
		return Advertisement{}, fmt.Errorf("Host name is unavailable")
	}
	dnsHostName := strings.TrimSpace(config.DNSHostName)
	if dnsHostName == "" {
		dnsHostName, _ = os.Hostname()
	}
	if dnsHostName == "" {
		return Advertisement{}, fmt.Errorf("DNS host name is unavailable")
	}
	protocol := strings.TrimSpace(config.Protocol)
	if protocol == "" {
		protocol = "4.0"
	}
	build := strings.TrimSpace(config.Build)
	if build == "" {
		build = "unknown"
	}
	ips := normalizeIPs(config.Candidates)
	if len(ips) == 0 {
		return Advertisement{}, fmt.Errorf("no non-loopback network addresses available")
	}
	instance := strings.TrimSpace(config.InstanceName)
	if instance == "" {
		instance = fmt.Sprintf("%s (%s)", displayName, shortHostID(hostID))
	}
	txt := []string{
		"txtvers=" + TXTVersion,
		"id=" + hostID,
		"name=" + displayName,
		"ver=" + protocol,
		"build=" + build,
		fmt.Sprintf("tls=%d", boolInt(config.TLS)),
		fmt.Sprintf("pair=%d", boolInt(config.PairingOpen)),
	}
	txt = append(txt, candidateTXTEntries(ips, config.Port)...)
	hostName := normalizeDNSHostName(dnsHostName)
	if hostName == "" {
		return Advertisement{}, fmt.Errorf("DNS host name is unavailable")
	}
	return Advertisement{
		InstanceName: instance,
		HostName:     hostName,
		Port:         config.Port,
		IPs:          ips,
		TXT:          txt,
	}, nil
}

// FilterForListener keeps only addresses that the HTTP listener can actually
// serve. An unspecified listener accepts every local interface; a loopback or
// specifically bound listener must not advertise unreachable candidates.
func FilterForListener(candidates []net.IP, listenerAddress string) []net.IP {
	host, _, err := net.SplitHostPort(strings.TrimSpace(listenerAddress))
	if err != nil {
		return normalizeIPs(candidates)
	}
	boundIP := net.ParseIP(host)
	if boundIP == nil || boundIP.IsUnspecified() {
		return normalizeIPs(candidates)
	}
	if boundIP.IsLoopback() {
		return nil
	}
	filtered := make([]net.IP, 0, len(candidates))
	for _, candidate := range candidates {
		if candidate.Equal(boundIP) {
			filtered = append(filtered, candidate)
		}
	}
	return normalizeIPs(filtered)
}

// Start starts a DNS-SD responder for the Warren Host. The returned shutdown
// function is idempotent from the underlying responder's perspective and must
// be called when the HTTP listener stops.
func Start(config Config) (func() error, error) {
	advertisement, err := BuildAdvertisement(config)
	if err != nil {
		return nil, err
	}
	service, err := mdns.NewMDNSService(
		advertisement.InstanceName,
		ServiceType,
		ServiceDomain,
		advertisement.HostName,
		advertisement.Port,
		advertisement.IPs,
		advertisement.TXT,
	)
	if err != nil {
		return nil, fmt.Errorf("create mDNS service: %w", err)
	}
	zone := mdns.Zone(service)
	if config.PairingOpenFunc != nil {
		zone = dynamicPairingZone{service: service, open: config.PairingOpenFunc}
	}
	server, err := mdns.NewServer(&mdns.Config{Zone: zone})
	if err != nil {
		return nil, fmt.Errorf("start mDNS service: %w", err)
	}
	return server.Shutdown, nil
}

// dynamicPairingZone keeps the advertised `pair` bit aligned with the
// in-memory Host pairing window without restarting the multicast listener.
// All other records remain owned by hashicorp/mdns.
type dynamicPairingZone struct {
	service *mdns.MDNSService
	open    func() bool
}

func (z dynamicPairingZone) Records(question dns.Question) []dns.RR {
	records := z.service.Records(question)
	if question.Qtype != dns.TypeTXT || len(records) == 0 {
		return records
	}
	open := false
	if z.open != nil {
		open = z.open()
	}
	for _, record := range records {
		txt, ok := record.(*dns.TXT)
		if !ok {
			continue
		}
		values := make([]string, 0, len(txt.Txt)+1)
		for _, value := range txt.Txt {
			if strings.HasPrefix(value, "pair=") {
				continue
			}
			values = append(values, value)
		}
		values = append(values, fmt.Sprintf("pair=%d", boolInt(open)))
		txt.Txt = values
	}
	return records
}

// LocalAddresses returns addresses suitable for a LAN advertisement. It
// excludes loopback, point-to-point, link-local, unspecified, multicast, and
// interface-down addresses.
func LocalAddresses() ([]net.IP, error) {
	interfaces, err := net.Interfaces()
	if err != nil {
		return nil, fmt.Errorf("list network interfaces: %w", err)
	}
	var addresses []net.IP
	for _, iface := range interfaces {
		if iface.Flags&net.FlagUp == 0 ||
			iface.Flags&net.FlagLoopback != 0 ||
			iface.Flags&net.FlagPointToPoint != 0 {
			continue
		}
		values, err := iface.Addrs()
		if err != nil {
			continue
		}
		for _, value := range values {
			var ip net.IP
			switch address := value.(type) {
			case *net.IPNet:
				ip = address.IP
			case *net.IPAddr:
				ip = address.IP
			}
			if ip == nil ||
				ip.IsUnspecified() ||
				ip.IsLoopback() ||
				ip.IsMulticast() ||
				ip.IsLinkLocalUnicast() {
				continue
			}
			addresses = append(addresses, ip)
		}
	}
	return normalizeIPs(addresses), nil
}

func candidateAddresses(ips []net.IP, port int) []string {
	values := make([]string, 0, len(ips))
	for _, ip := range ips {
		values = append(values, net.JoinHostPort(ip.String(), fmt.Sprint(port)))
	}
	return values
}

const maxDNSTXTStringBytes = 255

func candidateTXTEntries(ips []net.IP, port int) []string {
	addresses := candidateAddresses(ips, port)
	entries := make([]string, 0, len(addresses))
	var current []string
	for _, address := range addresses {
		key := candidateTXTKey(len(entries))
		limit := maxDNSTXTStringBytes - len(key) - 1 // account for `key=`
		joined := strings.Join(append(append([]string(nil), current...), address), ",")
		if len(current) > 0 && len(joined) > limit {
			entries = append(entries, key+"="+strings.Join(current, ","))
			current = []string{address}
			continue
		}
		current = append(current, address)
	}
	if len(current) > 0 {
		key := candidateTXTKey(len(entries))
		entries = append(entries, key+"="+strings.Join(current, ","))
	}
	return entries
}

func candidateTXTKey(index int) string {
	if index == 0 {
		return "cand"
	}
	return fmt.Sprintf("cand.%d", index)
}

func normalizeIPs(values []net.IP) []net.IP {
	seen := make(map[string]struct{}, len(values))
	result := make([]net.IP, 0, len(values))
	for _, value := range values {
		ip := value.To4()
		if ip == nil {
			ip = value.To16()
		}
		if ip == nil ||
			ip.IsUnspecified() ||
			ip.IsLoopback() ||
			ip.IsMulticast() ||
			ip.IsLinkLocalUnicast() {
			continue
		}
		key := ip.String()
		if _, ok := seen[key]; ok {
			continue
		}
		seen[key] = struct{}{}
		result = append(result, ip)
	}
	sort.SliceStable(result, func(i, j int) bool {
		leftV4 := result[i].To4() != nil
		rightV4 := result[j].To4() != nil
		if leftV4 != rightV4 {
			return leftV4
		}
		return result[i].String() < result[j].String()
	})
	return result
}

func shortHostID(value string) string {
	value = strings.TrimSpace(value)
	if len(value) <= 8 {
		return value
	}
	return value[:8]
}

func normalizeDNSHostName(value string) string {
	value = strings.TrimSpace(strings.TrimSuffix(value, "."))
	if value == "" {
		return ""
	}
	if !strings.Contains(value, ".") {
		value += ".local"
	}
	return value + "."
}

func boolInt(value bool) int {
	if value {
		return 1
	}
	return 0
}
