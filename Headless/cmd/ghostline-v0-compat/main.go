// ghostline-v0-compat is the temporary v0.8 bridge used only to hand an
// existing Warren-owned v0 daemon to Ghostline v1.
package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"

	"github.com/abcdlsj/ghostline"
)

func main() {
	if len(os.Args) < 2 || os.Args[1] != "serve" {
		fmt.Fprintln(os.Stderr, "usage: ghostline-v0-compat serve --socket <path> [--output-dir <dir>] [--adopt-from <admin-socket>] [--probe-foreground]")
		os.Exit(2)
	}
	serve(os.Args[2:])
}

func serve(arguments []string) {
	flags := flag.NewFlagSet("serve", flag.ExitOnError)
	socketPath := flags.String("socket", "", "unix socket path (required)")
	outputDir := flags.String("output-dir", "", "durable output directory")
	adoptFrom := flags.String("adopt-from", "", "source admin socket")
	probeForeground := flags.Bool("probe-foreground", false, "probe foreground process metadata")
	_ = flags.Parse(arguments)
	if *socketPath == "" {
		fmt.Fprintln(os.Stderr, "ghostline-v0-compat serve: --socket is required")
		os.Exit(2)
	}
	if *outputDir == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			fmt.Fprintln(os.Stderr, "ghostline-v0-compat serve: resolve home:", err)
			os.Exit(1)
		}
		*outputDir = filepath.Join(home, ".ghostline", "output")
	}

	server, err := ghostline.NewServer(ghostline.Options{
		OutputDir:       *outputDir,
		ProbeForeground: *probeForeground,
	})
	if err != nil {
		fmt.Fprintln(os.Stderr, "ghostline-v0-compat serve:", err)
		os.Exit(1)
	}
	if *adoptFrom != "" {
		adopted, err := server.Adopt(context.Background(), *adoptFrom)
		if err != nil {
			fmt.Fprintf(os.Stderr, "ghostline-v0-compat serve: adopt from %s: %v\n", *adoptFrom, err)
			os.Exit(1)
		}
		if adopted > 0 {
			fmt.Fprintf(os.Stderr, "ghostline-v0-compat serve: adopted %d session(s)\n", adopted)
		}
	}

	serveContext, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if err := server.Serve(serveContext, *socketPath); err != nil {
		fmt.Fprintln(os.Stderr, "ghostline-v0-compat serve:", err)
		os.Exit(1)
	}
}
