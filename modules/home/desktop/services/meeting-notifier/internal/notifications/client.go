package notifications

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"time"

	"github.com/godbus/dbus/v5"
)

const (
	rawSignalCapacity             = 64
	CompensationTimeout           = 5 * time.Second
	CompensationCompletionTimeout = CompensationTimeout + time.Second
	compensationTimeout           = CompensationTimeout // compatibility for package tests
)

type Request struct {
	ReplacesID uint32
	Summary    string
	Body       string
	Actions    []string
}

type CommandKind int

const (
	NotifyCommand CommandKind = iota + 1
	CloseCommand
)

type Command struct {
	Kind           CommandKind
	OccurrenceKey  string
	AccountLabel   string
	Revision       uint64
	Request        Request
	NotificationID uint32
}

type EventKind int

const (
	NotificationDelivered EventKind = iota + 1
	NotificationFailed
	NotificationCommandCompleted
	SignalReceived
)

type DeliveryAck struct {
	Persisted bool
	Err       error
}

type Event struct {
	Kind           EventKind
	OccurrenceKey  string
	AccountLabel   string
	Revision       uint64
	NotificationID uint32
	Signal         Signal
	Err            error
	DeliveryAck    chan DeliveryAck
	Completion     chan error
}

type Transport interface {
	Run(context.Context, <-chan Command, chan<- Event) error
}

type Client struct {
	connect func() (dbusConnection, error)
	logger  *slog.Logger
}

func NewClient(logger *slog.Logger) *Client {
	return &Client{logger: logger}
}

func (c *Client) Run(ctx context.Context, commands <-chan Command, events chan<- Event) error {
	connect := c.connect
	if connect == nil {
		connect = connectSessionBus
	}
	logger := c.logger
	if logger == nil {
		logger = slog.Default()
	}

	conn, err := connect()
	if err != nil {
		return fmt.Errorf("connect to session bus: %w", err)
	}
	rawSignals := make(chan *dbus.Signal, rawSignalCapacity)
	conn.signal(rawSignals)
	if err := subscribe(ctx, conn); err != nil {
		conn.removeSignal(rawSignals)
		return errors.Join(err, conn.close())
	}

	dispatchErr := dispatch(ctx, conn.notificationObject(), commands, events, rawSignals, logger)
	conn.removeSignal(rawSignals)
	return errors.Join(dispatchErr, conn.close())
}

func subscribe(ctx context.Context, conn dbusConnection) error {
	setupCtx, cancel := context.WithTimeout(ctx, operationTimeout)
	defer cancel()
	for _, member := range []string{"ActionInvoked", "NotificationClosed"} {
		err := conn.addMatchSignal(
			setupCtx,
			dbus.WithMatchSender(notificationDestination),
			dbus.WithMatchObjectPath(notificationPath),
			dbus.WithMatchInterface(notificationInterface),
			dbus.WithMatchMember(member),
		)
		if err != nil {
			return fmt.Errorf("subscribe to %s: %w", member, err)
		}
	}
	return nil
}

func dispatch(
	ctx context.Context,
	object dbusObject,
	commands <-chan Command,
	events chan<- Event,
	rawSignals <-chan *dbus.Signal,
	logger *slog.Logger,
) error {
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case command, ok := <-commands:
			if !ok {
				commands = nil
				continue
			}
			if err := handleCommand(ctx, object, command, events); err != nil {
				return err
			}
		case raw, ok := <-rawSignals:
			if !ok {
				rawSignals = nil
				continue
			}
			signal, err := decodeSignal(raw)
			if err != nil {
				logger.Warn("ignoring DBus signal", "error", err)
				continue
			}
			if err := deliver(ctx, events, Event{Kind: SignalReceived, Signal: signal}); err != nil {
				return err
			}
		}
	}
}

func handleCommand(ctx context.Context, object dbusObject, command Command, events chan<- Event) error {
	switch command.Kind {
	case NotifyCommand:
		id, err := notify(ctx, object, command.Request)
		if err != nil {
			return deliverFailure(ctx, events, command, err)
		}
		ack := make(chan DeliveryAck, 1)
		completion := make(chan error, 1)
		event := Event{
			Kind:           NotificationDelivered,
			OccurrenceKey:  command.OccurrenceKey,
			AccountLabel:   command.AccountLabel,
			Revision:       command.Revision,
			NotificationID: id,
			DeliveryAck:    ack,
			Completion:     completion,
		}
		if err := deliver(ctx, events, event); err != nil {
			return err
		}
		result := awaitDeliveryAck(ctx, object, id, ack)
		completion <- result
		return result
	case CloseCommand:
		if err := closeNotification(ctx, object, command.NotificationID); err != nil {
			return deliverFailure(ctx, events, command, err)
		}
		return deliver(ctx, events, Event{Kind: NotificationCommandCompleted, OccurrenceKey: command.OccurrenceKey, NotificationID: command.NotificationID})
	default:
		return deliverFailure(ctx, events, command, fmt.Errorf("unknown notification command kind %d", command.Kind))
	}
}

func awaitDeliveryAck(ctx context.Context, object dbusObject, id uint32, ack <-chan DeliveryAck) error {
	select {
	case <-ctx.Done():
		return ctx.Err()
	case result, ok := <-ack:
		if ok && result.Persisted {
			return nil
		}
		persistErr := result.Err
		if !ok || persistErr == nil {
			persistErr = errors.New("notification delivery was not persisted")
		}
		compensationCtx, cancel := context.WithTimeout(context.Background(), CompensationTimeout)
		defer cancel()
		closeErr := closeNotification(compensationCtx, object, id)
		return errors.Join(persistErr, closeErr)
	}
}

func deliverFailure(ctx context.Context, events chan<- Event, command Command, err error) error {
	return deliver(ctx, events, Event{
		Kind:           NotificationFailed,
		OccurrenceKey:  command.OccurrenceKey,
		AccountLabel:   command.AccountLabel,
		Revision:       command.Revision,
		NotificationID: command.NotificationID,
		Err:            err,
	})
}

func deliver(ctx context.Context, events chan<- Event, event Event) error {
	select {
	case events <- event:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}
