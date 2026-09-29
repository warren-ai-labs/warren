package agent

import (
	"encoding/json"
	"regexp"
	"strconv"
	"strings"
	"unicode/utf8"
)

const codexExecUpdatePlanCall = "tools.update_plan("

var codexExecToolCallPattern = regexp.MustCompile(`tools\.([A-Za-z_][A-Za-z0-9_]*)\s*\(`)

// codexExecUpdatePlan extracts the plan steps from a Codex code-mode `exec`
// script. Current Codex no longer exposes update_plan as its own function
// call: the model writes JavaScript such as
//
//	const r = await tools.update_plan({plan:[{step:"Inspect",status:"in_progress"}]}); text(r);
//
// and the call output is only `{}`, so the script is the sole record of the
// plan. The argument must be a literal object; its values may also name a
// `const` bound to a literal earlier in the script (`const plan = [...];
// tools.update_plan({plan})`). Anything computed stays an ordinary tool call.
//
// planOnly reports whether update_plan is the only host tool the script
// calls, in which case the tool row carries nothing beyond the Plan card.
func codexExecUpdatePlan(toolName string, input json.RawMessage) (steps []codexPlanStep, planOnly bool, ok bool) {
	if strings.ToLower(strings.TrimSpace(toolName)) != "exec" {
		return nil, false, false
	}
	var script string
	if json.Unmarshal(input, &script) != nil {
		return nil, false, false
	}
	start := strings.Index(script, codexExecUpdatePlanCall)
	if start < 0 {
		return nil, false, false
	}
	literal, found := jsLiteralAt(script, start+len(codexExecUpdatePlanCall))
	if !found || literal[0] != '{' {
		return nil, false, false
	}
	encoded, converted := jsLiteralToJSON(literal, script, 0)
	if !converted {
		return nil, false, false
	}
	var args struct {
		Plan []codexPlanStep `json:"plan"`
	}
	if json.Unmarshal([]byte(encoded), &args) != nil || len(args.Plan) == 0 {
		return nil, false, false
	}
	planOnly = true
	for _, match := range codexExecToolCallPattern.FindAllStringSubmatch(script, -1) {
		if match[1] != "update_plan" {
			planOnly = false
			break
		}
	}
	return args.Plan, planOnly, true
}

// jsLiteralAt returns the balanced `{...}` or `[...]` that starts at the
// first non-space character at or after offset.
func jsLiteralAt(source string, offset int) (string, bool) {
	index := offset
	for index < len(source) && strings.ContainsRune(" \t\r\n", rune(source[index])) {
		index++
	}
	if index >= len(source) || (source[index] != '{' && source[index] != '[') {
		return "", false
	}
	depth := 0
	for cursor := index; cursor < len(source); cursor++ {
		switch source[cursor] {
		case '"', '\'', '`':
			end, ok := jsStringEnd(source, cursor)
			if !ok {
				return "", false
			}
			cursor = end
		case '{', '[':
			depth++
		case '}', ']':
			depth--
			if depth == 0 {
				return source[index : cursor+1], true
			}
		}
	}
	return "", false
}

// jsStringEnd returns the index of the closing quote of the string literal
// opened at start.
func jsStringEnd(source string, start int) (int, bool) {
	quote := source[start]
	for cursor := start + 1; cursor < len(source); cursor++ {
		switch source[cursor] {
		case '\\':
			cursor++
		case quote:
			return cursor, true
		}
	}
	return 0, false
}

// jsConstLiteral returns the literal bound by `const name = <literal>` in
// script.
func jsConstLiteral(script, name string) (string, bool) {
	pattern := regexp.MustCompile(`(?:^|[^A-Za-z0-9_$.])const\s+` + regexp.QuoteMeta(name) + `\s*=\s*`)
	match := pattern.FindStringIndex(script)
	if match == nil {
		return "", false
	}
	return jsLiteralAt(script, match[1])
}

