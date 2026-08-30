package sshclient

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"unicode"
)

// HostConfig contains the SSH connection values needed by the embedded
// client. It intentionally covers the portable subset of ~/.ssh/config that
// can be implemented without invoking the OpenSSH binary.
type HostConfig struct {
	Host           string
	User           string
	Port           int
	IdentityFile   []string
	IdentitiesOnly bool
	IdentityAgent  string
	AgentDisabled  bool
	HostKeyAlias   string
	KnownHosts     string
	// KnownHostsDisabled records an explicit UserKnownHostsFile none. The
	// system-wide defaults may still be active unless
	// GlobalKnownHostsDisabled is also true.
	KnownHostsDisabled bool
	// GlobalKnownHostsDisabled records an explicit
	// GlobalKnownHostsFile none. UserKnownHostsFile defaults still apply in
	// that case, but the system-wide files must not be reintroduced by the
	// fallback below.
	GlobalKnownHostsDisabled bool
	// KnownHostsFiles preserves the configured/default user and system files
	// while KnownHosts remains the first path for callers that only need one
	// value.
	KnownHostsFiles []string
}

// HostEntry is a selectable alias from the user's SSH configuration.
type HostEntry struct {
	Name   string
	Config HostConfig
	Error  string
}

type configBlock struct {
	patterns []string
	options  map[string][]string
}

