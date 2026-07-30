package notifications

import (
	"bytes"
	"context"
	"errors"
	"log/slog"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/godbus/dbus/v5"
)

func TestClientUsesExactFreedesktopNotifyArguments(t *testing.T) {
	t.Parallel()

	connection := newFakeConnection()
	connection.object.responseID = 17
	client := clientForTest(connection, slog.New(slog.NewTextHandler(&bytes.Buffer{}, nil)))
	ctx, cancel := context.WithCancel(context.Background())
	requests := []Request{
		{
			ReplacesID: 9,
			Summary:    "Planning",
			Body:       "Starts at 10:00 · upfront",
			Actions:    []string{"join", "Join"},
		},
		{
			Summary: "Authentication required",
			Body:    "Reconnect alpha",
			Actions: nil,
		},
	}
	commands := make(chan Command, len(requests))
	commands <- Command{Kind: NotifyCommand, OccurrenceKey: "occurrence", Request: requests[0]}
	events := make(chan Event)
	runErr := runClient(client, ctx, commands, events)
	connection.waitReady(t)

	for index, request := range requests {
		if index > 0 {
			commands <- Command{Kind: NotifyCommand, OccurrenceKey: "occurrence", Request: request}
		}
		event := receiveEvent(t, events)
		if event.Kind != NotificationDelivered || event.NotificationID != 17 {
			t.Fatalf("event = %#v", event)
		}
		if cap(event.DeliveryAck) != 1 {
			t.Fatalf("DeliveryAck capacity = %d, want 1", cap(event.DeliveryAck))
		}
		event.DeliveryAck <- DeliveryAck{Persisted: true}

		call := connection.object.waitCall(t, index)
		if call.method != notifyMethod {
			t.Fatalf("method = %q, want %q", call.method, notifyMethod)
		}
		wantArgs := []any{
			"meeting-notifier",
			request.ReplacesID,
			"",
			request.Summary,
			request.Body,
			request.Actions,
			map[string]dbus.Variant{},
			int32(-1),
		}
		if !reflect.DeepEqual(call.args, wantArgs) {
			t.Fatalf("Notify args = %#v, want %#v", call.args, wantArgs)
		}
		assertBoundedContext(t, call.ctx, operationTimeout)
	}

	cancel()
	if err := receiveError(t, runErr); !errors.Is(err, context.Canceled) {
		t.Fatalf("Run() error = %v, want context canceled", err)
	}
	if got := connection.stepSnapshot(); !reflect.DeepEqual(got[:3], []string{"signal", "add-match", "add-match"}) {
		t.Fatalf("subscription steps = %v", got)
	}
	if got := connection.stepSnapshot(); !reflect.DeepEqual(got[len(got)-2:], []string{"remove-signal", "close"}) {
		t.Fatalf("shutdown steps = %v", got)
	}
}

func TestClientCancelsBlockedSubscriptionAndCleansUp(t *testing.T) {
	t.Parallel()

	connection := newFakeConnection()
	connection.blockMatch = 1
	client := clientForTest(connection, slog.Default())
	ctx, cancel := context.WithCancel(context.Background())
	runErr := runClient(client, ctx, make(chan Command), make(chan Event))
	connection.waitMatchStarted(t)

	matchCtx := connection.matchContext(t, 0)
	assertBoundedContext(t, matchCtx, operationTimeout)
	cancel()
	err := receiveError(t, runErr)
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("Run() error = %v, want context canceled", err)
	}
	if got := connection.stepSnapshot(); !reflect.DeepEqual(got, []string{"signal", "add-match", "remove-signal", "close"}) {
		t.Fatalf("steps = %v", got)
	}
}

func TestClientCleansUpAfterSubscriptionFailure(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name        string
		failedMatch int
	}{
		{name: "first match", failedMatch: 1},
		{name: "second match", failedMatch: 2},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()

			matchErr := errors.New("subscribe failed")
			connection := newFakeConnection()
			connection.matchErrors = map[int]error{test.failedMatch: matchErr}
			client := clientForTest(connection, slog.Default())

			err := client.Run(context.Background(), make(chan Command), make(chan Event))
			if !errors.Is(err, matchErr) {
				t.Fatalf("Run() error = %v, want subscription error", err)
			}
			want := append([]string{"signal"}, make([]string, test.failedMatch)...)
			for index := 1; index <= test.failedMatch; index++ {
				want[index] = "add-match"
			}
			want = append(want, "remove-signal", "close")
			if got := connection.stepSnapshot(); !reflect.DeepEqual(got, want) {
				t.Fatalf("steps = %v, want %v", got, want)
			}
		})
	}
}

