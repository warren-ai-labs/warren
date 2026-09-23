package discovery

import (
	"context"
	"errors"
	"net"
	"sync"
	"testing"
	"time"
)

// fakeAdvertiser records the advertisements a Supervisor publishes and how often
// each one was stopped, so a test can prove that unchanged addresses are left
// alone and changed addresses replace the running responder.
type fakeAdvertiser struct {
	mu        sync.Mutex
	published []Config
	stopped   int
	fail      error
}

func (fake *fakeAdvertiser) publish(config Config) (func() error, error) {
	fake.mu.Lock()
	fake.published = append(fake.published, config)
	fail := fake.fail
	fake.mu.Unlock()
	if fail != nil {
		return nil, fail
	}
	return func() error {
		fake.mu.Lock()
		fake.stopped++
		fake.mu.Unlock()
		return nil
	}, nil
}

func (fake *fakeAdvertiser) snapshot() ([]Config, int) {
	fake.mu.Lock()
	defer fake.mu.Unlock()
	return append([]Config(nil), fake.published...), fake.stopped
}

func supervisorConfig(fake *fakeAdvertiser, addresses func() []net.IP) SupervisorConfig {
	return SupervisorConfig{
		Advertisement: Config{HostID: "host", HostName: "Warren", DNSHostName: "warren-test", Port: 8789},
		Addresses: func() ([]net.IP, error) {
			return addresses(), nil
		},
		Publish: fake.publish,
	}
}

func fixedAddresses(values ...net.IP) func() []net.IP {
	return func() []net.IP { return values }
}

func TestSupervisorPublishesOncePerCandidateSet(t *testing.T) {
	fake := &fakeAdvertiser{}
	config := supervisorConfig(fake, fixedAddresses(net.ParseIP("192.168.1.10")))
	supervisor := NewSupervisor(config)

	if !supervisor.Refresh() {
		t.Fatal("first Refresh did not publish")
	}
	if supervisor.Refresh() {
		t.Fatal("unchanged addresses republished")
	}
	published, stopped := fake.snapshot()
	if len(published) != 1 || stopped != 0 {
		t.Fatalf("published = %d, stopped = %d, want 1 and 0", len(published), stopped)
	}
	if len(published[0].Candidates) != 1 || !published[0].Candidates[0].Equal(net.ParseIP("192.168.1.10")) {
		t.Fatalf("candidates = %v", published[0].Candidates)
	}
}

func TestSupervisorRepublishesWhenAddressesChange(t *testing.T) {
	fake := &fakeAdvertiser{}
	addresses := []net.IP{net.ParseIP("192.168.1.10")}
	config := supervisorConfig(fake, func() []net.IP { return addresses })
	supervisor := NewSupervisor(config)
	if !supervisor.Refresh() {
		t.Fatal("first Refresh did not publish")
	}

	// A new DHCP lease replaces the previous responder instead of leaving a
	// record that points at the address this machine no longer holds.
	addresses = []net.IP{net.ParseIP("10.23.138.75"), net.ParseIP("192.168.139.3")}
	if !supervisor.Refresh() {
		t.Fatal("changed addresses did not republish")
	}
	published, stopped := fake.snapshot()
	if len(published) != 2 || stopped != 1 {
		t.Fatalf("published = %d, stopped = %d, want 2 and 1", len(published), stopped)
	}
	if len(published[1].Candidates) != 2 {
		t.Fatalf("candidates = %v, want the new address set", published[1].Candidates)
	}
	if supervisor.Refresh() {
		t.Fatal("unchanged addresses republished")
	}
}

func TestSupervisorStopsAdvertisingWithoutCandidates(t *testing.T) {
	fake := &fakeAdvertiser{}
	addresses := []net.IP{net.ParseIP("192.168.1.10")}
	config := supervisorConfig(fake, func() []net.IP { return addresses })
	supervisor := NewSupervisor(config)
	if !supervisor.Refresh() {
		t.Fatal("first Refresh did not publish")
	}

	addresses = nil
	if supervisor.Refresh() {
		t.Fatal("Refresh published without candidates")
	}
	published, stopped := fake.snapshot()
	if len(published) != 1 || stopped != 1 {
		t.Fatalf("published = %d, stopped = %d, want 1 and 1", len(published), stopped)
	}

	addresses = []net.IP{net.ParseIP("10.0.0.4")}
	if !supervisor.Refresh() {
		t.Fatal("candidates did not restart the advertisement")
	}
	if published, stopped = fake.snapshot(); len(published) != 2 || stopped != 1 {
		t.Fatalf("published = %d, stopped = %d, want 2 and 1", len(published), stopped)
	}
	supervisor.Stop()
	if _, stopped = fake.snapshot(); stopped != 2 {
		t.Fatalf("stopped = %d, want the final responder stopped", stopped)
	}
	supervisor.Stop()
	if _, stopped = fake.snapshot(); stopped != 2 {
		t.Fatalf("stopped = %d, want Stop to be idempotent", stopped)
	}
}

func TestSupervisorKeepsAdvertisingWhenPublishFails(t *testing.T) {
	fake := &fakeAdvertiser{fail: errors.New("no multicast socket")}
	supervisor := NewSupervisor(supervisorConfig(fake, fixedAddresses(net.ParseIP("192.168.1.10"))))

	if supervisor.Refresh() {
		t.Fatal("failing publish reported success")
	}
	fake.fail = nil
	if !supervisor.Refresh() {
		t.Fatal("Refresh did not retry after a failing publish")
	}
	supervisor.Stop()
}

func TestSupervisorSkipsAddressesTheListenerCannotServe(t *testing.T) {
	fake := &fakeAdvertiser{}
	config := supervisorConfig(fake, fixedAddresses(net.ParseIP("192.168.1.10")))
	config.Addresses = nil
	config.ListenerAddress = "127.0.0.1:8789"
	supervisor := NewSupervisor(config)

	if supervisor.Refresh() {
		t.Fatal("loopback listener published an advertisement")
	}
	if published, _ := fake.snapshot(); len(published) != 0 {
		t.Fatalf("published = %d, want none", len(published))
	}
}

func TestSupervisorRunRefreshesUntilCancelled(t *testing.T) {
	fake := &fakeAdvertiser{}
	var (
		mu        sync.Mutex
		addresses = []net.IP{net.ParseIP("192.168.1.10")}
	)
	config := supervisorConfig(fake, func() []net.IP {
		mu.Lock()
		defer mu.Unlock()
		return append([]net.IP(nil), addresses...)
	})
	config.Interval = time.Millisecond
	supervisor := NewSupervisor(config)

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		supervisor.Run(ctx)
		close(done)
	}()
	deadline := time.Now().Add(2 * time.Second)
	for {
		published, _ := fake.snapshot()
		if len(published) > 0 {
			break
		}
		if time.Now().After(deadline) {
			cancel()
			t.Fatal("Run never refreshed")
		}
		time.Sleep(time.Millisecond)
	}
	mu.Lock()
	addresses = []net.IP{net.ParseIP("10.0.0.4")}
	mu.Unlock()
	for {
		published, _ := fake.snapshot()
		if len(published) > 1 {
			break
		}
		if time.Now().After(deadline) {
			cancel()
			t.Fatal("Run never republished changed addresses")
		}
		time.Sleep(time.Millisecond)
	}
	cancel()
	<-done
}
