package discovery

import (
	"fmt"
	"net"
	"strings"
	"testing"

	"github.com/hashicorp/mdns"
	"github.com/miekg/dns"
)

func TestBuildAdvertisementPublishesOnlyNonSecretMetadata(t *testing.T) {
	advertisement, err := BuildAdvertisement(Config{
		HostID:      "b79b2d8c-e8fd-438b-9e52-60e881c3cffb",
		HostName:    "Songjian's MacBook Pro",
		DNSHostName: "warren-test",
		Protocol:    "4.0",
		Build:       "dev-build",
		Port:        8789,
		TLS:         true,
		PairingOpen: true,
		Candidates:  []net.IP{net.ParseIP("127.0.0.1"), net.ParseIP("192.168.1.117"), net.ParseIP("2001:db8::1")},
	})
	if err != nil {
		t.Fatal(err)
	}
	if advertisement.InstanceName != "Songjian's MacBook Pro (b79b2d8c)" {
		t.Fatalf("instance name = %q", advertisement.InstanceName)
	}
	if advertisement.HostName != "warren-test.local." {
		t.Fatalf("host name = %q", advertisement.HostName)
	}
	joined := strings.Join(advertisement.TXT, "\n")
	for _, expected := range []string{
		"txtvers=1",
		"id=b79b2d8c-e8fd-438b-9e52-60e881c3cffb",
		"name=Songjian's MacBook Pro",
		"ver=4.0",
		"build=dev-build",
		"tls=1",
		"pair=1",
		"cand=192.168.1.117:8789,[2001:db8::1]:8789",
	} {
		if !strings.Contains(joined, expected) {
			t.Fatalf("TXT %q missing %q", joined, expected)
		}
	}
	if strings.Contains(joined, "token") || strings.Contains(joined, "secret") {
		t.Fatalf("TXT contains credential-like data: %q", joined)
	}
}

func TestBuildAdvertisementRejectsMissingAddresses(t *testing.T) {
	_, err := BuildAdvertisement(Config{HostID: "host", HostName: "Mac", Port: 8789})
	if err == nil || !strings.Contains(err.Error(), "network addresses") {
		t.Fatalf("error = %v, want missing address error", err)
	}
}

func TestBuildAdvertisementChunksLargeCandidateLists(t *testing.T) {
	input := make([]net.IP, 0, 32)
	for index := 1; index <= 32; index++ {
		input = append(input, net.ParseIP(fmt.Sprintf("2001:db8::%x", index)))
	}

	advertisement, err := BuildAdvertisement(Config{
		HostID:     "host",
		HostName:   "Warren",
		Port:       8789,
		Candidates: input,
	})
	if err != nil {
		t.Fatal(err)
	}

	var chunks []string
	for _, value := range advertisement.TXT {
		if !strings.HasPrefix(value, "cand") {
			continue
		}
		if len(value) > maxDNSTXTStringBytes {
			t.Fatalf("candidate TXT entry is %d bytes: %q", len(value), value)
		}
		chunks = append(chunks, value)
	}
	if len(chunks) < 2 {
		t.Fatalf("candidate TXT entries = %v, want multiple chunks", chunks)
	}

	var got []string
	for _, chunk := range chunks {
		parts := strings.SplitN(chunk, "=", 2)
		if len(parts) != 2 {
			t.Fatalf("candidate TXT entry %q has no value", chunk)
		}
		got = append(got, strings.Split(parts[1], ",")...)
	}
	want := candidateAddresses(normalizeIPs(input), 8789)
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Fatalf("candidate TXT values = %v, want %v", got, want)
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
		t.Fatal(err)
	}
	records := service.Records(dns.Question{
		Name:  "_warren._tcp.local.",
		Qtype: dns.TypePTR,
	})
	if _, err := (&dns.Msg{Answer: records}).Pack(); err != nil {
		t.Fatalf("mDNS PTR response could not be packed: %v", err)
	}
}

func TestBuildAdvertisementNormalizesDNSHostName(t *testing.T) {
	for _, test := range []struct {
		name string
		want string
	}{
		{name: "warren-test", want: "warren-test.local."},
		{name: "warren-test.local", want: "warren-test.local."},
		{name: "warren-test.local.", want: "warren-test.local."},
		{name: "warren-test.example.com", want: "warren-test.example.com."},
	} {
		t.Run(test.name, func(t *testing.T) {
			advertisement, err := BuildAdvertisement(Config{
				HostID:      "host",
				HostName:    "Warren",
				DNSHostName: test.name,
				Port:        8789,
				Candidates:  []net.IP{net.ParseIP("192.168.1.10")},
			})
			if err != nil {
				t.Fatal(err)
			}
			if advertisement.HostName != test.want {
				t.Fatalf("host name = %q, want %q", advertisement.HostName, test.want)
			}
		})
	}
}

func TestFilterForListenerDoesNotAdvertiseUnreachableAddresses(t *testing.T) {
	candidates := []net.IP{
		net.ParseIP("192.168.1.10"),
		net.ParseIP("10.0.0.4"),
	}
	if got := FilterForListener(candidates, "127.0.0.1:8789"); len(got) != 0 {
		t.Fatalf("loopback listener candidates = %v, want none", got)
	}
	if got := FilterForListener(candidates, "192.168.1.10:8789"); len(got) != 1 || !got[0].Equal(net.ParseIP("192.168.1.10")) {
		t.Fatalf("specific listener candidates = %v, want 192.168.1.10", got)
	}
	if got := FilterForListener(candidates, "0.0.0.0:8789"); len(got) != 2 {
		t.Fatalf("wildcard listener candidates = %v, want both addresses", got)
	}
}

func TestLocalAddressesDoNotIncludeLoopback(t *testing.T) {
	addresses, err := LocalAddresses()
	if err != nil {
		t.Fatal(err)
	}
	for _, address := range addresses {
		if address.IsLoopback() || address.IsUnspecified() || address.IsMulticast() {
			t.Fatalf("invalid local address %s", address)
		}
	}
}