func resolveHost(target, configPath string) (HostConfig, error) {
	target = strings.TrimSpace(target)
	if target == "" {
		return HostConfig{}, fmt.Errorf("SSH target is empty")
	}
	alias, userOverride := splitTarget(target)
	if strings.TrimSpace(alias) == "" {
		return HostConfig{}, fmt.Errorf("SSH target %q has no host alias", target)
	}
	if configPath == "" {
		configPath = defaultSSHConfigPath()
	}
	blocks, err := readSSHConfig(configPath, map[string]bool{})
	if err != nil {
		return HostConfig{}, err
	}
	host := HostConfig{Host: alias}
	hostNameConfigured := false
	var hostNameValue string
	identityConfigured := false
	identitiesOnlyConfigured := false
	identityAgentConfigured := false
	userKnownHostsConfigured := false
	globalKnownHostsConfigured := false
	var userKnownHostsFiles []string
	var globalKnownHostsFiles []string
	var proxyMode string
	var proxyKind string
	for _, block := range blocks {
		if !matchesHost(block.patterns, alias) {
			continue
		}
		for option, values := range block.options {
			if len(values) == 0 {
				continue
			}
			switch option {
			case "hostname":
				if !hostNameConfigured {
					hostNameConfigured = true
					hostNameValue = values[0]
				}
			case "user":
				if host.User == "" {
					host.User = values[0]
				}
			case "port":
				if host.Port == 0 {
					parsed, parseErr := strconv.Atoi(values[0])
					if parseErr != nil || parsed < 1 || parsed > 65535 {
						return HostConfig{}, fmt.Errorf("invalid SSH port %q for %q", values[0], target)
					}
					host.Port = parsed
				}
			case "identityfile":
				identityConfigured = true
				for _, value := range values {
					if !strings.EqualFold(value, "none") {
						host.IdentityFile = append(host.IdentityFile, value)
					}
				}
			case "identitiesonly":
				if !identitiesOnlyConfigured {
					host.IdentitiesOnly = strings.EqualFold(values[0], "yes") || values[0] == "1" || strings.EqualFold(values[0], "true")
					identitiesOnlyConfigured = true
				}
			case "identityagent":
				if !identityAgentConfigured {
					identityAgentConfigured = true
					value := strings.TrimSpace(values[0])
					if strings.EqualFold(value, "none") {
						host.AgentDisabled = true
					} else if value == "SSH_AUTH_SOCK" || value == "$SSH_AUTH_SOCK" || value == "${SSH_AUTH_SOCK}" {
						// OpenSSH treats this spelling as the environment-provided
						// agent socket rather than a literal path.
						host.IdentityAgent = strings.TrimSpace(os.Getenv("SSH_AUTH_SOCK"))
					} else {
						// Defer token expansion until User/Port have been resolved;
						// %r and %p are valid in IdentityAgent paths.
						host.IdentityAgent = value
					}
				}
			case "hostkeyalias":
				if host.HostKeyAlias == "" {
					host.HostKeyAlias = values[0]
				}
			case "userknownhostsfile":
				if !userKnownHostsConfigured {
					userKnownHostsConfigured = true
					configuredPath := false
					for _, value := range values {
						if !strings.EqualFold(value, "none") {
							userKnownHostsFiles = append(userKnownHostsFiles, value)
							configuredPath = true
						}
					}
					if !configuredPath {
						host.KnownHostsDisabled = true
					}
				}
			case "globalknownhostsfile":
				if !globalKnownHostsConfigured {
					globalKnownHostsConfigured = true
					configuredPath := false
					for _, value := range values {
						if !strings.EqualFold(value, "none") {
							globalKnownHostsFiles = append(globalKnownHostsFiles, value)
							configuredPath = true
						}
					}
					if !configuredPath {
						host.GlobalKnownHostsDisabled = true
					}
				}
			}
		}
		if proxyMode == "" {
			if values := block.options["proxyjump"]; len(values) > 0 {
				proxyMode, proxyKind = values[0], "ProxyJump"
			} else if values := block.options["proxycommand"]; len(values) > 0 {
				proxyMode, proxyKind = values[0], "ProxyCommand"
			}
		}
	}
	if proxyMode != "" && !strings.EqualFold(proxyMode, "none") {
		// Do not echo ProxyCommand/ProxyJump values: they can contain inline
		// passwords or other credentials. OpenSSH will apply the configured route
		// automatically when the user runs this external local forward.
		fallback := fmt.Sprintf("ssh -L 8789:127.0.0.1:8789 %s", shellQuote(target))
		return HostConfig{}, fmt.Errorf("SSH target %q uses unsupported %s; run %s externally, then add it with 'warren endpoint add NAME --url http://127.0.0.1:8789 --token TOKEN'", target, proxyKind, fallback)
	}
	if userOverride != "" {
		host.User = userOverride
	}
	if host.User == "" {
		host.User = os.Getenv("USER")
	}
	if host.User == "" {
		if current, err := os.UserHomeDir(); err == nil {
			host.User = filepath.Base(current)
		}
	}
	if host.User == "" {
		return HostConfig{}, fmt.Errorf("SSH user is not configured for %q", target)
	}
	if host.Port == 0 {
		host.Port = 22
	}
	if hostNameConfigured {
		// HostName is allowed to use OpenSSH %-tokens. Expand against the
		// command-line alias for %h, then retain the resolved hostname for the
		// actual TCP dial and all later path expansions.
		templateHost := host
		templateHost.Host = alias
		host.Host = expandSSHPath(strings.ReplaceAll(hostNameValue, "%h", alias), templateHost)
	}
	host.Host = unbracketSSHHost(host.Host)
	if strings.TrimSpace(host.Host) == "" {
		return HostConfig{}, fmt.Errorf("SSH hostname is empty for %q", target)
	}
	if host.HostKeyAlias != "" {
		host.HostKeyAlias = unbracketSSHHost(expandSSHPath(host.HostKeyAlias, host))
	}
	if !identityConfigured {
		host.IdentityFile = defaultIdentityFiles()
	}
	// User and system known_hosts sources are independent OpenSSH options. An
	// explicit value for one must not silently drop the default files from the
	// other; only `none` disables its own source.
	if !host.KnownHostsDisabled {
		if userKnownHostsConfigured {
			host.KnownHostsFiles = append(host.KnownHostsFiles, userKnownHostsFiles...)
		} else {
			host.KnownHostsFiles = append(host.KnownHostsFiles, defaultUserKnownHostsFiles()...)
		}
	}
	if !host.GlobalKnownHostsDisabled {
		if globalKnownHostsConfigured {
			host.KnownHostsFiles = append(host.KnownHostsFiles, globalKnownHostsFiles...)
		} else {
			host.KnownHostsFiles = append(host.KnownHostsFiles, defaultGlobalKnownHostsFiles()...)
		}
	}
	if len(host.KnownHostsFiles) > 0 {
		host.KnownHosts = host.KnownHostsFiles[0]
	}
	for index, identity := range host.IdentityFile {
		host.IdentityFile[index] = expandSSHPath(identity, host)
	}
	if host.IdentityAgent != "" {
		host.IdentityAgent = expandSSHPath(host.IdentityAgent, host)
	}
	for index, knownHosts := range host.KnownHostsFiles {
		host.KnownHostsFiles[index] = expandSSHPath(knownHosts, host)
	}
	if len(host.KnownHostsFiles) > 0 {
		host.KnownHosts = host.KnownHostsFiles[0]
	}
	return host, nil
}

func shellQuote(value string) string {
	return "'" + strings.ReplaceAll(value, "'", "'\\''") + "'"
}