func TestClientOrdersDeliveryBeforeQueuedSignalAndAck(t *testing.T) {
	t.Parallel()

	connection := newFakeConnection()
	connection.object.responseID = 42
	connection.object.beforeReturn = func(method string) {
		if method == notifyMethod {
			connection.emit(t, &dbus.Signal{
				Name: actionInvokedSignal,
				Path: notificationPath,
				Body: []any{uint32(42), "join"},
			})
		}
	}
	client := clientForTest(connection, slog.Default())
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	commands := make(chan Command)
	events := make(chan Event)
	runErr := runClient(client, ctx, commands, events)
	connection.waitReady(t)

	commands <- Command{Kind: NotifyCommand, OccurrenceKey: "occ-42", Request: Request{Actions: []string{"join", "Join"}}}
	delivered := receiveEvent(t, events)
	if delivered.Kind != NotificationDelivered || delivered.OccurrenceKey != "occ-42" {
		t.Fatalf("first event = %#v", delivered)
	}
	if cap(delivered.DeliveryAck) != 1 {
		t.Fatalf("DeliveryAck capacity = %d, want 1", cap(delivered.DeliveryAck))
	}
	assertNoEvent(t, events)

	delivered.DeliveryAck <- DeliveryAck{Persisted: true}
	signalEvent := receiveEvent(t, events)
	wantSignal := Signal{Kind: ActionInvoked, ID: 42, ActionKey: "join"}
	if signalEvent.Kind != SignalReceived || signalEvent.Signal != wantSignal {
		t.Fatalf("second event = %#v, want signal %#v", signalEvent, wantSignal)
	}

	cancel()
	if err := receiveError(t, runErr); !errors.Is(err, context.Canceled) {
		t.Fatalf("Run() error = %v, want context canceled", err)
	}
}

func TestClientCancellationWhileAwaitingAckAllowsLateAck(t *testing.T) {
	t.Parallel()

	connection := newFakeConnection()
	connection.object.responseID = 23
	client := clientForTest(connection, slog.Default())
	ctx, cancel := context.WithCancel(context.Background())
	commands := make(chan Command)
	events := make(chan Event)
	runErr := runClient(client, ctx, commands, events)
	connection.waitReady(t)

	commands <- Command{Kind: NotifyCommand, OccurrenceKey: "occ-23"}
	delivered := receiveEvent(t, events)
	cancel()
	if err := receiveError(t, runErr); !errors.Is(err, context.Canceled) {
		t.Fatalf("Run() error = %v, want context canceled", err)
	}

	select {
	case delivered.DeliveryAck <- DeliveryAck{Persisted: true}:
	case <-time.After(time.Second):
		t.Fatal("late delivery acknowledgement blocked")
	}
}

func TestClientNegativeAckCompensatesOnceAndSuppressesQueuedAction(t *testing.T) {
	t.Parallel()

	persistErr := errors.New("persist delivery")
	closeErr := errors.New("compensating close")
	connection := newFakeConnection()
	connection.object.responseID = 42
	connection.object.methodErrors = map[string]error{closeMethod: closeErr}
	connection.object.beforeReturn = func(method string) {
		if method == notifyMethod {
			connection.emit(t, &dbus.Signal{
				Name: actionInvokedSignal,
				Path: notificationPath,
				Body: []any{uint32(42), "join"},
			})
		}
	}
	client := clientForTest(connection, slog.Default())
	type contextKey struct{}
	ctx := context.WithValue(context.Background(), contextKey{}, "dispatcher")
	commands := make(chan Command)
	events := make(chan Event)
	runErr := runClient(client, ctx, commands, events)
	connection.waitReady(t)

	commands <- Command{Kind: NotifyCommand, OccurrenceKey: "occ-42"}
	delivered := receiveEvent(t, events)
	delivered.DeliveryAck <- DeliveryAck{Persisted: false, Err: persistErr}

	err := receiveError(t, runErr)
	if !errors.Is(err, persistErr) || !errors.Is(err, closeErr) {
		t.Fatalf("Run() error = %v, want joined persistence and close errors", err)
	}
	assertNoEvent(t, events)

	calls := connection.object.callSnapshot()
	if len(calls) != 2 || calls[1].method != closeMethod {
		t.Fatalf("calls = %#v, want one Notify and one compensating CloseNotification", calls)
	}
	if !reflect.DeepEqual(calls[1].args, []any{uint32(42)}) {
		t.Fatalf("CloseNotification args = %#v", calls[1].args)
	}
	assertBoundedContext(t, calls[1].ctx, compensationTimeout)
	if got := calls[1].ctx.Value(contextKey{}); got != nil {
		t.Fatalf("compensation inherited dispatcher context value %v", got)
	}
}

