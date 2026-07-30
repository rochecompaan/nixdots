package config

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestLoadParsesTrustedConfig(t *testing.T) {
	t.Setenv("XDG_CONFIG_HOME", t.TempDir())
	path := filepath.Join(t.TempDir(), "config.json")
	data := `{
      "pollInterval":"1m",
      "leadTime":"5m",
      "horizon":"24h",
      "workspace":"5",
      "allowedHosts":["meet.google.com","zoom.us","*.zoom.us"],
      "browserBin":"/nix/store/xdg-utils/bin/xdg-open",
      "firefoxLauncherBin":"/nix/store/niri-firefox-launcher/bin/niri-firefox-launcher",
      "systemctlBin":"/nix/store/systemd/bin/systemctl",
      "accounts":{"alpha":{"firefoxProfile":"clubhouse"}}
    }`
	if err := os.WriteFile(path, []byte(data), 0o600); err != nil {
		t.Fatal(err)
	}

	got, err := Load(path)
	if err != nil {
		t.Fatal(err)
	}
	if got.PollInterval != time.Minute || got.LeadTime != 5*time.Minute || got.Horizon != 24*time.Hour {
		t.Fatalf("unexpected durations: %#v", got)
	}
	if got.Accounts["alpha"].FirefoxProfile != "clubhouse" {
		t.Fatalf("unexpected account mapping: %#v", got.Accounts)
	}
}

func TestLoadRejectsInvalidConfig(t *testing.T) {
	tests := []struct {
		name string
		body string
	}{
		{"no accounts", `{"pollInterval":"1m","leadTime":"5m","horizon":"24h","workspace":"5","allowedHosts":["meet.google.com"],"browserBin":"/xdg-open","firefoxLauncherBin":"/niri-firefox-launcher","systemctlBin":"/systemctl","accounts":{}}`},
		{"empty profile", `{"pollInterval":"1m","leadTime":"5m","horizon":"24h","workspace":"5","allowedHosts":["meet.google.com"],"browserBin":"/xdg-open","firefoxLauncherBin":"/niri-firefox-launcher","systemctlBin":"/systemctl","accounts":{"alpha":{"firefoxProfile":""}}}`},
		{"bad host pattern", `{"pollInterval":"1m","leadTime":"5m","horizon":"24h","workspace":"5","allowedHosts":["https://meet.google.com"],"browserBin":"/xdg-open","firefoxLauncherBin":"/niri-firefox-launcher","systemctlBin":"/systemctl","accounts":{"alpha":{"firefoxProfile":"clubhouse"}}}`},
		{"unknown field", `{"pollInterval":"1m","leadTime":"5m","horizon":"24h","workspace":"5","allowedHosts":["meet.google.com"],"browserBin":"/xdg-open","firefoxLauncherBin":"/niri-firefox-launcher","systemctlBin":"/systemctl","accounts":{"alpha":{"firefoxProfile":"clubhouse"}},"unexpected":true}`},
		{"trailing JSON", `{"pollInterval":"1m","leadTime":"5m","horizon":"24h","workspace":"5","allowedHosts":["meet.google.com"],"browserBin":"/xdg-open","firefoxLauncherBin":"/niri-firefox-launcher","systemctlBin":"/systemctl","accounts":{"alpha":{"firefoxProfile":"clubhouse"}}}{}`},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "config.json")
			if err := os.WriteFile(path, []byte(tt.body), 0o600); err != nil {
				t.Fatal(err)
			}
			if _, err := Load(path); err == nil {
				t.Fatal("expected validation error")
			}
		})
	}
}

func TestDefaultPathUsesXDGConfigHome(t *testing.T) {
	root := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", root)
	got, err := DefaultPath()
	if err != nil {
		t.Fatal(err)
	}
	want := filepath.Join(root, "meeting-notifier", "config.json")
	if got != want {
		t.Fatalf("got %q, want %q", got, want)
	}
}