func unbracketSSHHost(value string) string {
	if len(value) >= 2 && strings.HasPrefix(value, "[") && strings.HasSuffix(value, "]") {
		return value[1 : len(value)-1]
	}
	return value
}

// ListHosts returns concrete SSH aliases in config order. Wildcard-only and
// negated patterns are intentionally omitted because they are defaults, not
// selectable destinations.
func ListHosts(configPath string) ([]HostEntry, error) {
	if configPath == "" {
		configPath = defaultSSHConfigPath()
	}
	blocks, err := readSSHConfig(configPath, map[string]bool{})
	if err != nil {
		return nil, err
	}
	seen := make(map[string]bool)
	entries := make([]HostEntry, 0)
	for _, block := range blocks {
		for _, pattern := range block.patterns {
			if pattern == "" || strings.HasPrefix(pattern, "!") || strings.ContainsAny(pattern, "*?[") || seen[pattern] {
				continue
			}
			seen[pattern] = true
			host, resolveErr := resolveHost(pattern, configPath)
			if resolveErr != nil {
				entries = append(entries, HostEntry{Name: pattern, Error: resolveErr.Error()})
				continue
			}
			entries = append(entries, HostEntry{Name: pattern, Config: host})
		}
	}
	return entries, nil
}

func splitTarget(target string) (alias, user string) {
	if index := strings.LastIndexByte(target, '@'); index >= 0 {
		return target[index+1:], target[:index]
	}
	return target, ""
}

func readSSHConfig(path string, seen map[string]bool) ([]configBlock, error) {
	path = canonicalSSHPath(path)
	if seen[path] {
		return nil, fmt.Errorf("recursive SSH config include: %s", path)
	}
	seen[path] = true
	defer delete(seen, path)

	file, err := os.Open(path)
	if os.IsNotExist(err) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("open SSH config %s: %w", path, err)
	}
	defer file.Close()

	blocks := make([]configBlock, 0, 4)
	current := configBlock{patterns: []string{"*"}, options: make(map[string][]string)}
	hasHostBlock := false
	flush := func() {
		if !hasHostBlock && len(current.options) == 0 {
			return
		}
		options := make(map[string][]string, len(current.options))
		for option, values := range current.options {
			options[option] = append([]string(nil), values...)
		}
		blocks = append(blocks, configBlock{
			patterns: append([]string(nil), current.patterns...),
			options:  options,
		})
		current.options = make(map[string][]string)
		hasHostBlock = false
	}
	scanner := bufio.NewScanner(file)
	lineNumber := 0
	for scanner.Scan() {
		lineNumber++
		line := strings.TrimSpace(stripSSHComment(scanner.Text()))
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		fields := normalizeSSHFields(parseSSHFields(line))
		if len(fields) < 2 {
			continue
		}
		option := strings.ToLower(fields[0])
		if option == "host" {
			flush()
			current = configBlock{patterns: fields[1:], options: make(map[string][]string)}
			hasHostBlock = true
			continue
		}
		if option == "include" {
			// Keep an option-less Host block pending around an Include so the
			// included aliases retain their existing order. The pending block is
			// still emitted at EOF, which keeps bare aliases selectable.
			if len(current.options) > 0 {
				flush()
			}
			for _, include := range fields[1:] {
				includePath := include
				if !filepath.IsAbs(includePath) && !strings.HasPrefix(includePath, "~/") {
					includePath = filepath.Join(filepath.Dir(path), includePath)
				}
				matches, globErr := filepath.Glob(expandSSHPath(includePath, HostConfig{}))
				if globErr != nil {
					return nil, fmt.Errorf("parse SSH Include at %s:%d: %w", path, lineNumber, globErr)
				}
				sort.Strings(matches)
				for _, match := range matches {
					included, includeErr := readSSHConfig(match, seen)
					if includeErr != nil {
						return nil, includeErr
					}
					blocks = append(blocks, included...)
				}
			}
			continue
		}
		current.options[option] = append(current.options[option], fields[1:]...)
	}
	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("read SSH config %s: %w", path, err)
	}
	flush()
	return blocks, nil
}

func matchesHost(patterns []string, alias string) bool {
	matched := false
	for _, pattern := range patterns {
		negated := strings.HasPrefix(pattern, "!")
		if negated {
			pattern = strings.TrimPrefix(pattern, "!")
		}
		match, _ := filepath.Match(pattern, alias)
		if !match {
			continue
		}
		if negated {
			return false
		}
		matched = true
	}
	return matched
}

