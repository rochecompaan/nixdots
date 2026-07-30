package launcher

import (
	"os"
	"path/filepath"
	"strconv"
	"syscall"
	"testing"
	"time"
)

func TestOSProcessesStartCreatesDetachedProcessGroup(t *testing.T) {
	dir := t.TempDir()
	pidPath := filepath.Join(dir, "firefox.pid")
	script := filepath.Join(dir, "firefox")
	if err := os.WriteFile(script, []byte("#!/bin/sh\necho $$ > \"$PID_PATH\"\ntrap 'exit 0' TERM\nwhile :; do sleep 1; done\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PID_PATH", pidPath)
	if err := (osProcesses{}).Start(script, nil, nil); err != nil {
		t.Fatal(err)
	}
	pid := waitForProcessPID(t, pidPath)
	t.Cleanup(func() { _ = syscall.Kill(-pid, syscall.SIGTERM) })
	pgid, err := syscall.Getpgid(pid)
	if err != nil {
		t.Fatal(err)
	}
	if pgid != pid {
		t.Fatalf("Firefox process group = %d, want %d", pgid, pid)
	}
}

func waitForProcessPID(t *testing.T, path string) int {
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
	t.Fatal("timed out waiting for Firefox PID")
	return 0
}
