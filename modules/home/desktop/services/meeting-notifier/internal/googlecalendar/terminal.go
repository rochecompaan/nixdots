package googlecalendar

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"strconv"
	"strings"

	"github.com/rochecompaan/nixdots/meeting-notifier/internal/storage"
)

type TerminalPrompter struct {
	input  *bufio.Reader
	output io.Writer
}

func NewTerminalPrompter(input io.Reader, output io.Writer) *TerminalPrompter {
	return &TerminalPrompter{input: bufio.NewReader(input), output: output}
}

func (p *TerminalPrompter) ConfirmIdentity(identity, label string) (bool, error) {
	if _, err := fmt.Fprintf(p.output, "Authenticated as %s for account %s. Type yes to confirm: ", identity, label); err != nil {
		return false, err
	}
	answer, err := p.readLine()
	if err != nil {
		return false, err
	}
	return strings.EqualFold(strings.TrimSpace(answer), "yes"), nil
}

func (p *TerminalPrompter) SelectCalendars(calendars []storage.CalendarRef) ([]storage.CalendarRef, error) {
	if len(calendars) == 0 {
		return nil, errors.New("no calendars are available")
	}
	if _, err := fmt.Fprintln(p.output, "Available calendars:"); err != nil {
		return nil, err
	}
	for index, calendar := range calendars {
		if _, err := fmt.Fprintf(p.output, "%d) %s\n", index+1, calendar.Summary); err != nil {
			return nil, err
		}
	}
	if _, err := fmt.Fprint(p.output, "Select calendar numbers separated by commas: "); err != nil {
		return nil, err
	}
	answer, err := p.readLine()
	if err != nil {
		return nil, err
	}
	parts := strings.Split(strings.TrimSpace(answer), ",")
	seen := make(map[int]struct{}, len(parts))
	selected := make([]storage.CalendarRef, 0, len(parts))
	for _, part := range parts {
		part = strings.TrimSpace(part)
		if part == "" {
			return nil, errors.New("calendar selection contains an empty number")
		}
		number, err := strconv.Atoi(part)
		if err != nil || number < 1 || number > len(calendars) {
			return nil, fmt.Errorf("calendar selection %q is out of range", part)
		}
		if _, duplicate := seen[number]; duplicate {
			return nil, fmt.Errorf("calendar number %d was selected more than once", number)
		}
		seen[number] = struct{}{}
		selected = append(selected, calendars[number-1])
	}
	if len(selected) == 0 {
		return nil, errors.New("at least one calendar must be selected")
	}
	return selected, nil
}

func (p *TerminalPrompter) readLine() (string, error) {
	line, err := p.input.ReadString('\n')
	if err != nil && !errors.Is(err, io.EOF) {
		return "", err
	}
	if errors.Is(err, io.EOF) && line == "" {
		return "", io.EOF
	}
	return line, nil
}