func expandSSHPath(value string, host HostConfig) string {
	value = strings.TrimSpace(value)
	if value == "" {
		return value
	}
	if value == "~" || strings.HasPrefix(value, "~/") {
		if value == "~" {
			value = userHomeDirectory()
		} else {
			value = filepath.Join(userHomeDirectory(), strings.TrimPrefix(value, "~/"))
		}
	}
	user := os.Getenv("USER")
	if user == "" {
		if current, err := os.UserHomeDir(); err == nil {
			user = filepath.Base(current)
		}
	}
	replacements := map[string]string{
		"%h": host.Host,
		"%r": host.User,
		"%p": strconv.Itoa(host.Port),
		"%d": func() string { home, _ := os.UserHomeDir(); return home }(),
		"%u": user,
	}
	for key, replacement := range replacements {
		value = strings.ReplaceAll(value, key, replacement)
	}
	return value
}

func defaultSSHConfigPath() string {
	return filepath.Join(userHomeDirectory(), ".ssh", "config")
}

func defaultIdentityFiles() []string {
	home := userHomeDirectory()
	return []string{
		filepath.Join(home, ".ssh", "id_ed25519"),
		filepath.Join(home, ".ssh", "id_ecdsa"),
		filepath.Join(home, ".ssh", "id_rsa"),
		filepath.Join(home, ".ssh", "id_dsa"),
	}
}

func defaultKnownHostsFiles() []string {
	return append(defaultUserKnownHostsFiles(), defaultGlobalKnownHostsFiles()...)
}

func defaultGlobalKnownHostsFiles() []string {
	return []string{
		"/etc/ssh/ssh_known_hosts",
		"/etc/ssh/ssh_known_hosts2",
	}
}

func defaultUserKnownHostsFiles() []string {
	home := userHomeDirectory()
	return []string{
		filepath.Join(home, ".ssh", "known_hosts"),
		filepath.Join(home, ".ssh", "known_hosts2"),
	}
}

func userHomeDirectory() string {
	if home, err := os.UserHomeDir(); err == nil && home != "" {
		return home
	}
	return ""
}

func canonicalSSHPath(path string) string {
	path = expandSSHPath(path, HostConfig{})
	if absolute, err := filepath.Abs(path); err == nil {
		return filepath.Clean(absolute)
	}
	return filepath.Clean(path)
}

func stripSSHComment(line string) string {
	var quote rune
	escaped := false
	for index, character := range line {
		if escaped {
			escaped = false
			continue
		}
		if character == '\\' && quote != '\'' {
			escaped = true
			continue
		}
		if quote != 0 {
			if character == quote {
				quote = 0
			}
			continue
		}
		if character == '\'' || character == '"' {
			quote = character
			continue
		}
		if character == '#' && (index == 0 || unicode.IsSpace(rune(line[index-1]))) {
			return line[:index]
		}
	}
	return line
}

func parseSSHFields(line string) []string {
	fields := make([]string, 0, 4)
	var current strings.Builder
	var quote rune
	escaped := false
	hasValue := false
	flush := func() {
		if !hasValue {
			return
		}
		fields = append(fields, current.String())
		current.Reset()
		hasValue = false
	}
	for _, character := range line {
		if escaped {
			current.WriteRune(character)
			hasValue = true
			escaped = false
			continue
		}
		if quote != 0 {
			if character == quote {
				quote = 0
			} else {
				current.WriteRune(character)
				hasValue = true
			}
			continue
		}
		switch {
		case character == '\\':
			escaped = true
			hasValue = true
		case character == '\'' || character == '"':
			quote = character
			hasValue = true
		case unicode.IsSpace(character):
			flush()
		default:
			current.WriteRune(character)
			hasValue = true
		}
	}
	if escaped {
		current.WriteRune('\\')
		hasValue = true
	}
	flush()
	return fields
}

// normalizeSSHFields accepts both OpenSSH spellings, such as "Port 22" and
// "Port=22". Some generated configs also put whitespace around the equals
// sign, so that form is accepted as well.
func normalizeSSHFields(fields []string) []string {
	if len(fields) == 0 {
		return fields
	}
	if index := strings.IndexByte(fields[0], '='); index > 0 {
		normalized := []string{fields[0][:index]}
		if value := fields[0][index+1:]; value != "" {
			normalized = append(normalized, value)
		}
		fields = append(normalized, fields[1:]...)
	}
	if len(fields) > 1 && fields[1] == "=" {
		fields = append(fields[:1], fields[2:]...)
	}
	return fields
}
