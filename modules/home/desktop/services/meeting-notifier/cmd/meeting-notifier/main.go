package main

import (
	"context"
	"fmt"
	"io"
	"os"
	"os/signal"
	"syscall"

	"github.com/rochecompaan/nixdots/meeting-notifier/internal/app"
)

func main() {
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	if code := reportResult(os.Stderr, app.Run(ctx, os.Args[1:])); code != 0 {
		os.Exit(code)
	}
}

func reportResult(stderr io.Writer, err error) int {
	if err == nil || app.IsCleanCancellation(err) {
		return 0
	}
	fmt.Fprintln(stderr, "meeting-notifier:", publicMessage(err))
	return 1
}

func publicMessage(err error) string { return app.PublicMessage(err) }
