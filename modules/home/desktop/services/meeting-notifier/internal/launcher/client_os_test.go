package launcher

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"syscall"
	"testing"
	"time"

	"github.com/rochecompaan/nixdots/meeting-notifier/internal/config"
)

func TestOSClientMapsLauncherExitProtocol(t *testing.T) {
	for code, want := range map[int]error{
		launcherExitWindowTimeout:  ErrWindowTimeout,
		launcherExitCommandTimeout: ErrCommandTimeout,
	} {
		t.Run(strconv.Itoa(code), func(t *testing.T) {
			launcher := writeExecutable(t, "launcher", "#!/bin/sh\nexit "+strconv.Itoa(code)+"\n")
			client := NewOSClient(config.Config{
				FirefoxLauncherBin: launcher,
				Workspace:          "5",
				AllowedHosts:       []string{"meet.google.com"},
			})

			err := client.Open(context.Background(), "clubhouse", "https://meet.google.com/abc-defg-hij")
			if !errors.Is(err, want) {
				t.Fatalf("error = %v, want %v", err, want)
			}
		})
	}
}

func TestOSRunnerTerminatesLauncherGroupWithoutKillingDetachedFirefox(t *testing.T) {
	if _, err := exec.LookPath("setsid"); err != nil {
		t.Skip("setsid is required for process-group integration test")
	}
	dir := t.TempDir()
	launcherPID := filepath.Join(dir, "launcher.pid")
	niriPID := filepath.Join(dir, "niri.pid")
	firefoxPID := filepath.Join(dir, "firefox.pid")
	niri := writeExecutable(t, "niri", "#!/bin/sh\necho $$ > \"$NIRI_PID\"\ntrap 'exit 0' TERM\nwhile :; do sleep 1; done\n")
	firefox := writeExecutable(t, "firefox", "#!/bin/sh\necho $$ > \"$FIREFOX_PID\"\ntrap 'exit 0' TERM\nwhile :; do sleep 1; done\n")
	launcher := writeExecutable(t, "launcher", "#!/bin/sh\n\"$NIRI\" &\nniri=$!\nsetsid \"$FIREFOX\" &\necho $$ > \"$LAUNCHER_PID\"\ntrap 'wait \"$niri\"; exit 0' TERM\nwait \"$niri\"\n")
	t.Setenv("LAUNCHER_PID", launcherPID)
	t.Setenv("NIRI_PID", niriPID)
	t.Setenv("FIREFOX_PID", firefoxPID)
	t.Setenv("NIRI", niri)
	t.Setenv("FIREFOX", firefox)

	client := NewOSClient(config.Config{
		FirefoxLauncherBin: launcher,
		Workspace:          "5",
		AllowedHosts:       []string{"meet.google.com"},
	})
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- client.Open(ctx, "clubhouse", "https://meet.google.com/abc-defg-hij") }()
	launcherProcess := waitForPID(t, launcherPID)
	niriProcess := waitForPID(t, niriPID)
	firefoxProcess := waitForPID(t, firefoxPID)
	t.Cleanup(func() {
		_ = syscall.Kill(-firefoxProcess, syscall.SIGTERM)
		_ = syscall.Kill(firefoxProcess, syscall.SIGTERM)
	})

	cancel()
	if err := <-done; !errors.Is(err, context.Canceled) {
		t.Fatalf("error = %v, want context cancellation", err)
	}
	waitForExited(t, launcherProcess)
	waitForExited(t, niriProcess)
	if err := syscall.Kill(firefoxProcess, 0); err != nil {
		t.Fatalf("detached Firefox was terminated: %v", err)
	}
}

func writeExecutable(t *testing.T, name, content string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), name)
	if err := os.WriteFile(path, []byte(content), 0o755); err != nil {
		t.Fatal(err)
	}
	return path
}

func waitForPID(t *testing.T, path string) int {
	t.Helper()
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		data, err := os.ReadFile(path)
		if err == nil {
			pid, err := strconv.Atoi(string(data[:len(data)-1]))
			if err != nil {
				t.Fatal(err)
			}
			return pid
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for PID file %s", path)
	return 0
}

func waitForExited(t *testing.T, pid int) {
	t.Helper()
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		if err := syscall.Kill(pid, 0); errors.Is(err, syscall.ESRCH) {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("process %d did not exit", pid)
}
