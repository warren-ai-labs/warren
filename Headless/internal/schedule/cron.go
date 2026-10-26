// Package schedule holds the time rules of Host-owned Schedules: the cron
// expression they repeat on and the date/time forms their bounds accept. It is
// pure so the rules can be tested without a Host.
package schedule

import (
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"
)

// Cron is a parsed five-field cron expression (minute, hour, day of month,
// month, day of week), evaluated in the location of the time passed to Next.
type Cron struct {
	minute, hour, dom, month, dow uint64
	// domAny and dowAny record a literal "*" in the day fields. Like Vixie
	// cron, a day matches either day field when both are restricted.
	domAny, dowAny bool
}

var cronMacros = map[string]string{
	"@yearly":   "0 0 1 1 *",
	"@annually": "0 0 1 1 *",
	"@monthly":  "0 0 1 * *",
	"@weekly":   "0 0 * * 0",
	"@daily":    "0 0 * * *",
	"@midnight": "0 0 * * *",
	"@hourly":   "0 * * * *",
}

var monthNames = map[string]int{
	"jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
	"jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12,
}

var weekdayNames = map[string]int{
	"sun": 0, "mon": 1, "tue": 2, "wed": 3, "thu": 4, "fri": 5, "sat": 6,
}

// ParseCron parses a five-field expression or one of the @yearly, @monthly,
// @weekly, @daily, and @hourly macros.
func ParseCron(expression string) (*Cron, error) {
	expression = strings.TrimSpace(expression)
	if macro, ok := cronMacros[strings.ToLower(expression)]; ok {
		expression = macro
	}
	fields := strings.Fields(expression)
	if len(fields) != 5 {
		return nil, fmt.Errorf("cron expression %q must have 5 fields: minute hour day-of-month month day-of-week", expression)
	}
	var cron Cron
	var err error
	if cron.minute, err = parseCronField(fields[0], 0, 59, nil); err != nil {
		return nil, fmt.Errorf("cron minute: %w", err)
	}
	if cron.hour, err = parseCronField(fields[1], 0, 23, nil); err != nil {
		return nil, fmt.Errorf("cron hour: %w", err)
	}
	if cron.dom, err = parseCronField(fields[2], 1, 31, nil); err != nil {
		return nil, fmt.Errorf("cron day of month: %w", err)
	}
	if cron.month, err = parseCronField(fields[3], 1, 12, monthNames); err != nil {
		return nil, fmt.Errorf("cron month: %w", err)
	}
	if cron.dow, err = parseCronField(fields[4], 0, 7, weekdayNames); err != nil {
		return nil, fmt.Errorf("cron day of week: %w", err)
	}
	// 7 is Sunday as well as 0.
	if cron.dow&(1<<7) != 0 {
		cron.dow |= 1
	}
	cron.domAny = fields[2] == "*"
	cron.dowAny = fields[4] == "*"
	return &cron, nil
}

func parseCronField(field string, low, high int, names map[string]int) (uint64, error) {
	var bits uint64
	for _, part := range strings.Split(field, ",") {
		if part == "" {
			return 0, fmt.Errorf("empty list item in %q", field)
		}
		rangePart, stepPart, hasStep := strings.Cut(part, "/")
		step := 1
		if hasStep {
			value, err := strconv.Atoi(stepPart)
			if err != nil || value <= 0 {
				return 0, fmt.Errorf("invalid step %q", stepPart)
			}
			step = value
		}
		start, end := low, high
		switch {
		case rangePart == "*":
		case strings.Contains(rangePart, "-"):
			first, last, _ := strings.Cut(rangePart, "-")
			var err error
			if start, err = cronValue(first, low, high, names); err != nil {
				return 0, err
			}
			if end, err = cronValue(last, low, high, names); err != nil {
				return 0, err
			}
			if start > end {
				return 0, fmt.Errorf("range %q runs backwards", rangePart)
			}
		default:
			value, err := cronValue(rangePart, low, high, names)
			if err != nil {
				return 0, err
			}
			start = value
			// "5/15" means from 5 to the end in steps of 15.
			if !hasStep {
				end = value
			}
		}
		for value := start; value <= end; value += step {
			bits |= 1 << uint(value)
		}
	}
	return bits, nil
}

func cronValue(text string, low, high int, names map[string]int) (int, error) {
	if value, ok := names[strings.ToLower(text)]; ok {
		return value, nil
	}
	value, err := strconv.Atoi(text)
	if err != nil {
		return 0, fmt.Errorf("invalid value %q", text)
	}
	if value < low || value > high {
		return 0, fmt.Errorf("value %d is outside %d-%d", value, low, high)
	}
	return value, nil
}

func (c *Cron) dayMatches(t time.Time) bool {
	dom := c.dom&(1<<uint(t.Day())) != 0
	dow := c.dow&(1<<uint(t.Weekday())) != 0
	if c.domAny || c.dowAny {
		return dom && dow
	}
	return dom || dow
}

// cronSearchLimit bounds the search for expressions that can never match,
// such as February 30.
const cronSearchLimit = 5 * 366 * 24 * time.Hour

// Next returns the first matching minute strictly after the given time, in
// that time's location, or the zero time when none exists.
func (c *Cron) Next(after time.Time) time.Time {
	location := after.Location()
	t := after.Truncate(time.Minute).Add(time.Minute)
	limit := after.Add(cronSearchLimit)
	for t.Before(limit) {
		year, month, day := t.Date()
		var next time.Time
		switch {
		case c.month&(1<<uint(month)) == 0:
			next = time.Date(year, month+1, 1, 0, 0, 0, 0, location)
		case !c.dayMatches(t):
			next = time.Date(year, month, day+1, 0, 0, 0, 0, location)
		case c.hour&(1<<uint(t.Hour())) == 0:
			next = time.Date(year, month, day, t.Hour()+1, 0, 0, 0, location)
		case c.minute&(1<<uint(t.Minute())) == 0:
			next = t.Add(time.Minute)
		default:
			return t
		}
		// A daylight-saving transition can map a wall-clock boundary back to
		// or before t; always make progress.
		if !next.After(t) {
			next = t.Add(time.Minute)
		}
		t = next
	}
	return time.Time{}
}

var localTimeLayouts = []string{
	"2006-01-02T15:04:05",
	"2006-01-02T15:04",
	"2006-01-02 15:04:05",
	"2006-01-02 15:04",
}

// ErrDateOnly reports a value that names a day without a time of day.
var ErrDateOnly = errors.New("a time of day is required")

// ParseInstant parses an RFC 3339 timestamp or a local date and time such as
// "2026-10-30 10:47". A bare date is accepted only when endOfDay is set, and
// then means the last second of that day.
func ParseInstant(value string, location *time.Location, endOfDay bool) (time.Time, error) {
	value = strings.TrimSpace(value)
	if value == "" {
		return time.Time{}, errors.New("time is empty")
	}
	if parsed, err := time.Parse(time.RFC3339, value); err == nil {
		return parsed, nil
	}
	for _, layout := range localTimeLayouts {
		if parsed, err := time.ParseInLocation(layout, value, location); err == nil {
			return parsed, nil
		}
	}
	if parsed, err := time.ParseInLocation("2006-01-02", value, location); err == nil {
		if !endOfDay {
			return time.Time{}, fmt.Errorf("%q: %w", value, ErrDateOnly)
		}
		year, month, day := parsed.Date()
		return time.Date(year, month, day, 23, 59, 59, 0, location), nil
	}
	return time.Time{}, fmt.Errorf("unrecognized time %q; use YYYY-MM-DD HH:MM, YYYY-MM-DDTHH:MM, or RFC 3339", value)
}
