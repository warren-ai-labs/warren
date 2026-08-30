package sshclient

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"golang.org/x/crypto/ssh"
	"golang.org/x/crypto/ssh/agent"
	"golang.org/x/crypto/ssh/knownhosts"
)

const defaultRemoteAddress = "127.0.0.1:8789"

// Options controls one embedded SSH forwarding connection.
type Options struct {
	Target           string
	RemoteAddress    string
	LocalAddress     string
	SSHConfigPath    string
	KnownHostsPath   string
	IdentityFiles    []string
	ConnectTimeout   time.Duration
	BootstrapTimeout time.Duration
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
	if options.BootstrapTimeout <= 0 {
		options.BootstrapTimeout = 30 * time.Second
	}
	if err := validateLoopbackAddress(options.LocalAddress); err != nil {
		return nil, Ready{}, err
	}
	remoteHost, _, err := splitAddress(options.RemoteAddress)
	if err != nil {
		return nil, Ready{}, err
	}
	if !isLiteralLoopbackHost(remoteHost) {
		return nil, Ready{}, fmt.Errorf("remote Warren address must be loopback, got %q", options.RemoteAddress)
	}
	host, err := resolveHost(options.Target, options.SSHConfigPath)
	if err != nil {
		return nil, Ready{}, err
	}
	if options.KnownHostsPath != "" {
		path := expandSSHPath(options.KnownHostsPath, host)
		host.KnownHosts = path
		host.KnownHostsFiles = []string{path}
		host.KnownHostsDisabled = false
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
	bootstrapContext, cancelBootstrap := context.WithTimeout(ctx, options.BootstrapTimeout)
	token, err := bootstrap(bootstrapContext, client, options.RemoteAddress)
	cancelBootstrap()
	if err != nil {
		client.Close()
		return nil, Ready{}, err
	}
	listener, err := net.Listen("tcp", options.LocalAddress)
	if err != nil {
		client.Close()
		return nil, Ready{}, fmt.Errorf("listen for local SSH tunnel: %w", err)
	}
	if err := ctx.Err(); err != nil {
		_ = listener.Close()
		_ = client.Close()
		return nil, Ready{}, err
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
			// A listener can report a temporary resource error repeatedly. Back
			// off instead of spinning a CPU, but stop on permanent errors so a
			// broken forwarder cannot remain in a tight loop until shutdown.
			if networkError, ok := err.(net.Error); ok && networkError.Temporary() {
				select {
				case <-t.done:
					return
				case <-time.After(50 * time.Millisecond):
					continue
				}
			}
			// A permanent listener failure means this Tunnel can no longer
			// forward connections. Tear down the client as well so callers do not
			// retain a live-looking endpoint whose Done channel never fires.
			_ = t.shutdown()
			return
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
	if host.KnownHostsDisabled && len(paths) == 0 {
		return nil, func() {}, errors.New("SSH config disables known_hosts; strict host-key verification requires UserKnownHostsFile or --known-hosts")
	}
	callback, err := knownHostCallback(host.Host, host.HostKeyAlias, host.Port, paths...)
	if err != nil {
		return nil, func() {}, err
	}
	auth, closeAgent, err := authMethods(host.IdentityFile, host.IdentitiesOnly, host.IdentityAgent, host.AgentDisabled)
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

func knownHostCallback(host, alias string, port int, paths ...string) (ssh.HostKeyCallback, error) {
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
		hint := host
		if alias != "" {
			hint = alias
		}
		return nil, fmt.Errorf("SSH known_hosts file not found: %s; run 'ssh %s' once to verify the host key, or add it with 'ssh-keyscan -H %s >> ~/.ssh/known_hosts'", strings.Join(requested, ", "), hint, hint)
	}
	callback, err := knownhosts.New(unique...)
	if err != nil {
		hint := host
		if alias != "" {
			hint = alias
		}
		return nil, fmt.Errorf("load SSH known_hosts %s: %w (if the host key changed, remove the old entry from known_hosts or verify with 'ssh-keygen -F %s')", strings.Join(unique, ", "), err, hint)
	}
	if alias == "" {
		return callback, nil
	}
	// HostKeyAlias changes the name used for known_hosts lookup without
	// changing the network address used by the SSH handshake.
	// knownhosts.New expects the preferred address in host:port form even
	// when the SSH port is the default. Passing a bare alias makes its
	// internal SplitHostPort fail before it can match a normal (port-22)
	// known_hosts entry.
	lookupHost := net.JoinHostPort(alias, strconv.Itoa(port))
	return func(_ string, remote net.Addr, key ssh.PublicKey) error {
		return callback(lookupHost, remote, key)
	}, nil
}

func isHostKeyMismatch(err error) bool {
	msg := strings.ToLower(err.Error())
	return strings.Contains(msg, "knownhosts") || strings.Contains(msg, "host key") || strings.Contains(msg, "key mismatch")
}

func authMethods(identityFiles []string, identitiesOnly bool, identityAgent string, agentDisabled bool) ([]ssh.AuthMethod, func(), error) {
	methods := make([]ssh.AuthMethod, 0, 2)
	closeAgent := func() {}
	if !identitiesOnly && !agentDisabled {
		socket := strings.TrimSpace(identityAgent)
		if socket == "" {
			socket = strings.TrimSpace(os.Getenv("SSH_AUTH_SOCK"))
		}
		if socket != "" {
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
		if path == "" || strings.EqualFold(path, "none") {
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

const bootstrapTemplate = `token_path="${WARREN_TOKEN_FILE:-$HOME/.warren/token}"; if [ "%s" = "1" ]; then find_warren() { if command -v warren-headless >/dev/null 2>&1; then command -v warren-headless; return 0; fi; for candidate in "$HOME/.local/bin/warren-headless" "$HOME/go/bin/warren-headless" /usr/local/bin/warren-headless /usr/bin/warren-headless /bin/warren-headless /opt/homebrew/bin/warren-headless; do if [ -x "$candidate" ]; then printf '%%s' "$candidate"; return 0; fi; done; return 1; }; binary="$(find_warren)" || { echo 'warren-headless is not installed (checked PATH, ~/.local/bin, ~/go/bin, /usr/local/bin, /usr/bin, /bin, and /opt/homebrew/bin)' >&2; exit 127; }; mkdir -p "$HOME/.warren"; nohup "$binary" --listen '%s:%s' --lan-https '' --token-file "$token_path" < /dev/null > "$HOME/.warren/headless.log" 2>&1 & fi; i=0; while [ "$i" -lt 300 ]; do if [ -s "$token_path" ]; then token="$(cat "$token_path")"; compact="$(printf '%%s' "$token" | tr -d '[:space:]')"; if [ -n "$token" ] && [ "$token" = "$compact" ]; then printf '%%s\n' "$token"; exit 0; fi; fi; i=$((i + 1)); sleep 0.1; done; echo 'Warren daemon token did not become ready' >&2; exit 1`

func bootstrap(ctx context.Context, client *ssh.Client, remoteAddress string) (string, error) {
	remoteHost, port, err := splitAddress(remoteAddress)
	if err != nil {
		return "", err
	}
	startDaemon := "1"
	if remoteDaemonReady(ctx, client, remoteAddress) {
		startDaemon = "0"
	}
	session, err := client.NewSession()
	if err != nil {
		return "", fmt.Errorf("open remote Warren bootstrap session: %w", err)
	}
	defer session.Close()
	var stdout, stderr bytes.Buffer
	session.Stdout = &stdout
	session.Stderr = &stderr
	listenHost := remoteHost
	if strings.Contains(listenHost, ":") {
		listenHost = "[" + listenHost + "]"
	}
	if err := session.Start(fmt.Sprintf(bootstrapTemplate, startDaemon, listenHost, port)); err != nil {
		return "", fmt.Errorf("start remote Warren bootstrap: %w", err)
	}
	wait := make(chan error, 1)
	go func() { wait <- session.Wait() }()
	select {
	case err = <-wait:
		if err != nil {
			// Stdout is reserved for the bearer token. Never copy it into an
			// error or diagnostic, even when a remote command exits non-zero.
			detail := strings.TrimSpace(stderr.String())
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
		select {
		case <-wait:
		case <-time.After(2 * time.Second):
		}
		return "", ctx.Err()
	}
	token := lastNonEmptyLine(stdout.String())
	if !validateToken(token) {
		return "", fmt.Errorf("remote Warren returned an invalid token")
	}
	if err := waitForRemoteDaemon(ctx, client, remoteAddress, token); err != nil {
		return "", err
	}
	return token, nil
}

// remoteDaemonReady probes the SSH-side Warren health endpoint before
// bootstrapping. It avoids depending on curl and distinguishes a live Warren
// daemon from a stale token file or an unrelated process on the port.
func remoteDaemonReady(ctx context.Context, client *ssh.Client, address string) bool {
	status, err := remoteHTTPStatus(ctx, client, address, "")
	return err == nil && status == 200
}

func remoteDaemonAuthorized(ctx context.Context, client *ssh.Client, address, token string) (bool, error) {
	status, err := remoteHTTPStatus(ctx, client, address, token)
	if err != nil {
		return false, nil
	}
	if status == 401 {
		return false, errors.New("remote Warren rejected the bootstrap token")
	}
	return status == 200, nil
}

func remoteHTTPStatus(ctx context.Context, client *ssh.Client, address, token string) (int, error) {
	type probeResult struct {
		status int
		err    error
	}
	result := make(chan probeResult, 1)
	go func() {
		connection, err := client.Dial("tcp", address)
		if err != nil {
			result <- probeResult{err: err}
			return
		}
		_ = connection.SetDeadline(time.Now().Add(2 * time.Second))
		path := "/healthz"
		header := ""
		if token != "" {
			// /v1/settings is authenticated but small; avoid fetching the full
			// roster merely to prove that the token belongs to this daemon.
			path = "/v1/settings"
			header = "Authorization: Bearer " + token + "\r\n"
		}
		if _, err := io.WriteString(connection, "GET "+path+" HTTP/1.1\r\nHost: 127.0.0.1\r\n"+header+"Connection: close\r\n\r\n"); err != nil {
			_ = connection.Close()
			result <- probeResult{err: err}
			return
		}
		statusLine, err := bufio.NewReader(connection).ReadString('\n')
		_ = connection.Close()
		if err != nil {
			result <- probeResult{err: err}
			return
		}
		parts := strings.Fields(statusLine)
		if len(parts) < 2 || !strings.HasPrefix(parts[0], "HTTP/") {
			result <- probeResult{err: errors.New("remote HTTP probe returned an invalid status line")}
			return
		}
		status, parseErr := strconv.Atoi(parts[1])
		if parseErr != nil {
			result <- probeResult{err: errors.New("remote HTTP probe returned an invalid status code")}
			return
		}
		result <- probeResult{status: status}
	}()
	select {
	case probe := <-result:
		return probe.status, probe.err
	case <-ctx.Done():
		return 0, ctx.Err()
	case <-time.After(2 * time.Second):
		return 0, errors.New("remote HTTP probe timed out")
	}
}

func waitForRemoteDaemon(ctx context.Context, client *ssh.Client, address, token string) error {
	for {
		if remoteDaemonReady(ctx, client, address) {
			if authorized, err := remoteDaemonAuthorized(ctx, client, address, token); err != nil {
				return err
			} else if authorized {
				return nil
			}
		}
		select {
		case <-ctx.Done():
			return fmt.Errorf("Warren daemon did not become ready: %w", ctx.Err())
		case <-time.After(100 * time.Millisecond):
		}
	}
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
	host, port, err := net.SplitHostPort(address)
	if err != nil {
		return fmt.Errorf("invalid local SSH tunnel address %q: %w", address, err)
	}
	parsedPort, portErr := strconv.Atoi(port)
	if portErr != nil || parsedPort < 0 || parsedPort > 65535 {
		return fmt.Errorf("invalid local SSH tunnel port %q", port)
	}
	if !isLiteralLoopbackHost(host) {
		return fmt.Errorf("local SSH tunnel must bind to loopback, got %q", address)
	}
	return nil
}

func isLiteralLoopbackHost(host string) bool {
	ip := net.ParseIP(host)
	if ip == nil {
		return false
	}
	if ipv4 := ip.To4(); ipv4 != nil {
		return ipv4[0] == 127
	}
	return ip.Equal(net.ParseIP("::1"))
}

func lastNonEmptyLine(value string) string {
	lines := strings.Split(value, "\n")
	for index := len(lines) - 1; index >= 0; index-- {
		line := strings.TrimSuffix(lines[index], "\r")
		if line != "" {
			return line
		}
	}
	return ""
}

// validateToken accepts the daemon's opaque single-line token format. Older
// versions only accepted 32-byte hex/URL-safe values, which rejected tokens
// generated by installers using standard Base64. Keep the value visible ASCII
// so a token can never smuggle shell/output delimiters or an invalid header.
func validateToken(token string) bool {
	if token == "" || len(token) > 4096 {
		return false
	}
	for _, character := range []byte(token) {
		// Tokens are placed in an HTTP header during the bootstrap probe and
		// emitted as JSON-line data. Restrict them to visible ASCII so neither
		// transport can interpret a delimiter or invalid header byte.
		if character < 0x21 || character > 0x7e {
			return false
		}
	}
	return true
}
