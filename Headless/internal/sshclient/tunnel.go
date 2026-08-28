package sshclient

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"

	"golang.org/x/crypto/ssh"
	"golang.org/x/crypto/ssh/agent"
	"golang.org/x/crypto/ssh/knownhosts"
)

const defaultRemoteAddress = "127.0.0.1:8789"

var tokenPattern = regexp.MustCompile(`^[A-Za-z0-9_-]{32,}$`)

// Options controls one embedded SSH forwarding connection.
type Options struct {
	Target         string
	RemoteAddress  string
	LocalAddress   string
	SSHConfigPath  string
	KnownHostsPath string
	IdentityFiles  []string
	ConnectTimeout time.Duration
}

// Ready is the local endpoint returned after the remote daemon is reachable.
type Ready struct {
	URL   string
	Token string
}

// Tunnel owns one SSH connection and its loopback forwarding listener.
type Tunnel struct {
	client       *ssh.Client
	listener     net.Listener
	done         chan struct{}
	shutdownOnce sync.Once
	wg           sync.WaitGroup
	connections  map[net.Conn]struct{}
	connectionMu sync.Mutex
}

// Start resolves the user's SSH configuration, authenticates, bootstraps the
// remote Warren daemon, and starts a loopback TCP forwarder.
func Start(ctx context.Context, options Options) (*Tunnel, Ready, error) {
	if options.RemoteAddress == "" {
		options.RemoteAddress = defaultRemoteAddress
	}
	if options.LocalAddress == "" {
		options.LocalAddress = "127.0.0.1:0"
	}
	if options.ConnectTimeout <= 0 {
		options.ConnectTimeout = 15 * time.Second
	}
	if err := validateLoopbackAddress(options.LocalAddress); err != nil {
		return nil, Ready{}, err
	}
	if _, _, err := splitAddress(options.RemoteAddress); err != nil {
		return nil, Ready{}, err
	}
	host, err := resolveHost(options.Target, options.SSHConfigPath)
	if err != nil {
		return nil, Ready{}, err
	}
	if options.KnownHostsPath != "" {
		path := expandSSHPath(options.KnownHostsPath, host)
		host.KnownHosts = path
		host.KnownHostsFiles = []string{path}
	}
	if len(options.IdentityFiles) > 0 {
		host.IdentityFile = make([]string, 0, len(options.IdentityFiles))
		for _, identity := range options.IdentityFiles {
			host.IdentityFile = append(host.IdentityFile, expandSSHPath(identity, host))
		}
	}
	config, closeAgent, err := clientConfig(host, options.ConnectTimeout)
	if err != nil {
		return nil, Ready{}, err
	}
	defer closeAgent()

	address := net.JoinHostPort(host.Host, fmt.Sprintf("%d", host.Port))
	dialer := net.Dialer{Timeout: options.ConnectTimeout}
	connection, err := dialer.DialContext(ctx, "tcp", address)
	if err != nil {
		return nil, Ready{}, fmt.Errorf("connect SSH host %s: %w", address, err)
	}
	clientConn, channels, requests, err := ssh.NewClientConn(connection, address, config)
	if err != nil {
		connection.Close()
		if isHostKeyMismatch(err) {
			return nil, Ready{}, fmt.Errorf("SSH host key verification failed for %s: %w; the remote host key does not match known_hosts (check 'ssh-keygen -F %s' or remove the stale entry)", address, err, host.Host)
		}
		return nil, Ready{}, fmt.Errorf("authenticate SSH host %s: %w", address, err)
	}
	client := ssh.NewClient(clientConn, channels, requests)
	token, err := bootstrap(ctx, client, options.RemoteAddress)
	if err != nil {
		client.Close()
		return nil, Ready{}, err
	}
	listener, err := net.Listen("tcp", options.LocalAddress)
	if err != nil {
		client.Close()
		return nil, Ready{}, fmt.Errorf("listen for local SSH tunnel: %w", err)
	}
	tunnel := &Tunnel{
		client:      client,
		listener:    listener,
		done:        make(chan struct{}),
		connections: make(map[net.Conn]struct{}),
	}
	tunnel.wg.Add(2)
	go tunnel.acceptLoop(options.RemoteAddress)
	go tunnel.monitorClient()
	return tunnel, Ready{
		URL:   "http://" + listener.Addr().String(),
		Token: token,
	}, nil
}

