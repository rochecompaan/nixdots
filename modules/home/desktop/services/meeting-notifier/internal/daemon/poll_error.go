package daemon

import "errors"

type PollErrorKind string

const (
	PollAuthentication PollErrorKind = "authentication"
	PollRateLimit      PollErrorKind = "rate-limit"
	PollTransient      PollErrorKind = "transient"
	PollPermanent      PollErrorKind = "permanent"
)

type PollError struct {
	Kind PollErrorKind
	Err  error
}

type InvalidPollError struct {
	Field string
}

func (e *InvalidPollError) Error() string { return "invalid poll " + e.Field }

func (e *PollError) Error() string {
	if e.Err == nil {
		return string(e.Kind)
	}
	return e.Err.Error()
}
func (e *PollError) Unwrap() error { return e.Err }

func pollErrorKind(err error) PollErrorKind {
	var failure *PollError
	if errors.As(err, &failure) && failure.Kind != "" {
		return failure.Kind
	}
	return PollPermanent
}
