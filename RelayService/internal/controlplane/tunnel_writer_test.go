package controlplane

import "testing"

func TestTunnelWriterReservesControlLane(t *testing.T) {
	writer := &tunnelWriter{
		control: make(chan tunnelQueuedWrite, tunnelControlQueueCapacity),
		data:    make(chan tunnelQueuedWrite, tunnelDataQueueCapacity),
		stop:    make(chan struct{}),
		stopped: make(chan struct{}),
	}
	for index := 0; index < tunnelDataQueueCapacity; index++ {
		if err := writer.enqueue(tunnelQueuedWrite{done: make(chan error, 1)}, false); err != nil {
			t.Fatalf("data enqueue %d: %v", index, err)
		}
	}
	if err := writer.enqueue(tunnelQueuedWrite{done: make(chan error, 1)}, false); err == nil {
		t.Fatal("data queue accepted an item beyond its bound")
	}
	if err := writer.enqueue(tunnelQueuedWrite{done: make(chan error, 1)}, true); err != nil {
		t.Fatalf("control lane was starved by data: %v", err)
	}
	writer.stopWith(nil)
}