func TestAwaitDeliveryAckCompensatesWhenCancellationFollowsAckSelection(t *testing.T) {
	t.Parallel()

	persistErr := errors.New("persist delivery")
	connection := newFakeConnection()
	ctx := newCancelAfterAckContext()
	connection.object.beforeReturn = func(method string) {
		if method == closeMethod {
			<-ctx.Done()
		}
	}
	ack := make(chan DeliveryAck)
	errCh := make(chan error, 1)
	go func() {
		errCh <- awaitDeliveryAck(ctx, connection.object, 42, ack)
	}()
	go ctx.sendAfterSelection(ack, DeliveryAck{Persisted: false, Err: persistErr})
	err := receiveError(t, errCh)
	if !errors.Is(err, persistErr) {
		t.Fatalf("awaitDeliveryAck() error = %v, want persistence error", err)
	}

	calls := connection.object.callSnapshot()
	if len(calls) != 1 || calls[0].method != closeMethod {
		t.Fatalf("calls = %#v, want one compensating CloseNotification", calls)
	}
	assertBoundedContext(t, calls[0].ctx, compensationTimeout)
}

func TestClientBackpressuresSignalDeliveryUntilConsumerOrCancellation(t *testing.T) {
	t.Parallel()

	connection := newFakeConnection()
	client := clientForTest(connection, slog.Default())
	ctx, cancel := context.WithCancel(context.Background())
	commands := make(chan Command)
	events := make(chan Event)
	runErr := runClient(client, ctx, commands, events)
	connection.waitReady(t)

	first := &dbus.Signal{Name: notificationClosedSignal, Path: notificationPath, Body: []any{uint32(7), uint32(2)}}
	connection.emit(t, first)
	assertNoRunResult(t, runErr)
	event := receiveEvent(t, events)
	if event.Kind != SignalReceived || event.Signal.ID != 7 {
		t.Fatalf("retained event = %#v", event)
	}

	connection.emit(t, &dbus.Signal{Name: notificationClosedSignal, Path: notificationPath, Body: []any{uint32(8), uint32(3)}})
	assertNoRunResult(t, runErr)
	cancel()
	if err := receiveError(t, runErr); !errors.Is(err, context.Canceled) {
		t.Fatalf("Run() error = %v, want context canceled", err)
	}
}

func TestClientLogsAndIgnoresMalformedAndUnknownSignals(t *testing.T) {
	t.Parallel()

	var logs bytes.Buffer
	connection := newFakeConnection()
	client := clientForTest(connection, slog.New(slog.NewTextHandler(&logs, nil)))
	ctx, cancel := context.WithCancel(context.Background())
	commands := make(chan Command)
	events := make(chan Event)
	runErr := runClient(client, ctx, commands, events)
	connection.waitReady(t)

	connection.emit(t, &dbus.Signal{Name: actionInvokedSignal, Path: notificationPath, Body: []any{uint32(42)}})
	connection.emit(t, &dbus.Signal{Name: "org.freedesktop.Notifications.Unknown", Path: notificationPath, Body: []any{uint32(42), "join"}})
	connection.emit(t, &dbus.Signal{Name: actionInvokedSignal, Body: []any{uint32(42), "join"}})
	connection.emit(t, &dbus.Signal{Name: actionInvokedSignal, Path: "/org/example/Notifications", Body: []any{uint32(42), "join"}})
	connection.emit(t, &dbus.Signal{Name: actionInvokedSignal, Path: notificationPath, Body: []any{uint32(42), "join"}})

	event := receiveEvent(t, events)
	if event.Kind != SignalReceived || event.Signal.ActionKey != "join" {
		t.Fatalf("event = %#v", event)
	}
	if count := strings.Count(logs.String(), "ignoring DBus signal"); count != 4 {
		t.Fatalf("ignored-signal log count = %d, want 4; logs: %s", count, logs.String())
	}

	cancel()
	if err := receiveError(t, runErr); !errors.Is(err, context.Canceled) {
		t.Fatalf("Run() error = %v, want context canceled", err)
	}
}

