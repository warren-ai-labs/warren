package main

import (
	"errors"
	"fmt"
	"sort"
	"strconv"
	"strings"

	"github.com/abcdlsj/warren/Headless/internal/config"
)

// displayCommand manages the client-local endpoint set shown by the Desktop.
// It never opens a Host connection and therefore remains safe to run while the
// Desktop is active.
func displayCommand(args []string) error {
	if len(args) == 0 || isHelpArgument(args[0]) {
		fmt.Print(displayUsageText())
		return nil
	}
	return displayEndpointsCommand(args)
}

type displayEndpointsResult struct {
	Endpoints []string          `json:"endpoints"`
	Current   string            `json:"current"`
	Version   int               `json:"version"`
	Names     map[string]string `json:"names,omitempty"`
}

func displayEndpointsCommand(args []string) error {
	action := args[0]
	if isHelpArgument(action) {
		fmt.Print(displayUsageText())
		return nil
	}
	switch action {
	case "list", "add", "remove", "move", "set", "reset":
	default:
		return newUsageError(fmt.Sprintf("unknown display command: %s", action), displayUsageText())
	}
	flags := parseFlags(args[1:])
	if boolValue(flags, "help") || boolValue(flags, "h") {
		fmt.Print(displayUsageText())
		return nil
	}
	if unknown := unknownDisplayFlags(flags); unknown != "" {
		return newUsageError("unknown display option --"+unknown, displayUsageText())
	}
	positions := positionals(flags)
	if action == "set" {
		if len(positions) == 0 {
			return newUsageError("missing ENDPOINT_NAME", displayUsageText())
		}
	} else if action != "list" && action != "reset" {
		if len(positions) == 0 {
			return newUsageError("missing ENDPOINT_NAME", displayUsageText())
		}
		if len(positions) > 1 {
			return newUsageError("display "+action+" accepts one ENDPOINT_NAME", displayUsageText())
		}
	}
	if action == "list" && len(positions) > 0 {
		return newUsageError("display list does not accept positional arguments", displayUsageText())
	}
	if action == "reset" && len(positions) > 0 {
		return newUsageError("display reset does not accept positional arguments", displayUsageText())
	}
	before := strings.TrimSpace(stringValue(flags, "before"))
	if (action == "add" || action == "move") && before == "" {
		// `add` appends by default; `move` requires an explicit destination so
		// an accidental invocation cannot silently reorder the set.
		if action == "move" {
			return newUsageError("missing --before ENDPOINT_NAME", displayUsageText())
		}
	}
	if action != "add" && action != "move" && before != "" {
		return newUsageError("--before is only valid with add or move", displayUsageText())
	}
	if action == "list" {
		settings, err := config.Load(configPath)
		if err != nil {
			return err
		}
		if settings.Display != nil {
			if err := settings.NormalizeDisplay(); err != nil {
				return err
			}
		}
		result := makeDisplayEndpointsResult(settings)
		return printDisplayEndpointsResult(result)
	}

	var result displayEndpointsResult
	err := config.Update(configPath, func(settings *config.Config) error {
		if settings.Endpoints == nil {
			settings.Endpoints = map[string]config.Endpoint{}
		}
		switch action {
		case "set":
			if err := validateDisplayAliases(*settings, positions); err != nil {
				return err
			}
			settings.Display = &config.DisplayConfig{
				Version:   config.DisplayConfigVersion,
				Endpoints: append([]string(nil), positions...),
				Names:     cloneDisplayNames(settings.Display),
			}
		case "add":
			aliases, err := effectiveDisplayForMutation(*settings)
			if err != nil {
				return err
			}
			name := positions[0]
			if err := validateDisplayAliases(*settings, []string{name}); err != nil {
				return err
			}
			if !containsString(aliases, name) {
				if before == "" {
					aliases = append(aliases, name)
				} else {
					index := indexOfString(aliases, before)
					if index < 0 {
						return fmt.Errorf("display endpoint not found: %s", before)
					}
					aliases = insertString(aliases, index, name)
				}
			} else if before != "" && indexOfString(aliases, before) < 0 {
				return fmt.Errorf("display endpoint not found: %s", before)
			}
			settings.Display = &config.DisplayConfig{
				Version:   config.DisplayConfigVersion,
				Endpoints: aliases,
				Names:     cloneDisplayNames(settings.Display),
			}
		case "remove":
			aliases, err := effectiveDisplayForMutation(*settings)
			if err != nil {
				return err
			}
			name := positions[0]
			index := indexOfString(aliases, name)
			if index < 0 {
				return fmt.Errorf("display endpoint not found: %s", name)
			}
			aliases = append(aliases[:index], aliases[index+1:]...)
			if len(aliases) == 0 {
				return errors.New("display endpoint set cannot be empty")
			}
			settings.Display = &config.DisplayConfig{
				Version:   config.DisplayConfigVersion,
				Endpoints: aliases,
				Names:     cloneDisplayNames(settings.Display),
			}
		case "move":
			aliases, err := effectiveDisplayForMutation(*settings)
			if err != nil {
				return err
			}
			name := positions[0]
			from := indexOfString(aliases, name)
			to := indexOfString(aliases, before)
			if from < 0 {
				return fmt.Errorf("display endpoint not found: %s", name)
			}
			if to < 0 {
				return fmt.Errorf("display endpoint not found: %s", before)
			}
			if name == before {
				// Keep the operation idempotent while still returning the normal
				// ordered result to the caller.
				settings.Display = &config.DisplayConfig{
					Version:   config.DisplayConfigVersion,
					Endpoints: aliases,
					Names:     cloneDisplayNames(settings.Display),
				}
				break
			}
			item := aliases[from]
			aliases = append(aliases[:from], aliases[from+1:]...)
			if from < to {
				to--
			}
			aliases = insertString(aliases, to, item)
			settings.Display = &config.DisplayConfig{
				Version:   config.DisplayConfigVersion,
				Endpoints: aliases,
				Names:     cloneDisplayNames(settings.Display),
			}
		case "reset":
			settings.Display = nil
		default:
			// The action was validated before opening the config transaction.
			return errors.New("invalid display command")
		}
		if settings.Display != nil {
			if err := settings.NormalizeDisplay(); err != nil {
				return err
			}
		}
		result = makeDisplayEndpointsResult(*settings)
		return nil
	})
	if err != nil {
		return err
	}
	return printDisplayEndpointsResult(result)
}

