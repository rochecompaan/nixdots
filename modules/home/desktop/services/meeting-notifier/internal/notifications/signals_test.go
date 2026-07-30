package notifications

import (
	"strings"
	"testing"

	"github.com/godbus/dbus/v5"
)

func TestDecodeSignal(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name string
		raw  *dbus.Signal
		want Signal
	}{
		{
			name: "action invoked",
			raw: &dbus.Signal{
				Name: "org.freedesktop.Notifications.ActionInvoked",
				Path: notificationPath,
				Body: []any{uint32(42), "join"},
			},
			want: Signal{Kind: ActionInvoked, ID: 42, ActionKey: "join"},
		},
		{
			name: "notification closed",
			raw: &dbus.Signal{
				Name: "org.freedesktop.Notifications.NotificationClosed",
				Path: notificationPath,
				Body: []any{uint32(42), uint32(2)},
			},
			want: Signal{Kind: NotificationClosed, ID: 42, Reason: 2},
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			got, err := decodeSignal(test.raw)
			if err != nil {
				t.Fatalf("decodeSignal() error = %v", err)
			}
			if got != test.want {
				t.Fatalf("decodeSignal() = %#v, want %#v", got, test.want)
			}
		})
	}
}

func TestDecodeSignalRejectsUnexpectedObjectPath(t *testing.T) {
	t.Parallel()

	for _, path := range []dbus.ObjectPath{"", "/org/example/Notifications"} {
		raw := &dbus.Signal{
			Name: actionInvokedSignal,
			Path: path,
			Body: []any{uint32(42), "join"},
		}
		if _, err := decodeSignal(raw); err == nil {
			t.Fatalf("decodeSignal(%#v) error = nil", raw)
		}
	}
}

func TestDecodeSignalRejectsMalformedAndUnknownBodies(t *testing.T) {
	t.Parallel()

	tests := []struct {
		raw  *dbus.Signal
		want string
	}{
		{nil, "signal is nil"},
		{&dbus.Signal{Name: actionInvokedSignal, Path: notificationPath, Body: []any{uint32(42)}}, "body has 1 fields"},
		{&dbus.Signal{Name: actionInvokedSignal, Path: notificationPath, Body: []any{"42", "join"}}, "notification ID has type string"},
		{&dbus.Signal{Name: notificationClosedSignal, Path: notificationPath, Body: []any{uint32(42), "dismissed"}}, "reason has type string"},
		{&dbus.Signal{Name: notificationInterface + ".Unknown", Path: notificationPath, Body: []any{uint32(42), "join"}}, "unknown signal"},
	}

	for _, test := range tests {
		_, err := decodeSignal(test.raw)
		if err == nil || !strings.Contains(err.Error(), test.want) {
			t.Fatalf("decodeSignal(%#v) error = %v, want %q", test.raw, err, test.want)
		}
	}
}
