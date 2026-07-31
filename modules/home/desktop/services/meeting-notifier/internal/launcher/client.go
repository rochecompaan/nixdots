package launcher

import (
	"context"
	"errors"
	"fmt"
	"os/exec"

	"github.com/rochecompaan/nixdots/meeting-notifier/internal/config"
	"github.com/rochecompaan/nixdots/meeting-notifier/internal/meeting"
)

// Launcher exit codes are the process protocol exposed by niri-firefox-launcher.
const (
	launcherExitWindowTimeout  = 20
	launcherExitCommandTimeout = 21
)

var (
	ErrWindowTimeout  = errors.New("Firefox window observation timed out")
	ErrCommandTimeout = errors.New("Niri launcher command timed out")
)

type Runner interface {
	Run(context.Context, string, ...string) error
}

type Client struct {
	launcherBin  string
	workspace    string
	allowedHosts []string
	runner       Runner
	transformURL func(string) (string, error)
}

func NewClient(cfg config.Config, runner Runner) Client {
	return Client{
		launcherBin:  cfg.FirefoxLauncherBin,
		workspace:    cfg.Workspace,
		allowedHosts: append([]string(nil), cfg.AllowedHosts...),
		runner:       runner,
		transformURL: meeting.ZoomWebClientURL,
	}
}

func NewOSClient(cfg config.Config) Client {
	return NewClient(cfg, osRunner{})
}

func (c Client) Open(ctx context.Context, profile, rawURL string) error {
	args := []string{"open-url", "--workspace", c.workspace, "--profile", profile, "--url"}
	validatedURL, err := meeting.ValidateURL(rawURL, c.allowedHosts)
	if err != nil {
		return fmt.Errorf("validate meeting URL: %w", err)
	}
	launchURL, err := c.transformURL(validatedURL)
	if err != nil {
		return fmt.Errorf("prepare meeting launch URL: %w", err)
	}
	launchURL, err = meeting.ValidateURL(launchURL, c.allowedHosts)
	if err != nil {
		return fmt.Errorf("validate meeting launch URL: %w", err)
	}
	if err := c.runner.Run(ctx, c.launcherBin, append(args, launchURL)...); err != nil {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		return classifyLauncherError(err)
	}
	return nil
}

func classifyLauncherError(err error) error {
	var exitErr *exec.ExitError
	if !errors.As(err, &exitErr) {
		return fmt.Errorf("open meeting URL: %w", err)
	}
	switch exitErr.ExitCode() {
	case launcherExitWindowTimeout:
		return fmt.Errorf("open meeting URL: %w", ErrWindowTimeout)
	case launcherExitCommandTimeout:
		return fmt.Errorf("open meeting URL: %w", ErrCommandTimeout)
	default:
		return fmt.Errorf("open meeting URL: %w", err)
	}
}