func TestClientReportsMethodFailuresWithExactCloseArguments(t *testing.T) {
	t.Parallel()

	notifyErr := errors.New("notify failed")
	closeErr := errors.New("close failed")
	connection := newFakeConnection()
	connection.object.methodErrors = map[string]error{
		notifyMethod: notifyErr,
		closeMethod:  closeErr,
	}
	client := clientForTest(connection, slog.Default())
	ctx, cancel := context.WithCancel(context.Background())
	commands := make(chan Command)
	events := make(chan Event)
	runErr := runClient(client, ctx, commands, events)
	connection.waitReady(t)

	commands <- Command{Kind: NotifyCommand, OccurrenceKey: "notify-occ"}
	notifyEvent := receiveEvent(t, events)
	if notifyEvent.Kind != NotificationFailed || notifyEvent.OccurrenceKey != "notify-occ" || !errors.Is(notifyEvent.Err, notifyErr) {
		t.Fatalf("notify event = %#v", notifyEvent)
	}

	commands <- Command{Kind: CloseCommand, OccurrenceKey: "close-occ", NotificationID: 91}
	closeEvent := receiveEvent(t, events)
	if closeEvent.Kind != NotificationFailed || closeEvent.NotificationID != 91 || !errors.Is(closeEvent.Err, closeErr) {
		t.Fatalf("close event = %#v", closeEvent)
	}
	calls := connection.object.callSnapshot()
	if !reflect.DeepEqual(calls[1].args, []any{uint32(91)}) {
		t.Fatalf("CloseNotification args = %#v, want [91]", calls[1].args)
	}

	cancel()
	if err := receiveError(t, runErr); !errors.Is(err, context.Canceled) {
		t.Fatalf("Run() error = %v, want context canceled", err)
	}
}

type recordedCall struct {
	ctx    context.Context
	method string
	args   []any
}

type cancelAfterAckContext struct {
	mu       sync.Mutex
	done     chan struct{}
	canceled bool
}

func newCancelAfterAckContext() *cancelAfterAckContext {
	return &cancelAfterAckContext{
		done: make(chan struct{}),
	}
}

func (c *cancelAfterAckContext) Deadline() (time.Time, bool) { return time.Time{}, false }

func (c *cancelAfterAckContext) Done() <-chan struct{} { return c.done }

func (c *cancelAfterAckContext) Err() error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.canceled {
		return context.Canceled
	}
	return nil
}

func (c *cancelAfterAckContext) Value(any) any { return nil }

func (c *cancelAfterAckContext) sendAfterSelection(ack chan<- DeliveryAck, result DeliveryAck) {
	c.mu.Lock()
	ack <- result
	c.canceled = true
	close(c.done)
	c.mu.Unlock()
}

type fakeObject struct {
	mu           sync.Mutex
	calls        []recordedCall
	responseID   uint32
	methodErrors map[string]error
	beforeReturn func(string)
}

func (o *fakeObject) CallWithContext(ctx context.Context, method string, _ dbus.Flags, args ...any) *dbus.Call {
	o.mu.Lock()
	o.calls = append(o.calls, recordedCall{ctx: ctx, method: method, args: append([]any(nil), args...)})
	index := len(o.calls) - 1
	beforeReturn := o.beforeReturn
	err := o.methodErrors[method]
	responseID := o.responseID
	o.mu.Unlock()

	if beforeReturn != nil {
		beforeReturn(method)
	}
	call := &dbus.Call{Err: err}
	if method == notifyMethod && err == nil {
		call.Body = []any{responseID}
	}
	o.mu.Lock()
	o.calls[index].ctx = ctx
	o.mu.Unlock()
	return call
}