// jsLiteralToJSON converts the JSON-like subset of JavaScript literals models
// write for tool arguments: bare or quoted keys, single, double, or backtick
// strings, trailing commas, numbers, and true/false/null. A value (or
// shorthand property) naming a const bound to a literal in script resolves to
// that literal. Anything else, such as a computed value or template
// interpolation, fails the conversion rather than guessing a value.
func jsLiteralToJSON(literal, script string, depth int) (string, bool) {
	if depth > 4 {
		return "", false
	}
	var out strings.Builder
	var containers []byte
	lastSignificant := byte(0)
	for index := 0; index < len(literal); {
		char := literal[index]
		switch {
		case char == '"' || char == '\'' || char == '`':
			end, ok := jsStringEnd(literal, index)
			if !ok {
				return "", false
			}
			value, ok := jsStringValue(literal[index+1:end], char)
			if !ok {
				return "", false
			}
			encoded, _ := json.Marshal(value)
			out.Write(encoded)
			lastSignificant = '"'
			index = end + 1
		case char == ',':
			next := index + 1
			for next < len(literal) && strings.ContainsRune(" \t\r\n", rune(literal[next])) {
				next++
			}
			if next < len(literal) && (literal[next] == '}' || literal[next] == ']') {
				index = next
				continue
			}
			out.WriteByte(char)
			lastSignificant = char
			index++
		case char == '_' || char == '$' || (char|0x20 >= 'a' && char|0x20 <= 'z'):
			end := index
			for end < len(literal) {
				next := literal[end]
				if next == '_' || next == '$' || (next|0x20 >= 'a' && next|0x20 <= 'z') || (next >= '0' && next <= '9') {
					end++
					continue
				}
				break
			}
			word := literal[index:end]
			after := end
			for after < len(literal) && strings.ContainsRune(" \t\r\n", rune(literal[after])) {
				after++
			}
			key, _ := json.Marshal(word)
			switch {
			case after < len(literal) && literal[after] == ':':
				out.Write(key)
			case word == "true" || word == "false" || word == "null":
				out.WriteString(word)
			default:
				bound, ok := jsConstLiteral(script, word)
				if !ok {
					return "", false
				}
				value, ok := jsLiteralToJSON(bound, script, depth+1)
				if !ok {
					return "", false
				}
				shorthand := len(containers) > 0 && containers[len(containers)-1] == '{' &&
					(lastSignificant == '{' || lastSignificant == ',')
				if shorthand {
					out.Write(key)
					out.WriteByte(':')
				}
				out.WriteString(value)
			}
			lastSignificant = 'a'
			index = end
		case char < utf8.RuneSelf && strings.ContainsRune("{}[]:-+.0123456789eE \t\r\n", rune(char)):
			switch char {
			case '{', '[':
				containers = append(containers, char)
			case '}', ']':
				if len(containers) == 0 {
					return "", false
				}
				containers = containers[:len(containers)-1]
			}
			if !strings.ContainsRune(" \t\r\n", rune(char)) {
				lastSignificant = char
			}
			out.WriteByte(char)
			index++
		default:
			return "", false
		}
	}
	return out.String(), true
}

// jsStringValue decodes the body of a JavaScript string literal.
func jsStringValue(body string, quote byte) (string, bool) {
	if quote == '`' && strings.Contains(body, "${") {
		return "", false
	}
	var out strings.Builder
	for index := 0; index < len(body); index++ {
		char := body[index]
		if char != '\\' {
			out.WriteByte(char)
			continue
		}
		index++
		if index >= len(body) {
			return "", false
		}
		switch escaped := body[index]; escaped {
		case 'n':
			out.WriteByte('\n')
		case 't':
			out.WriteByte('\t')
		case 'r':
			out.WriteByte('\r')
		case 'b':
			out.WriteByte('\b')
		case 'f':
			out.WriteByte('\f')
		case '0':
			out.WriteByte(0)
		case 'u':
			if index+4 >= len(body) {
				return "", false
			}
			code, err := strconv.ParseUint(body[index+1:index+5], 16, 32)
			if err != nil {
				return "", false
			}
			out.WriteRune(rune(code))
			index += 4
		case '\n':
			// Line continuation.
		default:
			out.WriteByte(escaped)
		}
	}
	return out.String(), true
}
