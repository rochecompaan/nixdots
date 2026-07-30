package launcher

import (
	"context"
	"os/exec"
	"syscall"
	"time"
)

const terminationGrace = 2 * time.Second

type osRunner struct{}

func (osRunner) Run(ctx context.Context, name string, args ...string) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	command := exec.Command(name, args...)
	command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := command.Start(); err != nil {
		return err
	}
	wait := make(chan error, 1)
	go func() { wait <- command.Wait() }()

	select {
	case err := <-wait:
		if ctx.Err() != nil {
			return ctx.Err()
		}
		return err
	case <-ctx.Done():
		terminateProcessGroup(command.Process.Pid, syscall.SIGTERM)
		timer := time.NewTimer(terminationGrace)
		defer timer.Stop()
		select {
		case <-wait:
		case <-timer.C:
			terminateProcessGroup(command.Process.Pid, syscall.SIGKILL)
			<-wait
		}
		return ctx.Err()
	}
}

func terminateProcessGroup(pid int, signal syscall.Signal) {
	if pid > 0 {
		_ = syscall.Kill(-pid, signal)
	}
}
