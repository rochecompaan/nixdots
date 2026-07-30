package notifications

import (
	"context"
	"fmt"
	"sync"
	"time"

	"github.com/godbus/dbus/v5"
)

const (
	notificationDestination = "org.freedesktop.Notifications"
	notificationPath        = dbus.ObjectPath("/org/freedesktop/Notifications")
	notifyMethod            = notificationInterface + ".Notify"
	closeMethod             = notificationInterface + ".CloseNotification"
	operationTimeout        = 5 * time.Second
)

func notify(ctx context.Context, object dbusObject, request Request) (uint32, error) {
	callCtx, cancel := context.WithTimeout(ctx, operationTimeout)
	defer cancel()
	call := object.CallWithContext(callCtx, notifyMethod, 0,
		"meeting-notifier",
		request.ReplacesID,
		"",
		request.Summary,
		request.Body,
		request.Actions,
		map[string]dbus.Variant{},
		int32(-1),
	)
	var id uint32
	if err := call.Store(&id); err != nil {
		return 0, fmt.Errorf("notify: %w", err)
	}
	return id, nil
}

func closeNotification(ctx context.Context, object dbusObject, id uint32) error {
	callCtx, cancel := context.WithTimeout(ctx, operationTimeout)
	defer cancel()
	if err := object.CallWithContext(callCtx, closeMethod, 0, id).Store(); err != nil {
		return fmt.Errorf("close notification %d: %w", id, err)
	}
	return nil
}

type dbusObject interface {
	CallWithContext(context.Context, string, dbus.Flags, ...any) *dbus.Call
}

type dbusConnection interface {
	notificationObject() dbusObject
	addMatchSignal(context.Context, ...dbus.MatchOption) error
	signal(chan<- *dbus.Signal)
	removeSignal(chan<- *dbus.Signal)
	close() error
}

type sessionBusConnection struct {
	conn *dbus.Conn
}

func connectSessionBus() (dbusConnection, error) {
	conn, err := dbus.ConnectSessionBus(dbus.WithSignalHandler(newSignalHandler()))
	if err != nil {
		return nil, err
	}
	return &sessionBusConnection{conn: conn}, nil
}

func newSignalHandler() dbus.SignalHandler {
	return &blockingSignalHandler{targets: make(map[chan<- *dbus.Signal]*signalTarget)}
}

type blockingSignalHandler struct {
	mu      sync.Mutex
	closed  bool
	targets map[chan<- *dbus.Signal]*signalTarget
}

type signalTarget struct {
	channel chan<- *dbus.Signal
	done    chan struct{}
	active  sync.WaitGroup
}

func (h *blockingSignalHandler) AddSignal(channel chan<- *dbus.Signal) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.closed {
		return
	}
	h.targets[channel] = &signalTarget{channel: channel, done: make(chan struct{})}
}

func (h *blockingSignalHandler) RemoveSignal(channel chan<- *dbus.Signal) {
	h.mu.Lock()
	target := h.targets[channel]
	delete(h.targets, channel)
	if target != nil {
		close(target.done)
	}
	h.mu.Unlock()
	if target != nil {
		target.active.Wait()
	}
}

func (h *blockingSignalHandler) DeliverSignal(_ string, _ string, signal *dbus.Signal) {
	h.mu.Lock()
	targets := make([]*signalTarget, 0, len(h.targets))
	for _, target := range h.targets {
		target.active.Add(1)
		targets = append(targets, target)
	}
	h.mu.Unlock()

	for _, target := range targets {
		select {
		case target.channel <- signal:
		case <-target.done:
		}
		target.active.Done()
	}
}

func (h *blockingSignalHandler) Terminate() {
	h.mu.Lock()
	if h.closed {
		h.mu.Unlock()
		return
	}
	h.closed = true
	targets := make([]*signalTarget, 0, len(h.targets))
	for channel, target := range h.targets {
		delete(h.targets, channel)
		close(target.done)
		targets = append(targets, target)
	}
	h.mu.Unlock()
	for _, target := range targets {
		target.active.Wait()
		close(target.channel)
	}
}

func (c *sessionBusConnection) notificationObject() dbusObject {
	return c.conn.Object(notificationDestination, notificationPath)
}

func (c *sessionBusConnection) addMatchSignal(ctx context.Context, options ...dbus.MatchOption) error {
	return c.conn.AddMatchSignalContext(ctx, options...)
}

func (c *sessionBusConnection) signal(raw chan<- *dbus.Signal) {
	c.conn.Signal(raw)
}

func (c *sessionBusConnection) removeSignal(raw chan<- *dbus.Signal) {
	c.conn.RemoveSignal(raw)
}

func (c *sessionBusConnection) close() error {
	return c.conn.Close()
}