func printDisplayEndpointsResult(result displayEndpointsResult) error {
	if outputJSON {
		return printValue(result)
	}
	if outputQuiet {
		for _, alias := range result.Endpoints {
			fmt.Println(alias)
		}
		return nil
	}
	rows := make([][]string, 0, len(result.Endpoints))
	for index, alias := range result.Endpoints {
		marker := ""
		if alias == result.Current {
			marker = "*"
		}
		rows = append(rows, []string{marker, strconv.Itoa(index + 1), alias})
	}
	printTable([]string{"CURRENT", "ORDER", "ENDPOINT"}, rows...)
	return nil
}

func effectiveDisplayForMutation(settings config.Config) ([]string, error) {
	if settings.Display != nil {
		return settings.EffectiveDisplay()
	}
	current := strings.TrimSpace(settings.Current)
	if current == "" {
		current = defaultEndpointName
	}
	return []string{current}, nil
}

func validateDisplayAliases(settings config.Config, aliases []string) error {
	if len(aliases) == 0 {
		return errors.New("display endpoint set cannot be empty")
	}
	seen := map[string]struct{}{}
	for _, alias := range aliases {
		name := strings.TrimSpace(alias)
		if name == "" || name != alias || strings.ContainsAny(name, "\r\n\x00") {
			return fmt.Errorf("invalid display endpoint name: %q", alias)
		}
		if _, exists := seen[name]; exists {
			continue
		}
		seen[name] = struct{}{}
		if name != defaultEndpointName {
			if _, ok := settings.Endpoints[name]; !ok {
				return fmt.Errorf("display endpoint not found: %s", name)
			}
		}
	}
	return nil
}

func makeDisplayEndpointsResult(settings config.Config) displayEndpointsResult {
	aliases, err := effectiveDisplayForMutation(settings)
	if err != nil {
		aliases = []string{defaultEndpointName}
	}
	version := 0
	if settings.Display != nil {
		version = settings.Display.Version
		if version == 0 {
			version = config.DisplayConfigVersion
		}
	}
	current := strings.TrimSpace(settings.Current)
	if current == "" {
		current = defaultEndpointName
	}
	return displayEndpointsResult{
		Endpoints: aliases,
		Current:   current,
		Version:   version,
		Names:     cloneDisplayNames(settings.Display),
	}
}

func cloneDisplayNames(display *config.DisplayConfig) map[string]string {
	if display == nil || len(display.Names) == 0 {
		return nil
	}
	names := make(map[string]string, len(display.Names))
	for alias, name := range display.Names {
		names[alias] = name
	}
	return names
}

func unknownDisplayFlags(flags map[string]any) string {
	allowed := map[string]bool{
		"before": true, "help": true, "h": true,
	}
	for key := range flags {
		if key != "_" && !allowed[key] {
			return key
		}
	}
	return ""
}

func containsString(values []string, target string) bool { return indexOfString(values, target) >= 0 }

func indexOfString(values []string, target string) int {
	for index, value := range values {
		if value == target {
			return index
		}
	}
	return -1
}

func insertString(values []string, index int, value string) []string {
	if index < 0 || index > len(values) {
		index = len(values)
	}
	values = append(values, "")
	copy(values[index+1:], values[index:])
	values[index] = value
	return values
}

func normalizeConfiguredDisplay(settings *config.Config) error {
	if settings.Display == nil {
		return nil
	}
	return settings.NormalizeDisplay()
}

func firstRemainingEndpoint(endpoints map[string]config.Endpoint) string {
	if _, ok := endpoints[defaultEndpointName]; ok {
		return defaultEndpointName
	}
	names := make([]string, 0, len(endpoints))
	for name := range endpoints {
		if strings.TrimSpace(name) != "" {
			names = append(names, name)
		}
	}
	sort.Strings(names)
	if len(names) > 0 {
		return names[0]
	}
	return defaultEndpointName
}
