package daemon

import "log/slog"

type Diagnostic struct {
	Component    string
	AccountLabel string
	Category     string
}

type DiagnosticSink interface {
	Report(Diagnostic)
}

type slogDiagnosticSink struct {
	logger *slog.Logger
}

func NewSlogDiagnosticSink(logger *slog.Logger) DiagnosticSink {
	if logger == nil {
		logger = slog.Default()
	}
	return slogDiagnosticSink{logger: logger}
}

func (s slogDiagnosticSink) Report(item Diagnostic) {
	attributes := []any{"component", item.Component}
	if item.AccountLabel != "" {
		attributes = append(attributes, "account", item.AccountLabel)
	}
	attributes = append(attributes, "category", item.Category)
	s.logger.Warn("meeting notifier degraded", attributes...)
}
