package activity

import (
	"context"
	"errors"
	"fmt"
	"reflect"
	"sync"
	"testing"
	"time"

	"github.com/godbus/dbus/v5"
)

var testSessionPath = dbus.ObjectPath("/org/freedesktop/login1/session/_42")

func TestReaderCurrentEvaluatesSessionActivity(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name     string
		active   bool
		idle     bool
		eligible bool
	}{
		{name: "active and not idle", active: true, eligible: true},
		{name: "active and idle", active: true, idle: true},
		{name: "inactive and not idle"},
		{name: "inactive and idle", idle: true},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()

			connection := newFakeConnection(test.active, test.idle)
			reader := newTestReader(connection)
			result, err := reader.Current(context.Background())
			if err != nil {
				t.Fatalf("Current() error = %v", err)
			}
			if result != (Result{Eligible: test.eligible}) {
				t.Fatalf("Current() result = %#v, want %#v", result, Result{Eligible: test.eligible})
			}
			if got, want := connection.objectCallsSnapshot(), []objectCall{
				{destination: logindDestination, path: managerPath},
				{destination: logindDestination, path: testSessionPath},
			}; !reflect.DeepEqual(got, want) {
				t.Errorf("DBus objects = %#v, want %#v", got, want)
			}
			if got, want := connection.manager.callsSnapshot(), []recordedCall{{
				method: getSessionMethod,
				args:   []any{"session-42"},
			}}; !reflect.DeepEqual(got, want) {
				t.Errorf("manager calls = %#v, want %#v", got, want)
			}
			if got, want := connection.session.callsSnapshot(), []recordedCall{
				{method: propertiesGetMethod, args: []any{sessionInterface, "Active"}},
				{method: propertiesGetMethod, args: []any{sessionInterface, "IdleHint"}},
			}; !reflect.DeepEqual(got, want) {
				t.Errorf("session calls = %#v, want %#v", got, want)
			}
		})
	}
}

func TestReaderCurrentFailsOpenOnLookupFailures(t *testing.T) {
	t.Parallel()

	lookupErr := errors.New("lookup failed")
	tests := []struct {
		name   string
		reader *Reader
	}{
		{
			name: "connect system bus",
			reader: &Reader{
				connect:   func() (dbusConnection, error) { return nil, lookupErr },
				sessionID: func() string { return "session-42" },
			},
		},
		{
			name: "connect returns nil connection",
			reader: &Reader{
				connect:   func() (dbusConnection, error) { return nil, nil },
				sessionID: func() string { return "session-42" },
			},
		},
		{
			name: "missing session ID",
			reader: &Reader{
				connect:   func() (dbusConnection, error) { return newFakeConnection(true, false), nil },
				sessionID: func() string { return "" },
			},
		},
		{
			name: "get session",
			reader: func() *Reader {
				connection := newFakeConnection(true, false)
				connection.manager.callErr = lookupErr
				return newTestReader(connection)
			}(),
		},
		{
			name: "read Active",
			reader: func() *Reader {
				connection := newFakeConnection(true, false)
				connection.session.propertyErrors[activeProperty] = lookupErr
				return newTestReader(connection)
			}(),
		},
		{
			name: "Active is not bool",
			reader: func() *Reader {
				connection := newFakeConnection(true, false)
				connection.session.propertyValues[activeProperty] = dbus.MakeVariant("true")
				return newTestReader(connection)
			}(),
		},
		{
			name: "read IdleHint",
			reader: func() *Reader {
				connection := newFakeConnection(true, false)
				connection.session.propertyErrors[idleHintProperty] = lookupErr
				return newTestReader(connection)
			}(),
		},
		{
			name: "IdleHint is not bool",
			reader: func() *Reader {
				connection := newFakeConnection(true, false)
				connection.session.propertyValues[idleHintProperty] = dbus.MakeVariant("false")
				return newTestReader(connection)
			}(),
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()

			result, err := test.reader.Current(context.Background())
			assertFailOpen(t, result, err)
		})
	}
}

