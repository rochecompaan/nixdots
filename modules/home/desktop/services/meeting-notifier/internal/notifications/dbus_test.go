package notifications

import (
	"testing"
	"time"

	"github.com/godbus/dbus/v5"
)

func TestSignalHandlerBackpressuresAfterRawChannelCapacity(t *testing.T) {
	t.Parallel()

	handler := newSignalHandler()
	registrar, ok := handler.(dbus.SignalRegistrar)
	if !ok {
		t.Fatal("signal handler does not support channel registration")
	}
	raw := make(chan *dbus.Signal, rawSignalCapacity)
	registrar.AddSignal(raw)
	defer registrar.RemoveSignal(raw)

	for id := uint32(0); id < rawSignalCapacity; id++ {
		handler.DeliverSignal(notificationInterface, "ActionInvoked", &dbus.Signal{Body: []any{id, "join"}})
	}
	blocked := make(chan struct{})
	go func() {
		handler.DeliverSignal(notificationInterface, "ActionInvoked", &dbus.Signal{Body: []any{uint32(rawSignalCapacity), "join"}})
		close(blocked)
	}()

	select {
	case <-blocked:
		t.Fatal("signal handler did not backpressure at raw channel capacity")
	case <-time.After(50 * time.Millisecond):
	}

	first := <-raw
	if id := first.Body[0].(uint32); id != 0 {
		t.Fatalf("first signal ID = %d, want 0", id)
	}
	select {
	case <-blocked:
	case <-time.After(time.Second):
		t.Fatal("signal handler remained blocked after channel capacity became available")
	}
}

func TestSignalHandlerRemoveSignalReleasesBlockedDelivery(t *testing.T) {
	t.Parallel()

	handler := newSignalHandler()
	registrar := handler.(dbus.SignalRegistrar)
	raw := make(chan *dbus.Signal)
	registrar.AddSignal(raw)
	returned := deliverSignal(handler)
	assertBlocked(t, returned)

	removed := make(chan struct{})
	go func() {
		registrar.RemoveSignal(raw)
		close(removed)
	}()
	assertReturned(t, returned, "DeliverSignal after RemoveSignal")
	assertReturned(t, removed, "RemoveSignal")
}

func TestSignalHandlerTerminateReleasesBlockedDeliveryBeforeClosingChannel(t *testing.T) {
	t.Parallel()

	handler := newSignalHandler()
	registrar := handler.(dbus.SignalRegistrar)
	terminator := handler.(dbus.Terminator)
	raw := make(chan *dbus.Signal)
	registrar.AddSignal(raw)
	returned := deliverSignal(handler)
	assertBlocked(t, returned)

	terminated := make(chan struct{})
	go func() {
		terminator.Terminate()
		close(terminated)
	}()
	assertReturned(t, returned, "DeliverSignal after Terminate")
	assertReturned(t, terminated, "Terminate")
	if signal, ok := <-raw; ok || signal != nil {
		t.Fatalf("raw signal channel = (%#v, %t), want closed", signal, ok)
	}
}

func deliverSignal(handler dbus.SignalHandler) <-chan struct{} {
	returned := make(chan struct{})
	go func() {
		handler.DeliverSignal(notificationInterface, "ActionInvoked", &dbus.Signal{Path: notificationPath})
		close(returned)
	}()
	return returned
}

func assertBlocked(t *testing.T, returned <-chan struct{}) {
	t.Helper()
	select {
	case <-returned:
		t.Fatal("DeliverSignal did not block")
	case <-time.After(50 * time.Millisecond):
	}
}

func assertReturned(t *testing.T, returned <-chan struct{}, operation string) {
	t.Helper()
	select {
	case <-returned:
	case <-time.After(time.Second):
		t.Fatalf("%s did not return", operation)
	}
}
