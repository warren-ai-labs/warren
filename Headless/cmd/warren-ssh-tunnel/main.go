package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"strings"
	"syscall"

	"github.com/abcdlsj/warren/Headless/internal/sshclient"
)

var version = "dev"

type event struct {
	Type  string `json:"type"`
	URL   string `json:"url,omitempty"`
	Token string `json:"token,omitempty"`
	Error string `json:"error,omitempty"`
}

type command struct {
	Type string `json:"type"`
}

func main() {
	if err := run(os.Args[1:]); err != nil {
		_ = writeEvent(event{Type: "error", Error: err.Error()})
		os.Exit(1)
	}
}

func run(args []string) error {
	flags := flag.NewFlagSet("warren-ssh-tunnel", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	target := flags.String("target", "", "SSH target or alias")
	remote := flags.String("remote", "127.0.0.1:8789", "remote Warren address")
	local := flags.String("listen", "127.0.0.1:0", "local loopback address")
	sshConfig := flags.String("ssh-config", "", "SSH config path")
	knownHosts := flags.String("known-hosts", "", "known_hosts path")
	identity := stringList{}
	flags.Var(&identity, "identity-file", "SSH identity file (repeatable)")
	showVersion := flags.Bool("version", false, "print version")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if *showVersion {
		fmt.Println(version)
		return nil
	}
	if strings.TrimSpace(*target) == "" {
		return errors.New("missing --target")
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	tunnel, ready, err := sshclient.Start(ctx, sshclient.Options{
		Target:         *target,
		RemoteAddress:  *remote,
		LocalAddress:   *local,
		SSHConfigPath:  *sshConfig,
		KnownHostsPath: *knownHosts,
		IdentityFiles:  identity,
	})
	if err != nil {
		return err
	}
	defer tunnel.Close()
	if err := writeEvent(event{Type: "ready", URL: ready.URL, Token: ready.Token}); err != nil {
		return err
	}

	commands := make(chan command, 1)
	go readCommands(os.Stdin, commands)
	select {
	case <-ctx.Done():
		_ = writeEvent(event{Type: "closed"})
		return nil
	case <-tunnel.Done():
		_ = writeEvent(event{Type: "closed"})
		return nil
	case request := <-commands:
		if request.Type != "" && request.Type != "stop" {
			return fmt.Errorf("unknown command %q", request.Type)
		}
		_ = writeEvent(event{Type: "closed"})
		return nil
	}
}

func readCommands(reader io.Reader, commands chan<- command) {
	scanner := bufio.NewScanner(reader)
	for scanner.Scan() {
		var request command
		if json.Unmarshal(scanner.Bytes(), &request) == nil {
			commands <- request
			return
		}
	}
	// EOF is the parent's normal shutdown signal.
	commands <- command{Type: "stop"}
}

func writeEvent(value event) error {
	return json.NewEncoder(os.Stdout).Encode(value)
}

type stringList []string

func (values *stringList) String() string { return strings.Join(*values, ",") }

func (values *stringList) Set(value string) error {
	*values = append(*values, value)
	return nil
}
