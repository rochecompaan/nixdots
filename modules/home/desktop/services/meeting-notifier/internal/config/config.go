package config

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"
)

type Account struct {
	FirefoxProfile string `json:"firefoxProfile"`
}

type fileConfig struct {
	PollInterval       string             `json:"pollInterval"`
	LeadTime           string             `json:"leadTime"`
	Horizon            string             `json:"horizon"`
	Workspace          string             `json:"workspace"`
	AllowedHosts       []string           `json:"allowedHosts"`
	BrowserBin         string             `json:"browserBin"`
	FirefoxLauncherBin string             `json:"firefoxLauncherBin"`
	SystemctlBin       string             `json:"systemctlBin"`
	Accounts           map[string]Account `json:"accounts"`
}

type Config struct {
	PollInterval       time.Duration
	LeadTime           time.Duration
	Horizon            time.Duration
	Workspace          string
	AllowedHosts       []string
	BrowserBin         string
	FirefoxLauncherBin string
	SystemctlBin       string
	Accounts           map[string]Account
}

func DefaultPath() (string, error) {
	root := os.Getenv("XDG_CONFIG_HOME")
	if root == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return "", err
		}
		root = filepath.Join(home, ".config")
	}
	return filepath.Join(root, "meeting-notifier", "config.json"), nil
}

func Load(path string) (Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return Config{}, err
	}

	var raw fileConfig
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&raw); err != nil {
		return Config{}, fmt.Errorf("decode static config: %w", err)
	}
	var trailing any
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		return Config{}, errors.New("static config must contain exactly one JSON value")
	}

	poll, err := time.ParseDuration(raw.PollInterval)
	if err != nil || poll <= 0 {
		return Config{}, errors.New("pollInterval must be a positive Go duration")
	}
	lead, err := time.ParseDuration(raw.LeadTime)
	if err != nil || lead <= 0 {
		return Config{}, errors.New("leadTime must be a positive Go duration")
	}
	horizon, err := time.ParseDuration(raw.Horizon)
	if err != nil || horizon < lead {
		return Config{}, errors.New("horizon must be a duration at least as large as leadTime")
	}
	if raw.Workspace == "" || raw.BrowserBin == "" || raw.FirefoxLauncherBin == "" || raw.SystemctlBin == "" {
		return Config{}, errors.New("workspace, browserBin, firefoxLauncherBin, and systemctlBin are required")
	}
	if len(raw.Accounts) == 0 {
		return Config{}, errors.New("at least one account mapping is required")
	}
	for label, account := range raw.Accounts {
		if label == "" || account.FirefoxProfile == "" {
			return Config{}, errors.New("account labels and Firefox profiles must be non-empty")
		}
	}
	if len(raw.AllowedHosts) == 0 {
		return Config{}, errors.New("allowedHosts must not be empty")
	}
	for _, host := range raw.AllowedHosts {
		trimmed := strings.TrimPrefix(host, "*.")
		if trimmed == "" || strings.ContainsAny(trimmed, "/:@") {
			return Config{}, fmt.Errorf("invalid host pattern %q", host)
		}
	}

	return Config{
		PollInterval:       poll,
		LeadTime:           lead,
		Horizon:            horizon,
		Workspace:          raw.Workspace,
		AllowedHosts:       append([]string(nil), raw.AllowedHosts...),
		BrowserBin:         raw.BrowserBin,
		FirefoxLauncherBin: raw.FirefoxLauncherBin,
		SystemctlBin:       raw.SystemctlBin,
		Accounts:           raw.Accounts,
	}, nil
}