// Addr returns the loopback listener address.
func (t *Tunnel) Addr() net.Addr { return t.listener.Addr() }

// Done is closed when the tunnel is stopped.
func (t *Tunnel) Done() <-chan struct{} { return t.done }

// Close stops forwarding and releases the SSH connection.
func (t *Tunnel) Close() error {
	if t == nil {
		return nil
	}
	err := t.shutdown()
	t.wg.Wait()
	return err
}

func (t *Tunnel) shutdown() (err error) {
	t.shutdownOnce.Do(func() {
		close(t.done)
		err = t.listener.Close()
		_ = t.client.Close()
		t.connectionMu.Lock()
		take := make([]net.Conn, 0, len(t.connections))
		for connection := range t.connections {
			take = append(take, connection)
		}
		t.connections = nil
		t.connectionMu.Unlock()
		for _, connection := range take {
			_ = connection.Close()
		}
	})
	return err
}

func (t *Tunnel) acceptLoop(remoteAddress string) {
	defer t.wg.Done()
	for {
		connection, err := t.listener.Accept()
		if err != nil {
			select {
			case <-t.done:
				return
			default:
			}
			continue
		}
		if !t.trackConnection(connection) {
			_ = connection.Close()
			return
		}
		remote, err := t.client.Dial("tcp", remoteAddress)
		if err != nil {
			t.untrackConnection(connection)
			_ = connection.Close()
			select {
			case <-t.done:
				return
			default:
			}
			continue
		}
		if !t.trackConnection(remote) {
			t.untrackConnection(connection)
			_ = connection.Close()
			_ = remote.Close()
			return
		}
		t.wg.Add(1)
		go func(local, upstream net.Conn) {
			defer t.wg.Done()
			defer t.untrackConnection(local)
			defer t.untrackConnection(upstream)
			defer local.Close()
			defer upstream.Close()
			proxy(local, upstream)
		}(connection, remote)
	}
}

func (t *Tunnel) monitorClient() {
	defer t.wg.Done()
	_ = t.client.Wait()
	_ = t.shutdown()
}

func (t *Tunnel) trackConnection(connection net.Conn) bool {
	t.connectionMu.Lock()
	defer t.connectionMu.Unlock()
	if t.connections == nil {
		return false
	}
	t.connections[connection] = struct{}{}
	return true
}

func (t *Tunnel) untrackConnection(connection net.Conn) {
	t.connectionMu.Lock()
	delete(t.connections, connection)
	t.connectionMu.Unlock()
}

func proxy(local, remote net.Conn) {
	var once sync.Once
	closeBoth := func() { once.Do(func() { _ = local.Close(); _ = remote.Close() }) }
	var wg sync.WaitGroup
	wg.Add(2)
	go func() { defer wg.Done(); _, _ = io.Copy(remote, local); closeBoth() }()
	go func() { defer wg.Done(); _, _ = io.Copy(local, remote); closeBoth() }()
	wg.Wait()
}

func clientConfig(host HostConfig, timeout time.Duration) (*ssh.ClientConfig, func(), error) {
	paths := host.KnownHostsFiles
	if len(paths) == 0 && host.KnownHosts != "" {
		paths = []string{host.KnownHosts}
	}
	callback, err := knownHostCallback(paths...)
	if err != nil {
		return nil, func() {}, err
	}
	auth, closeAgent, err := authMethods(host.IdentityFile, host.IdentitiesOnly)
	if err != nil {
		closeAgent()
		return nil, func() {}, err
	}
	if len(auth) == 0 {
		closeAgent()
		return nil, func() {}, errors.New("no SSH authentication method available; start ssh-agent (ssh-add ~/.ssh/id_ed25519) or configure IdentityFile in ~/.ssh/config")
	}
	return &ssh.ClientConfig{
		User:            host.User,
		Auth:            auth,
		HostKeyCallback: callback,
		Timeout:         timeout,
	}, closeAgent, nil
}

