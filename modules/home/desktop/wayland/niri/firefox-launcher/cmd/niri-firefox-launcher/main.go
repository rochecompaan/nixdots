package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"syscall"

	"github.com/rochecompaan/nixdots/niri-firefox-launcher/internal/launcher"
)

var errMissingBinaryEnvironment = errors.New("FIREFOX_BIN and NIRI_BIN must be set by the package wrapper")

// These exit codes are the stable process protocol consumed by meeting-notifier.
const (
	exitWindowTimeout  = 20
	exitCommandTimeout = 21
)

type commandService interface {
	LaunchProfile(context.Context, string, string) error
	OpenURL(context.Context, string, string, string) error
	FocusWorkspace(context.Context, string) error
}

type serviceFactory func(string, string) commandService

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if err := run(ctx, os.Args[1:], os.Getenv, func(firefoxBin, niriBin string) commandService {
		return launcher.NewOS(firefoxBin, niriBin)
	}); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(exitCode(err))
	}
}

func exitCode(err error) int {
	switch {
	case errors.Is(err, launcher.ErrWindowTimeout):
		return exitWindowTimeout
	case errors.Is(err, context.DeadlineExceeded):
		return exitCommandTimeout
	default:
		return 1
	}
}

func run(ctx context.Context, args []string, getenv func(string) string, factory serviceFactory) error {
	firefoxBin, niriBin := getenv("FIREFOX_BIN"), getenv("NIRI_BIN")
	if firefoxBin == "" || niriBin == "" {
		return errMissingBinaryEnvironment
	}
	if len(args) == 0 {
		return errors.New("command is required")
	}
	service := factory(firefoxBin, niriBin)
	switch args[0] {
	case "launch-profile":
		workspace, profile, err := parseProfileFlags(args[0], args[1:])
		if err != nil {
			return err
		}
		return service.LaunchProfile(ctx, workspace, profile)
	case "open-url":
		workspace, profile, rawURL, err := parseOpenURLFlags(args[1:])
		if err != nil {
			return err
		}
		return service.OpenURL(ctx, workspace, profile, rawURL)
	case "focus-workspace":
		workspace, err := parseWorkspaceFlags(args[0], args[1:])
		if err != nil {
			return err
		}
		return service.FocusWorkspace(ctx, workspace)
	default:
		return fmt.Errorf("unknown command %q", args[0])
	}
}

func parseProfileFlags(command string, args []string) (string, string, error) {
	flags := flag.NewFlagSet(command, flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	workspace := flags.String("workspace", "", "target workspace")
	profile := flags.String("profile", "", "Firefox profile")
	if err := flags.Parse(args); err != nil {
		return "", "", err
	}
	if flags.NArg() != 0 {
		return "", "", errors.New("unexpected positional arguments")
	}
	if *workspace == "" || *profile == "" {
		return "", "", errors.New("workspace and profile are required")
	}
	return *workspace, *profile, nil
}

func parseOpenURLFlags(args []string) (string, string, string, error) {
	flags := flag.NewFlagSet("open-url", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	workspace := flags.String("workspace", "", "target workspace")
	profile := flags.String("profile", "", "Firefox profile")
	rawURL := flags.String("url", "", "URL to open")
	if err := flags.Parse(args); err != nil {
		return "", "", "", err
	}
	if flags.NArg() != 0 {
		return "", "", "", errors.New("unexpected positional arguments")
	}
	if *workspace == "" || *profile == "" || *rawURL == "" {
		return "", "", "", errors.New("workspace, profile, and URL are required")
	}
	return *workspace, *profile, *rawURL, nil
}

func parseWorkspaceFlags(command string, args []string) (string, error) {
	flags := flag.NewFlagSet(command, flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	workspace := flags.String("workspace", "", "target workspace")
	if err := flags.Parse(args); err != nil {
		return "", err
	}
	if flags.NArg() != 0 {
		return "", errors.New("unexpected positional arguments")
	}
	if *workspace == "" {
		return "", errors.New("workspace is required")
	}
	return *workspace, nil
}
