package programstatus

import (
	"bytes"
	"testing"
)

// The scanner runs on every Session's output batch, so a plain batch has to
// stay cheap: no copy, no allocation.
func plainOutputBatch() []byte {
	var batch bytes.Buffer
	for batch.Len() < 32*1024 {
		batch.WriteString("make: building target widget-0123 ... ok\n")
	}
	return batch.Bytes()
}

func BenchmarkScannerFeedPlainOutput(b *testing.B) {
	batch := plainOutputBatch()
	b.SetBytes(int64(len(batch)))
	b.ReportAllocs()
	scanner := Scanner{}
	for i := 0; i < b.N; i++ {
		scanner.Feed(batch)
	}
}

func BenchmarkScannerFeedReportBatch(b *testing.B) {
	batch := append(plainOutputBatch(), []byte("\x1b]7501;state=working:app=make\x1b\\")...)
	b.SetBytes(int64(len(batch)))
	b.ReportAllocs()
	scanner := Scanner{}
	for i := 0; i < b.N; i++ {
		scanner.Feed(batch)
	}
}