func knownHostCallback(paths ...string) (ssh.HostKeyCallback, error) {
	unique := make([]string, 0, len(paths))
	seen := make(map[string]struct{}, len(paths))
	requested := make([]string, 0, len(paths))
	for _, path := range paths {
		path = strings.TrimSpace(path)
		if path == "" {
			continue
		}
		if _, ok := seen[path]; ok {
			continue
		}
		seen[path] = struct{}{}
		requested = append(requested, path)
		if _, err := os.Stat(path); err != nil {
			if os.IsNotExist(err) {
				continue
			}
			return nil, fmt.Errorf("stat SSH known_hosts %s: %w", path, err)
		}
		unique = append(unique, path)
	}
	if len(unique) == 0 {
		if len(requested) == 0 {
			return nil, errors.New("SSH known_hosts path is empty")
		}
		return nil, fmt.Errorf("SSH known_hosts file not found: %s; run 'ssh %s' once to verify the host key, or add it with 'ssh-keyscan -H <host> >> ~/.ssh/known_hosts'", strings.Join(requested, ", "), hostForKnownHostsHint(requested))
	}
	callback, err := knownhosts.New(unique...)
	if err != nil {
		return nil, fmt.Errorf("load SSH known_hosts %s: %w (if the host key changed, remove the old entry from known_hosts or verify with 'ssh-keygen -F <host>')", strings.Join(unique, ", "), err)
	}
	return callback, nil
}

func hostForKnownHostsHint(paths []string) string {
	if len(paths) == 0 {
		return "<host>"
	}
	// Use the first requested path's host hint – the connection error already
	// contains the dial address, so a generic placeholder is sufficient here.
	_ = paths
	return "<host>"
}

func isHostKeyMismatch(err error) bool {
	msg := strings.ToLower(err.Error())
	return strings.Contains(msg, "knownhosts") || strings.Contains(msg, "host key") || strings.Contains(msg, "key mismatch")
}

func authMethods(identityFiles []string, identitiesOnly bool) ([]ssh.AuthMethod, func(), error) {
	methods := make([]ssh.AuthMethod, 0, 2)
	closeAgent := func() {}
	if !identitiesOnly {
		if socket := strings.TrimSpace(os.Getenv("SSH_AUTH_SOCK")); socket != "" {
			connection, err := net.DialTimeout("unix", socket, 2*time.Second)
			if err == nil {
				agentClient := agent.NewClient(connection)
				if signers, signersErr := agentClient.Signers(); signersErr == nil && len(signers) > 0 {
					methods = append(methods, ssh.PublicKeys(signers...))
					closeAgent = func() { _ = connection.Close() }
				} else {
					_ = connection.Close()
				}
			}
		}
	}
	for _, path := range identityFiles {
		path = strings.TrimSpace(path)
		if path == "" {
			continue
		}
		data, err := os.ReadFile(path)
		if err != nil {
			if os.IsNotExist(err) {
				continue
			}
			return nil, closeAgent, fmt.Errorf("read SSH identity %s: %w", path, err)
		}
		signer, err := ssh.ParsePrivateKey(data)
		if err != nil {
			var encrypted *ssh.PassphraseMissingError
			if errors.As(err, &encrypted) {
				if len(methods) > 0 {
					// ssh-agent already supplies a usable signer; do not make an
					// encrypted on-disk key block an otherwise valid connection.
					continue
				}
				return nil, closeAgent, fmt.Errorf("SSH identity %s is encrypted; add it to ssh-agent with 'ssh-add %s'", path, path)
			}
			return nil, closeAgent, fmt.Errorf("parse SSH identity %s: %w", path, err)
		}
		methods = append(methods, ssh.PublicKeys(signer))
	}
	return methods, closeAgent, nil
}

