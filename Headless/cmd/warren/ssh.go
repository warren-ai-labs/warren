package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"strconv"
	"strings"
	"syscall"

	"github.com/abcdlsj/warren/Headless/internal/config"
	"github.com/abcdlsj/warren/Headless/internal/sshclient"
)

func sshCommand(args []string) error {
	if len(args) >= 1 && isHelpArgument(args[0]) {
		fmt.Print(sshUsageText())
		return nil
	}
	if len(args) >= 1 && args[0] == "list" {
		flags := parseFlags(args[1:])
		if boolValue(flags, "help") || boolValue(flags, "h") {
			fmt.Print(sshUsageText())
			return nil
		}
		if len(positionals(flags)) > 1 {
			return newUsageError("ssh list accepts at most one pattern", sshUsageText())
		}
		searchPattern := ""
		if len(positionals(flags)) == 1 {
			searchPattern = positionals(flags)[0]
		}
		if s := stringValue(flags, "search"); s != "" {
			searchPattern = s
		}
		searchPattern = strings.ToLower(strings.TrimSpace(searchPattern))
		entries, err := sshclient.ListHosts(stringValue(flags, "ssh-config"))
		if err != nil {
			return err
		}
		rows := make([]sshHostRow, 0, len(entries))
		for _, entry := range entries {
			if searchPattern != "" {
				if !strings.Contains(strings.ToLower(entry.Name), searchPattern) &&
					!strings.Contains(strings.ToLower(entry.Config.Host), searchPattern) &&
					!strings.Contains(strings.ToLower(entry.Config.User), searchPattern) {
					continue
				}
			}
			rows = append(rows, sshHostRow{
				Name:          entry.Name,
				Host:          entry.Config.Host,
				User:          entry.Config.User,
				Port:          entry.Config.Port,
				IdentityFiles: len(entry.Config.IdentityFile),
				Error:         entry.Error,
			})
		}
		if value, specified := flags["limit"]; specified {
			limit, err := strconv.Atoi(fmt.Sprint(value))
			if err != nil || limit <= 0 {
				return newUsageError("--limit must be a positive integer", sshUsageText())
			}
			rows = limitListRows(rows, limit)
		}
		return printValue(rows)
	}
	flags := parseFlags(args)
	if boolValue(flags, "help") || boolValue(flags, "h") {
		fmt.Print(sshUsageText())
		return nil
	}
	if label := missingPositional(flags, []string{"SSH_TARGET"}); label != "" {
		return newUsageError("missing "+label, sshUsageText())
	}
	if len(positionals(flags)) > 1 {
		return newUsageError("ssh accepts exactly one target", sshUsageText())
	}
	target := positional(flags, 0, "SSH target")
	// Use an ephemeral loopback port by default so a local daemon on 8789 and
	// multiple SSH-backed endpoints can coexist without manual coordination.
	localPort := stringValueDefault(flags, "local-port", "0")
	remotePort := stringValueDefault(flags, "remote-port", "8789")
	name := stringValueDefault(flags, "name", strings.NewReplacer("@", "-", ":", "-").Replace(target))
	if name == "local" {
		return newUsageError("local is reserved for the local daemon; choose another --name", sshUsageText())
	}
	localAddress := localPort
	if !strings.Contains(localAddress, ":") {
		localAddress = "127.0.0.1:" + localAddress
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	tunnel, ready, err := sshclient.Start(ctx, sshclient.Options{
		Target:         target,
		RemoteAddress:  "127.0.0.1:" + remotePort,
		LocalAddress:   localAddress,
		SSHConfigPath:  stringValue(flags, "ssh-config"),
		KnownHostsPath: stringValue(flags, "known-hosts"),
	})
	if err != nil {
		return err
	}
	defer tunnel.Close()
	if err := config.Update(configPath, func(settings *config.Config) error {
		// Do not persist the helper's ephemeral listener or token. Persisting
		// either value makes a later process reuse a dead tunnel and can leak
		// credentials to unrelated Desktop/CLI instances.
		settings.Endpoints[name] = config.Endpoint{Name: name, SSH: target, SSHRemote: "127.0.0.1:" + remotePort}
		settings.Current = name
		if settings.Display != nil {
			return normalizeConfiguredDisplay(settings)
		}
		return nil
	}); err != nil {
		return err
	}
	fmt.Fprintf(os.Stderr, "Warren endpoint %q active at %s; keep this process running.\n", name, ready.URL)
	select {
	case <-ctx.Done():
		return nil
	case <-tunnel.Done():
		return errors.New("SSH tunnel stopped unexpectedly")
	}
}

func headlessCommand(args []string) error {
	binary, err := exec.LookPath("warren-headless")
	if err != nil {
		return errors.New("warren-headless is not installed")
	}
	command := exec.Command(binary, args...)
	command.Stdin = os.Stdin
	command.Stdout = os.Stdout
	command.Stderr = os.Stderr
	return command.Run()
}