func TestReaderCurrentFailsOpenWhenPropertyContextIsCanceled(t *testing.T) {
	t.Parallel()

	connection := newFakeConnection(true, false)
	entered := make(chan struct{})
	connection.session.onCall = func(ctx context.Context, method string, _ ...any) *dbus.Call {
		if method != propertiesGetMethod {
			return nil
		}
		close(entered)
		<-ctx.Done()
		return &dbus.Call{Err: ctx.Err()}
	}
	reader := newTestReader(connection)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	resultCh := make(chan currentResult, 1)
	go func() {
		result, err := reader.Current(ctx)
		resultCh <- currentResult{result: result, err: err}
	}()

	await(t, entered, "property lookup")
	cancel()
	got := await(t, resultCh, "canceled Current")
	assertFailOpen(t, got.result, got.err)
	if !errors.Is(got.err, context.Canceled) {
		t.Errorf("Current() error = %v, want context cancellation", got.err)
	}
}

func TestReaderCloseInterruptsBlockedCurrent(t *testing.T) {
	t.Parallel()

	connection := newFakeConnection(true, false)
	entered := make(chan struct{})
	release := make(chan struct{})
	var releaseOnce sync.Once
	t.Cleanup(func() { releaseOnce.Do(func() { close(release) }) })
	connection.session.onCall = func(_ context.Context, method string, _ ...any) *dbus.Call {
		if method != propertiesGetMethod {
			return nil
		}
		close(entered)
		select {
		case <-connection.closed:
			return &dbus.Call{Err: errors.New("connection closed")}
		case <-release:
			return &dbus.Call{Err: errors.New("test release")}
		}
	}
	reader := newTestReader(connection)
	current := make(chan currentResult, 1)
	go func() {
		result, err := reader.Current(context.Background())
		current <- currentResult{result: result, err: err}
	}()

	await(t, entered, "blocked property lookup")
	closeResult := make(chan error, 1)
	go func() { closeResult <- reader.Close() }()
	if err := await(t, closeResult, "Close while Current is blocked"); err != nil {
		t.Fatalf("Close() error = %v", err)
	}
	got := await(t, current, "Current after Close")
	assertFailOpen(t, got.result, got.err)
}

func TestReaderCloseDoesNotWaitForLazyConnection(t *testing.T) {
	t.Parallel()

	connection := newFakeConnection(true, false)
	entered := make(chan struct{})
	release := make(chan struct{})
	reader := &Reader{
		connect: func() (dbusConnection, error) {
			close(entered)
			<-release
			return connection, nil
		},
		sessionID: func() string { return "session-42" },
	}
	current := make(chan currentResult, 1)
	go func() {
		result, err := reader.Current(context.Background())
		current <- currentResult{result: result, err: err}
	}()

	await(t, entered, "lazy connection")
	if err := await(t, closeReader(reader), "Close during lazy connection"); err != nil {
		t.Fatalf("Close() error = %v", err)
	}
	close(release)
	got := await(t, current, "Current after lazy connection completes")
	assertFailOpen(t, got.result, got.err)
	if got := connection.closeCallCount(); got != 1 {
		t.Errorf("connection close calls = %d, want 1", got)
	}
}

func TestReaderCloseReturnsUnderlyingErrorOnce(t *testing.T) {
	t.Parallel()

	closeErr := errors.New("close failed")
	connection := newFakeConnection(true, false)
	connection.closeErr = closeErr
	reader := newTestReader(connection)
	if _, err := reader.Current(context.Background()); err != nil {
		t.Fatalf("Current() error = %v", err)
	}
	if err := reader.Close(); !errors.Is(err, closeErr) {
		t.Fatalf("first Close() error = %v, want %v", err, closeErr)
	}
	if err := reader.Close(); err != nil {
		t.Fatalf("second Close() error = %v, want nil", err)
	}
	if got := connection.closeCallCount(); got != 1 {
		t.Errorf("connection close calls = %d, want 1", got)
	}
}

