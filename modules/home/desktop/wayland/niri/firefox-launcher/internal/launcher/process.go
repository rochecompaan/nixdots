package launcher

import (
	"context"
	"io"
	"os"
	"os/exec"
	"strings"
	"syscall"
)

type osProcesses struct{}

func (osProcesses) Output(ctx context.Context, name string, args ...string) ([]byte, error) {
	return exec.CommandContext(ctx, name, args...).Output()
}

func (osProcesses) Run(ctx context.Context, name string, args ...string) error {
	command := exec.CommandContext(ctx, name, args...)
	command.Stdout = io.Discard
	command.Stderr = io.Discard
	return command.Run()
}

func (osProcesses) Start(name string, args, env []string) error {
	command := exec.Command(name, args...)
	command.Env = mergeEnvironment(os.Environ(), env)
	command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	command.Stdout = io.Discard
	command.Stderr = io.Discard
	if err := command.Start(); err != nil {
		return err
	}
	go func() { _ = command.Wait() }()
	return nil
}

func mergeEnvironment(base, overrides []string) []string {
	overridden := make(map[string]struct{}, len(overrides))
	for _, item := range overrides {
		key, _, _ := strings.Cut(item, "=")
		overridden[key] = struct{}{}
	}
	result := make([]string, 0, len(base)+len(overrides))
	for _, item := range base {
		key, _, _ := strings.Cut(item, "=")
		if _, replace := overridden[key]; !replace {
			result = append(result, item)
		}
	}
	return append(result, overrides...)
}
