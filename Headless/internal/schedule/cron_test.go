package schedule

import (
	"errors"
	"testing"
	"time"
)

func mustLocation(t *testing.T, name string) *time.Location {
	t.Helper()
	location, err := time.LoadLocation(name)
	if err != nil {
		t.Skipf("time zone %s unavailable: %v", name, err)
	}
	return location
}

func TestCronNext(t *testing.T) {
	shanghai := mustLocation(t, "Asia/Shanghai")
	at := func(value string) time.Time {
		parsed, err := time.ParseInLocation("2006-01-02 15:04", value, shanghai)
		if err != nil {
			t.Fatal(err)
		}
		return parsed
	}
	cases := []struct {
		expression string
		after      string
		want       string
	}{
		{"47 10 * * *", "2026-10-23 09:00", "2026-10-23 10:47"},
		{"47 10 * * *", "2026-10-23 10:47", "2026-10-24 10:47"},
		{"47 10 * * *", "2026-10-31 11:00", "2026-11-01 10:47"},
		{"*/15 * * * *", "2026-10-23 10:01", "2026-10-23 10:15"},
		{"5/20 * * * *", "2026-10-23 10:26", "2026-10-23 10:45"},
		{"0 9 * * mon-fri", "2026-10-23 10:00", "2026-10-26 09:00"}, // Friday → Monday
		{"0 9 * * 7", "2026-10-23 10:00", "2026-10-25 09:00"},       // 7 is Sunday
		{"0 0 1 jan *", "2026-10-23 10:00", "2027-01-01 00:00"},
		{"0 0 13 * fri", "2026-10-23 10:00", "2026-10-30 00:00"}, // either day field matches
		{"@daily", "2026-10-23 10:00", "2026-10-24 00:00"},
		{"0 12 29 2 *", "2026-10-23 10:00", "2028-02-29 12:00"},
	}
	for _, test := range cases {
		cron, err := ParseCron(test.expression)
		if err != nil {
			t.Fatalf("%s: %v", test.expression, err)
		}
		got := cron.Next(at(test.after))
		if !got.Equal(at(test.want)) {
			t.Errorf("%s after %s = %s, want %s", test.expression, test.after, got.Format("2006-01-02 15:04 Mon"), test.want)
		}
	}
}

func TestCronNextNeverMatches(t *testing.T) {
	cron, err := ParseCron("0 0 30 2 *")
	if err != nil {
		t.Fatal(err)
	}
	if got := cron.Next(time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)); !got.IsZero() {
		t.Fatalf("February 30 matched %s", got)
	}
}

func TestCronNextAcrossDaylightSaving(t *testing.T) {
	newYork := mustLocation(t, "America/New_York")
	cron, err := ParseCron("30 2 * * *")
	if err != nil {
		t.Fatal(err)
	}
	// 2026-03-08 02:30 does not exist in New York; the next run must still
	// make progress and land on a real later day.
	got := cron.Next(time.Date(2026, 3, 7, 3, 0, 0, 0, newYork))
	if got.IsZero() || !got.After(time.Date(2026, 3, 7, 3, 0, 0, 0, newYork)) {
		t.Fatalf("next = %s", got)
	}
	if got.Hour() != 2 && got.Hour() != 3 {
		t.Fatalf("next = %s", got)
	}
}

func TestParseCronRejects(t *testing.T) {
	for _, expression := range []string{"", "* * * *", "60 * * * *", "* 24 * * *", "* * 0 * *", "* * * 13 *", "*/0 * * * *", "5-1 * * * *", "a * * * *", ",1 * * * *"} {
		if _, err := ParseCron(expression); err == nil {
			t.Errorf("%q parsed", expression)
		}
	}
}

func TestParseInstant(t *testing.T) {
	shanghai := mustLocation(t, "Asia/Shanghai")
	got, err := ParseInstant("2026-10-30", shanghai, true)
	if err != nil {
		t.Fatal(err)
	}
	if want := time.Date(2026, 10, 30, 23, 59, 59, 0, shanghai); !got.Equal(want) {
		t.Fatalf("end of day = %s, want %s", got, want)
	}
	if _, err := ParseInstant("2026-10-30", shanghai, false); !errors.Is(err, ErrDateOnly) {
		t.Fatalf("date-only at = %v", err)
	}
	for _, value := range []string{"2026-10-24 10:47", "2026-10-24T10:47", "2026-10-24T10:47:00"} {
		got, err := ParseInstant(value, shanghai, false)
		if err != nil {
			t.Fatalf("%s: %v", value, err)
		}
		if want := time.Date(2026, 10, 24, 10, 47, 0, 0, shanghai); !got.Equal(want) {
			t.Fatalf("%s = %s", value, got)
		}
	}
	got, err = ParseInstant("2026-10-24T02:47:00Z", shanghai, false)
	if err != nil || !got.Equal(time.Date(2026, 10, 24, 10, 47, 0, 0, shanghai)) {
		t.Fatalf("RFC 3339 = %s, %v", got, err)
	}
	if _, err := ParseInstant("tomorrow", shanghai, true); err == nil {
		t.Fatal("tomorrow parsed")
	}
}