func (o *fakeObject) waitCall(t *testing.T, index int) recordedCall {
	t.Helper()
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		calls := o.callSnapshot()
		if len(calls) > index {
			return calls[index]
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatalf("call %d was not recorded", index)
	return recordedCall{}
}

func (o *fakeObject) callSnapshot() []recordedCall {
	o.mu.Lock()
	defer o.mu.Unlock()
	return append([]recordedCall(nil), o.calls...)
}

type fakeConnection struct {
	mu            sync.Mutex
	object        *fakeObject
	raw           chan<- *dbus.Signal
	matches       int
	matchContexts []context.Context
	matchErrors   map[int]error
	blockMatch    int
	matchStarted  chan struct{}
	matchStartDo  sync.Once
	steps         []string
	ready         chan struct{}
	readyDo       sync.Once
}

func newFakeConnection() *fakeConnection {
	return &fakeConnection{
		object:       &fakeObject{},
		matchStarted: make(chan struct{}),
		ready:        make(chan struct{}),
	}
}

func (c *fakeConnection) notificationObject() dbusObject {
	return c.object
}

func (c *fakeConnection) addMatchSignal(ctx context.Context, _ ...dbus.MatchOption) error {
	c.mu.Lock()
	c.matches++
	match := c.matches
	c.matchContexts = append(c.matchContexts, ctx)
	c.steps = append(c.steps, "add-match")
	ready := c.raw != nil && c.matches == 2
	err := c.matchErrors[match]
	blocked := c.blockMatch == match
	c.mu.Unlock()
	if blocked {
		c.matchStartDo.Do(func() { close(c.matchStarted) })
		<-ctx.Done()
		return ctx.Err()
	}
	if ready {
		c.readyDo.Do(func() { close(c.ready) })
	}
	return err
}

func (c *fakeConnection) signal(raw chan<- *dbus.Signal) {
	c.mu.Lock()
	c.raw = raw
	c.steps = append(c.steps, "signal")
	ready := c.matches == 2
	c.mu.Unlock()
	if ready {
		c.readyDo.Do(func() { close(c.ready) })
	}
}

func (c *fakeConnection) removeSignal(chan<- *dbus.Signal) {
	c.recordStep("remove-signal")
}

func (c *fakeConnection) close() error {
	c.recordStep("close")
	return nil
}

func (c *fakeConnection) emit(t *testing.T, raw *dbus.Signal) {
	t.Helper()
	c.mu.Lock()
	ch := c.raw
	c.mu.Unlock()
	if ch == nil {
		t.Fatal("signal channel is not registered")
	}
	select {
	case ch <- raw:
	case <-time.After(time.Second):
		t.Fatal("sending raw DBus signal blocked")
	}
}

func (c *fakeConnection) waitReady(t *testing.T) {
	t.Helper()
	select {
	case <-c.ready:
		c.mu.Lock()
		capacity := cap(c.raw)
		c.mu.Unlock()
		if capacity != rawSignalCapacity {
			t.Fatalf("raw signal channel capacity = %d, want %d", capacity, rawSignalCapacity)
		}
	case <-time.After(time.Second):
		t.Fatal("client did not subscribe")
	}
}

func (c *fakeConnection) waitMatchStarted(t *testing.T) {
	t.Helper()
	select {
	case <-c.matchStarted:
	case <-time.After(time.Second):
		t.Fatal("subscription did not start")
	}
}

func (c *fakeConnection) matchContext(t *testing.T, index int) context.Context {
	t.Helper()
	c.mu.Lock()
	defer c.mu.Unlock()
	if len(c.matchContexts) <= index {
		t.Fatalf("match context %d was not recorded", index)
	}
	return c.matchContexts[index]
}

func (c *fakeConnection) recordStep(step string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.steps = append(c.steps, step)
}

func (c *fakeConnection) stepSnapshot() []string {
	c.mu.Lock()
	defer c.mu.Unlock()
	return append([]string(nil), c.steps...)
}

func clientForTest(connection *fakeConnection, logger *slog.Logger) *Client {
	return &Client{
		connect: func() (dbusConnection, error) { return connection, nil },
		logger:  logger,
	}
}

func runClient(client *Client, ctx context.Context, commands <-chan Command, events chan<- Event) <-chan error {
	errCh := make(chan error, 1)
	go func() {
		errCh <- client.Run(ctx, commands, events)
	}()
	return errCh
}

func receiveEvent(t *testing.T, events <-chan Event) Event {
	t.Helper()
	select {
	case event := <-events:
		return event
	case <-time.After(time.Second):
		t.Fatal("timed out waiting for event")
		return Event{}
	}
}

func receiveError(t *testing.T, errors <-chan error) error {
	t.Helper()
	select {
	case err := <-errors:
		return err
	case <-time.After(time.Second):
		t.Fatal("timed out waiting for Run result")
		return nil
	}
}

func assertNoEvent(t *testing.T, events <-chan Event) {
	t.Helper()
	select {
	case event := <-events:
		t.Fatalf("unexpected event: %#v", event)
	case <-time.After(50 * time.Millisecond):
	}
}

func assertNoRunResult(t *testing.T, result <-chan error) {
	t.Helper()
	select {
	case err := <-result:
		t.Fatalf("Run returned while delivery was blocked: %v", err)
	case <-time.After(50 * time.Millisecond):
	}
}

func assertBoundedContext(t *testing.T, ctx context.Context, limit time.Duration) {
	t.Helper()
	deadline, ok := ctx.Deadline()
	if !ok {
		t.Fatal("DBus call context has no deadline")
	}
	remaining := time.Until(deadline)
	if remaining <= 0 || remaining > limit {
		t.Fatalf("DBus deadline remaining = %v, want within (0, %v]", remaining, limit)
	}
}
