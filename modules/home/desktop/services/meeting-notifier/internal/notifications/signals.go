package notifications

import (
	"fmt"

	"github.com/godbus/dbus/v5"
)

const (
	notificationInterface    = "org.freedesktop.Notifications"
	actionInvokedSignal      = notificationInterface + ".ActionInvoked"
	notificationClosedSignal = notificationInterface + ".NotificationClosed"
)

type SignalKind int

const (
	ActionInvoked SignalKind = iota + 1
	NotificationClosed
)

type Signal struct {
	Kind      SignalKind
	ID        uint32
	ActionKey string
	Reason    uint32
}

func decodeSignal(raw *dbus.Signal) (Signal, error) {
	if raw == nil {
		return Signal{}, fmt.Errorf("signal is nil")
	}
	if raw.Path != notificationPath {
		return Signal{}, fmt.Errorf("signal path %q, want %q", raw.Path, notificationPath)
	}
	if len(raw.Body) != 2 {
		return Signal{}, fmt.Errorf("%s body has %d fields, want 2", raw.Name, len(raw.Body))
	}
	id, ok := raw.Body[0].(uint32)
	if !ok {
		return Signal{}, fmt.Errorf("%s notification ID has type %T, want uint32", raw.Name, raw.Body[0])
	}

	switch raw.Name {
	case actionInvokedSignal:
		actionKey, ok := raw.Body[1].(string)
		if !ok {
			return Signal{}, fmt.Errorf("%s action key has type %T, want string", raw.Name, raw.Body[1])
		}
		return Signal{Kind: ActionInvoked, ID: id, ActionKey: actionKey}, nil
	case notificationClosedSignal:
		reason, ok := raw.Body[1].(uint32)
		if !ok {
			return Signal{}, fmt.Errorf("%s reason has type %T, want uint32", raw.Name, raw.Body[1])
		}
		return Signal{Kind: NotificationClosed, ID: id, Reason: reason}, nil
	default:
		return Signal{}, fmt.Errorf("unknown signal %q", raw.Name)
	}
}
