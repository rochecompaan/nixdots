package activity

import (
	"context"
	"errors"
	"fmt"
	"os"
	"sync"

	"github.com/godbus/dbus/v5"
)

const (
	logindDestination   = "org.freedesktop.login1"
	sessionInterface    = logindDestination + ".Session"
	getSessionMethod    = logindDestination + ".Manager.GetSession"
	propertiesGetMethod = "org.freedesktop.DBus.Properties.Get"
	activeProperty      = "Active"
	idleHintProperty    = "IdleHint"
)

var managerPath = dbus.ObjectPath("/org/freedesktop/login1")

type Result struct {
	Eligible bool
	Degraded bool
}

type Reader struct {
	mu          sync.Mutex
	connect     func() (dbusConnection, error)
	sessionID   func() string
	conn        dbusConnection
	connecting  bool
	connectDone chan struct{}
	closed      bool
}

func NewReader() *Reader {
	return &Reader{
		connect:   connectSystemBus,
		sessionID: func() string { return os.Getenv("XDG_SESSION_ID") },
	}
}

func (r *Reader) Current(ctx context.Context) (Result, error) {
	r.mu.Lock()
	if r.closed {
		r.mu.Unlock()
		err := fmt.Errorf("logind reader is closed")
		return evaluate(false, false, err), err
	}
	sessionID := r.sessionID
	r.mu.Unlock()

	if sessionID == nil {
		err := fmt.Errorf("read XDG_SESSION_ID: session ID reader is nil")
		return evaluate(false, false, err), err
	}
	id := sessionID()
	if id == "" {
		err := fmt.Errorf("read XDG_SESSION_ID: not set")
		return evaluate(false, false, err), err
	}

	conn, err := r.connection(ctx)
	if err != nil {
		return evaluate(false, false, err), err
	}
	active, idle, err := readSession(ctx, conn, id)
	if err != nil {
		return evaluate(active, idle, err), err
	}
	return evaluate(active, idle, nil), nil
}

func (r *Reader) Close() error {
	r.mu.Lock()
	if r.closed {
		r.mu.Unlock()
		return nil
	}
	r.closed = true
	conn := r.conn
	r.conn = nil
	r.mu.Unlock()

	if conn == nil {
		return nil
	}
	return conn.close()
}

func (r *Reader) connection(ctx context.Context) (dbusConnection, error) {
	for {
		r.mu.Lock()
		if r.closed {
			r.mu.Unlock()
			return nil, fmt.Errorf("logind reader is closed")
		}
		if r.conn != nil {
			conn := r.conn
			r.mu.Unlock()
			return conn, nil
		}
		if r.connecting {
			done := r.connectDone
			r.mu.Unlock()
			select {
			case <-done:
				continue
			case <-ctx.Done():
				return nil, fmt.Errorf("wait for system bus connection: %w", ctx.Err())
			}
		}
		connect := r.connect
		if connect == nil {
			connect = connectSystemBus
		}
		r.connecting = true
		r.connectDone = make(chan struct{})
		done := r.connectDone
		r.mu.Unlock()

		conn, err := connect()
		closeConn := false
		r.mu.Lock()
		r.connecting = false
		r.connectDone = nil
		if err == nil && conn != nil && !r.closed {
			r.conn = conn
		} else if conn != nil {
			closeConn = true
		}
		closed := r.closed
		close(done)
		r.mu.Unlock()

		if closeConn {
			closeErr := conn.close()
			if err != nil {
				err = errors.Join(err, closeErr)
			} else if closed {
				err = errors.Join(fmt.Errorf("logind reader is closed"), closeErr)
			}
		}
		if err != nil {
			return nil, fmt.Errorf("connect to system bus: %w", err)
		}
		if conn == nil {
			return nil, fmt.Errorf("connect to system bus: nil connection")
		}
		if closed {
			return nil, fmt.Errorf("logind reader is closed")
		}
		return conn, nil
	}
}

func evaluate(active, idle bool, err error) Result {
	if err != nil {
		return Result{Eligible: true, Degraded: true}
	}
	return Result{Eligible: active && !idle}
}

func readSession(ctx context.Context, conn dbusConnection, sessionID string) (bool, bool, error) {
	manager := conn.object(logindDestination, managerPath)
	var sessionPath dbus.ObjectPath
	if err := manager.callWithContext(ctx, getSessionMethod, 0, sessionID).Store(&sessionPath); err != nil {
		return false, false, fmt.Errorf("get logind session %q: %w", sessionID, err)
	}

	session := conn.object(logindDestination, sessionPath)
	active, err := boolProperty(ctx, session, activeProperty)
	if err != nil {
		return false, false, err
	}
	idle, err := boolProperty(ctx, session, idleHintProperty)
	if err != nil {
		return active, false, err
	}
	return active, idle, nil
}

func boolProperty(ctx context.Context, session dbusObject, property string) (bool, error) {
	var variant dbus.Variant
	if err := session.callWithContext(ctx, propertiesGetMethod, 0, sessionInterface, property).Store(&variant); err != nil {
		return false, fmt.Errorf("read logind property %s: %w", property, err)
	}
	value, ok := variant.Value().(bool)
	if !ok {
		return false, fmt.Errorf("logind property %s has type %T, want bool", property, variant.Value())
	}
	return value, nil
}

type dbusConnection interface {
	object(string, dbus.ObjectPath) dbusObject
	close() error
}

type dbusObject interface {
	callWithContext(context.Context, string, dbus.Flags, ...any) *dbus.Call
}

type systemBusConnection struct {
	conn *dbus.Conn
}

func connectSystemBus() (dbusConnection, error) {
	conn, err := dbus.ConnectSystemBus()
	if err != nil {
		return nil, err
	}
	return &systemBusConnection{conn: conn}, nil
}

func (c *systemBusConnection) object(destination string, path dbus.ObjectPath) dbusObject {
	return systemBusObject{object: c.conn.Object(destination, path)}
}

func (c *systemBusConnection) close() error {
	return c.conn.Close()
}

type systemBusObject struct {
	object dbus.BusObject
}

func (o systemBusObject) callWithContext(ctx context.Context, method string, flags dbus.Flags, args ...any) *dbus.Call {
	return o.object.CallWithContext(ctx, method, flags, args...)
}