const bootstrapTemplate = `command -v warren-headless >/dev/null || { echo 'warren-headless is not installed' >&2; exit 127; }; mkdir -p ~/.warren; daemon_ready() { if command -v curl >/dev/null 2>&1; then curl -fsS --max-time 2 http://127.0.0.1:%s/healthz >/dev/null 2>&1; else test -s ~/.warren/token; fi; }; (daemon_ready || nohup warren-headless --listen 127.0.0.1:%s --lan-https '' > ~/.warren/headless.log 2>&1 &); i=0; while [ "$i" -lt 50 ]; do if test -s ~/.warren/token && daemon_ready; then cat ~/.warren/token; exit 0; fi; i=$((i + 1)); sleep 0.1; done; echo 'Warren daemon did not become ready' >&2; exit 1`

func bootstrap(ctx context.Context, client *ssh.Client, remoteAddress string) (string, error) {
	_, port, err := splitAddress(remoteAddress)
	if err != nil {
		return "", err
	}
	session, err := client.NewSession()
	if err != nil {
		return "", fmt.Errorf("open remote Warren bootstrap session: %w", err)
	}
	defer session.Close()
	var stdout, stderr bytes.Buffer
	session.Stdout = &stdout
	session.Stderr = &stderr
	if err := session.Start(fmt.Sprintf(bootstrapTemplate, port, port)); err != nil {
		return "", fmt.Errorf("start remote Warren bootstrap: %w", err)
	}
	wait := make(chan error, 1)
	go func() { wait <- session.Wait() }()
	select {
	case err = <-wait:
		if err != nil {
			detail := strings.TrimSpace(strings.Join([]string{
				strings.TrimSpace(stderr.String()),
				strings.TrimSpace(stdout.String()),
			}, "\n"))
			if len(detail) > 1024 {
				detail = detail[len(detail)-1024:]
			}
			if detail == "" {
				return "", fmt.Errorf("bootstrap remote Warren daemon: %w", err)
			}
			return "", fmt.Errorf("bootstrap remote Warren daemon: %s: %w", detail, err)
		}
	case <-ctx.Done():
		_ = session.Close()
		<-wait
		return "", ctx.Err()
	}
	token := lastNonEmptyLine(stdout.String())
	if !validateToken(token) {
		return "", fmt.Errorf("remote Warren returned an invalid token")
	}
	return token, nil
}

func splitAddress(address string) (string, string, error) {
	host, port, err := net.SplitHostPort(address)
	if err != nil {
		return "", "", fmt.Errorf("invalid SSH tunnel address %q: %w", address, err)
	}
	parsed, err := strconv.Atoi(port)
	if err != nil || parsed < 1 || parsed > 65535 {
		return "", "", fmt.Errorf("invalid SSH tunnel port %q", port)
	}
	return host, port, nil
}

func validateLoopbackAddress(address string) error {
	host, _, err := net.SplitHostPort(address)
	if err != nil {
		return fmt.Errorf("invalid local SSH tunnel address %q: %w", address, err)
	}
	if host == "localhost" {
		return nil
	}
	ip := net.ParseIP(host)
	if ip == nil || !ip.IsLoopback() {
		return fmt.Errorf("local SSH tunnel must bind to loopback, got %q", address)
	}
	return nil
}

func lastNonEmptyLine(value string) string {
	lines := strings.Split(value, "\n")
	for index := len(lines) - 1; index >= 0; index-- {
		line := strings.TrimSpace(lines[index])
		if line != "" {
			return line
		}
	}
	return ""
}

// validateToken is kept small and local so protocol tests can exercise token
// handling without creating a real SSH connection.
func validateToken(token string) bool {
	if !tokenPattern.MatchString(token) {
		return false
	}
	if _, err := hex.DecodeString(token); err == nil && len(token)%2 == 0 {
		return true
	}
	decoded, err := base64.RawURLEncoding.DecodeString(token)
	return err == nil && len(decoded) == 32
}