func newTestReader(connection dbusConnection) *Reader {
	return &Reader{
		connect:   func() (dbusConnection, error) { return connection, nil },
		sessionID: func() string { return "session-42" },
	}
}

type currentResult struct {
	result Result
	err    error
}

type objectCall struct {
	destination string
	path        dbus.ObjectPath
}

type fakeConnection struct {
	mu          sync.Mutex
	manager     *fakeObject
	session     *fakeObject
	objectCalls []objectCall
	closed      chan struct{}
	closeOnce   sync.Once
	closeCalls  int
	closeErr    error
}

func newFakeConnection(active, idle bool) *fakeConnection {
	return &fakeConnection{
		manager: &fakeObject{callResult: testSessionPath},
		session: &fakeObject{
			propertyErrors: map[string]error{},
			propertyValues: map[string]dbus.Variant{
				activeProperty:   dbus.MakeVariant(active),
				idleHintProperty: dbus.MakeVariant(idle),
			},
		},
		closed: make(chan struct{}),
	}
}

func (c *fakeConnection) object(destination string, path dbus.ObjectPath) dbusObject {
	c.mu.Lock()
	c.objectCalls = append(c.objectCalls, objectCall{destination: destination, path: path})
	c.mu.Unlock()
	if path == managerPath {
		return c.manager
	}
	return c.session
}

func (c *fakeConnection) close() error {
	c.mu.Lock()
	c.closeCalls++
	err := c.closeErr
	c.mu.Unlock()
	c.closeOnce.Do(func() { close(c.closed) })
	return err
}

func (c *fakeConnection) objectCallsSnapshot() []objectCall {
	c.mu.Lock()
	defer c.mu.Unlock()
	return append([]objectCall(nil), c.objectCalls...)
}

func (c *fakeConnection) closeCallCount() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.closeCalls
}

type recordedCall struct {
	method string
	args   []any
}

type fakeObject struct {
	mu             sync.Mutex
	callResult     dbus.ObjectPath
	callErr        error
	calls          []recordedCall
	propertyValues map[string]dbus.Variant
	propertyErrors map[string]error
	onCall         func(context.Context, string, ...any) *dbus.Call
}

func (o *fakeObject) callWithContext(ctx context.Context, method string, _ dbus.Flags, args ...any) *dbus.Call {
	o.mu.Lock()
	o.calls = append(o.calls, recordedCall{method: method, args: append([]any(nil), args...)})
	onCall := o.onCall
	o.mu.Unlock()
	if onCall != nil {
		if call := onCall(ctx, method, args...); call != nil {
			return call
		}
	}
	if method == getSessionMethod {
		return &dbus.Call{Body: []any{o.callResult}, Err: o.callErr}
	}
	if method == propertiesGetMethod {
		property, _ := args[1].(string)
		if err := o.propertyErrors[property]; err != nil {
			return &dbus.Call{Err: err}
		}
		value, ok := o.propertyValues[property]
		if !ok {
			return &dbus.Call{Err: fmt.Errorf("unexpected property %q", property)}
		}
		return &dbus.Call{Body: []any{value}}
	}
	return &dbus.Call{Err: fmt.Errorf("unexpected method %q", method)}
}

func (o *fakeObject) callsSnapshot() []recordedCall {
	o.mu.Lock()
	defer o.mu.Unlock()
	return append([]recordedCall(nil), o.calls...)
}

func assertFailOpen(t *testing.T, result Result, err error) {
	t.Helper()
	if err == nil {
		t.Fatal("Current() error = nil, want non-nil")
	}
	if result != (Result{Eligible: true, Degraded: true}) {
		t.Fatalf("Current() result = %#v, want fail-open degraded result", result)
	}
}

func await[T any](t *testing.T, channel <-chan T, operation string) T {
	t.Helper()
	select {
	case value := <-channel:
		return value
	case <-time.After(time.Second):
		t.Fatalf("timed out waiting for %s", operation)
		var zero T
		return zero
	}
}

func closeReader(reader *Reader) <-chan error {
	result := make(chan error, 1)
	go func() { result <- reader.Close() }()
	return result
}
