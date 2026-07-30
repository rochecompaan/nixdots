package launcher

import (
	"context"
	"errors"
	"reflect"
	"strings"
	"testing"
	"time"
)

type processCall struct {
	kind string
	name string
	args []string
	env  []string
}

type fakeProcesses struct {
	outputs   map[string][][]byte
	runErrors map[string]error
	calls     []processCall
}

func (f *fakeProcesses) Output(_ context.Context, name string, args ...string) ([]byte, error) {
	f.calls = append(f.calls, processCall{kind: "output", name: name, args: append([]string(nil), args...)})
	key := strings.Join(args, " ")
	queue := f.outputs[key]
	if len(queue) == 0 {
		return nil, errors.New("unexpected output call: " + key)
	}
	result := queue[0]
	f.outputs[key] = queue[1:]
	return result, nil
}

func (f *fakeProcesses) Run(_ context.Context, name string, args ...string) error {
	f.calls = append(f.calls, processCall{kind: "run", name: name, args: append([]string(nil), args...)})
	return f.runErrors[strings.Join(args, " ")]
}

func (f *fakeProcesses) Start(name string, args, env []string) error {
	f.calls = append(f.calls, processCall{
		kind: "start",
		name: name,
		args: append([]string(nil), args...),
		env:  append([]string(nil), env...),
	})
	return nil
}

type fakeClock struct {
	now    time.Time
	sleeps []time.Duration
}

func (f *fakeClock) Now() time.Time { return f.now }
func (f *fakeClock) Sleep(_ context.Context, duration time.Duration) error {
	f.sleeps = append(f.sleeps, duration)
	f.now = f.now.Add(duration)
	return nil
}

func newTestLauncher(processes *fakeProcesses, clock *fakeClock) *Launcher {
	result := New("/firefox", "/niri", processes)
	result.now = clock.Now
	result.sleep = clock.Sleep
	result.pollInterval = 5 * time.Second
	result.windowTimeout = 15 * time.Second
	result.restoreSettle = 2 * time.Second
	return result
}

func TestLaunchProfileMovesEveryRestoredWindowWithoutFocus(t *testing.T) {
	processes := &fakeProcesses{outputs: map[string][][]byte{
		"msg --json workspaces": {[]byte(`[{"id":6,"idx":6,"name":"6","output":"DP-1","active_window_id":null}]`)},
		"msg --json windows": {
			[]byte(windowsFixture),
			[]byte(windowsFixture[:len(windowsFixture)-1] + `,{"id":70,"app_id":"firefox-profile-clubhouse","pid":300000,"workspace_id":6}]`),
			[]byte(windowsFixture[:len(windowsFixture)-1] + `,{"id":70,"app_id":"firefox-profile-clubhouse","pid":300000,"workspace_id":6},{"id":71,"app_id":"firefox-profile-clubhouse","pid":300000,"workspace_id":6}]`),
		},
	}}
	clock := &fakeClock{}
	client := newTestLauncher(processes, clock)

	if err := client.LaunchProfile(context.Background(), "6", "clubhouse"); err != nil {
		t.Fatal(err)
	}

	start := callsOfKind(processes.calls, "start")
	wantStart := []processCall{{
		kind: "start",
		name: "/firefox",
		args: []string{"--new-instance", "-P", "clubhouse"},
		env: []string{
			"MOZ_APP_REMOTINGNAME=firefox-profile-clubhouse",
			"MOZ_APP_LAUNCHER=firefox-profile-clubhouse",
		},
	}}
	if !reflect.DeepEqual(start, wantStart) {
		t.Fatalf("Firefox start = %#v, want %#v", start, wantStart)
	}
	if got, want := clock.sleeps, []time.Duration{2 * time.Second}; !reflect.DeepEqual(got, want) {
		t.Fatalf("sleeps = %v, want %v", got, want)
	}
	wantActions := [][]string{
		{"msg", "action", "move-window-to-monitor", "--id", "70", "DP-1"},
		{"msg", "action", "move-window-to-workspace", "--window-id", "70", "--focus", "false", "6"},
		{"msg", "action", "move-window-to-monitor", "--id", "71", "DP-1"},
		{"msg", "action", "move-window-to-workspace", "--window-id", "71", "--focus", "false", "6"},
	}
	assertActionArgs(t, processes.calls, wantActions)
}

func TestOpenURLMovesAndFocusesOnlyNewMatchingWindow(t *testing.T) {
	rawURL := `https://clubhouse.zoom.us/j/123?next=$HOME;printf%20pwned`
	processes := &fakeProcesses{outputs: map[string][][]byte{
		"msg --json workspaces": {[]byte(workspaceFixture)},
		"msg --json windows": {
			[]byte(windowsFixture),
			[]byte(windowsFixture[:len(windowsFixture)-1] + `,{"id":60,"app_id":"other","pid":300000,"workspace_id":5}]`),
			[]byte(windowsFixture[:len(windowsFixture)-1] + `,{"id":60,"app_id":"other","pid":300000,"workspace_id":5},{"id":61,"app_id":"firefox-profile-clubhouse","pid":300001,"workspace_id":5}]`),
		},
	}}
	clock := &fakeClock{}
	client := newTestLauncher(processes, clock)

	if err := client.OpenURL(context.Background(), "5", "clubhouse", rawURL); err != nil {
		t.Fatal(err)
	}

	start := callsOfKind(processes.calls, "start")
	wantStart := []processCall{{
		kind: "start",
		name: "/firefox",
		args: []string{"-P", "clubhouse", "--new-window", rawURL},
		env: []string{
			"MOZ_APP_REMOTINGNAME=firefox-profile-clubhouse",
			"MOZ_APP_LAUNCHER=firefox-profile-clubhouse",
		},
	}}
	if !reflect.DeepEqual(start, wantStart) {
		t.Fatalf("Firefox start = %#v, want %#v", start, wantStart)
	}
	wantActions := [][]string{
		{"msg", "action", "move-window-to-monitor", "--id", "61", "HDMI-A-1"},
		{"msg", "action", "move-window-to-workspace", "--window-id", "61", "--focus", "false", "5"},
		{"msg", "action", "focus-monitor", "HDMI-A-1"},
		{"msg", "action", "focus-workspace", "5"},
		{"msg", "action", "focus-window", "--id", "61"},
	}
	assertActionArgs(t, processes.calls, wantActions)
}

func TestOpenURLDoesNotFocusWhenPlacementFails(t *testing.T) {
	processes := &fakeProcesses{
		outputs: map[string][][]byte{
			"msg --json workspaces": {[]byte(workspaceFixture)},
			"msg --json windows": {
				[]byte(windowsFixture),
				[]byte(windowsFixture[:len(windowsFixture)-1] + `,{"id":61,"app_id":"firefox-profile-clubhouse"}]`),
			},
		},
		runErrors: map[string]error{
			"msg action move-window-to-monitor --id 61 HDMI-A-1": errors.New("move failed"),
		},
	}
	client := newTestLauncher(processes, &fakeClock{})

	err := client.OpenURL(context.Background(), "5", "clubhouse", "https://meet.google.com/abc-defg-hij")
	if err == nil || !strings.Contains(err.Error(), "move-window-to-monitor") {
		t.Fatalf("error = %v, want wrapped move error", err)
	}
	assertActionArgs(t, processes.calls, [][]string{
		{"msg", "action", "move-window-to-monitor", "--id", "61", "HDMI-A-1"},
		{"msg", "action", "move-window-to-workspace", "--window-id", "61", "--focus", "false", "5"},
	})
}

func TestLaunchProfileAttemptsBothPlacementActionsWhenMonitorMoveFails(t *testing.T) {
	processes := &fakeProcesses{
		outputs: map[string][][]byte{
			"msg --json workspaces": {[]byte(`[{"idx":6,"name":"6","output":"DP-1"}]`)},
			"msg --json windows": {
				[]byte(windowsFixture),
				[]byte(windowsFixture[:len(windowsFixture)-1] + `,{"id":70,"app_id":"firefox-profile-clubhouse"}]`),
				[]byte(windowsFixture[:len(windowsFixture)-1] + `,{"id":70,"app_id":"firefox-profile-clubhouse"}]`),
			},
		},
		runErrors: map[string]error{
			"msg action move-window-to-monitor --id 70 DP-1": errors.New("monitor move failed"),
		},
	}
	client := newTestLauncher(processes, &fakeClock{})

	if err := client.LaunchProfile(context.Background(), "6", "clubhouse"); err != nil {
		t.Fatal(err)
	}
	assertActionArgs(t, processes.calls, [][]string{
		{"msg", "action", "move-window-to-monitor", "--id", "70", "DP-1"},
		{"msg", "action", "move-window-to-workspace", "--window-id", "70", "--focus", "false", "6"},
	})
}

func TestOpenURLDoesNotFocusWhenWorkspacePlacementFails(t *testing.T) {
	processes := &fakeProcesses{
		outputs: map[string][][]byte{
			"msg --json workspaces": {[]byte(workspaceFixture)},
			"msg --json windows": {
				[]byte(windowsFixture),
				[]byte(windowsFixture[:len(windowsFixture)-1] + `,{"id":61,"app_id":"firefox-profile-clubhouse"}]`),
			},
		},
		runErrors: map[string]error{
			"msg action move-window-to-workspace --window-id 61 --focus false 5": errors.New("workspace move failed"),
		},
	}
	client := newTestLauncher(processes, &fakeClock{})

	err := client.OpenURL(context.Background(), "5", "clubhouse", "https://meet.google.com/abc-defg-hij")
	if err == nil || !strings.Contains(err.Error(), "move-window-to-workspace") {
		t.Fatalf("error = %v, want wrapped workspace move error", err)
	}
	assertActionArgs(t, processes.calls, [][]string{
		{"msg", "action", "move-window-to-monitor", "--id", "61", "HDMI-A-1"},
		{"msg", "action", "move-window-to-workspace", "--window-id", "61", "--focus", "false", "5"},
	})
}

func TestOpenURLTimeoutDoesNotRelaunchOrAct(t *testing.T) {
	processes := &fakeProcesses{outputs: map[string][][]byte{
		"msg --json workspaces": {[]byte(workspaceFixture)},
		"msg --json windows": {
			[]byte(windowsFixture),
			[]byte(windowsFixture),
			[]byte(windowsFixture),
			[]byte(windowsFixture),
		},
	}}
	clock := &fakeClock{}
	client := newTestLauncher(processes, clock)

	err := client.OpenURL(context.Background(), "5", "clubhouse", "https://meet.google.com/abc-defg-hij")
	if !errors.Is(err, ErrWindowTimeout) {
		t.Fatalf("error = %v, want ErrWindowTimeout", err)
	}
	if got := len(callsOfKind(processes.calls, "start")); got != 1 {
		t.Fatalf("Firefox starts = %d, want 1", got)
	}
	if got, want := clock.sleeps, []time.Duration{5 * time.Second, 5 * time.Second, 5 * time.Second}; !reflect.DeepEqual(got, want) {
		t.Fatalf("timeout sleeps = %v, want %v", got, want)
	}
	assertActionArgs(t, processes.calls, nil)
}

func TestNewLaunchProfileTimeoutUsesProductionDefaults(t *testing.T) {
	processes := &fakeProcesses{outputs: map[string][][]byte{
		"msg --json workspaces": {[]byte(`[{"idx":6,"name":"6","output":"DP-1"}]`)},
		"msg --json windows":    timeoutWindows(61),
	}}
	clock := &fakeClock{}
	client := New("/firefox", "/niri", processes)
	if client.pollInterval != 250*time.Millisecond || client.windowTimeout != 15*time.Second || client.restoreSettle != 2*time.Second {
		t.Fatalf("New timings = (%v, %v, %v)", client.pollInterval, client.windowTimeout, client.restoreSettle)
	}
	client.now = clock.Now
	client.sleep = clock.Sleep

	if err := client.LaunchProfile(context.Background(), "6", "clubhouse"); err != nil {
		t.Fatal(err)
	}
	if got := len(callsOfKind(processes.calls, "start")); got != 1 {
		t.Fatalf("Firefox starts = %d, want 1", got)
	}
	if got, want := clock.sleeps, repeatDuration(250*time.Millisecond, 60); !reflect.DeepEqual(got, want) {
		t.Fatalf("timeout sleeps = %v, want %v", got, want)
	}
	assertActionArgs(t, processes.calls, nil)
}

type blockingProcesses struct {
	fakeProcesses
	blockOutputAfter int
	outputCalls      int
	blockRun         bool
	blocked          chan struct{}
}

func (f *blockingProcesses) Output(ctx context.Context, name string, args ...string) ([]byte, error) {
	f.outputCalls++
	if f.outputCalls > f.blockOutputAfter {
		f.blocked <- struct{}{}
		<-ctx.Done()
		return nil, ctx.Err()
	}
	return f.fakeProcesses.Output(ctx, name, args...)
}

func (f *blockingProcesses) Run(ctx context.Context, name string, args ...string) error {
	if f.blockRun {
		f.calls = append(f.calls, processCall{kind: "run", name: name, args: append([]string(nil), args...)})
		f.blocked <- struct{}{}
		<-ctx.Done()
		return ctx.Err()
	}
	return f.fakeProcesses.Run(ctx, name, args...)
}

func TestObservationBoundsBlockedNiriQuery(t *testing.T) {
	processes := &blockingProcesses{
		fakeProcesses: fakeProcesses{outputs: map[string][][]byte{
			"msg --json workspaces": {[]byte(`[{"idx":5,"name":"5","output":"HDMI-A-1"}]`)},
			"msg --json windows":    {[]byte(windowsFixture)},
		}},
		blockOutputAfter: 2,
		blocked:          make(chan struct{}, 1),
	}
	client := New("/firefox", "/niri", processes)
	client.windowTimeout = 20 * time.Millisecond
	client.commandTimeout = time.Second

	err := client.OpenURL(context.Background(), "5", "clubhouse", "https://meet.google.com/abc-defg-hij")
	if !errors.Is(err, context.DeadlineExceeded) || !strings.Contains(err.Error(), "query Niri windows") {
		t.Fatalf("error = %v, want wrapped observation timeout", err)
	}
	select {
	case <-processes.blocked:
	default:
		t.Fatal("blocked query was not invoked")
	}
	if got := len(callsOfKind(processes.calls, "start")); got != 1 {
		t.Fatalf("Firefox starts = %d, want detached single start", got)
	}
}

func TestObservationPropagatesCallerDeadline(t *testing.T) {
	processes := &fakeProcesses{outputs: map[string][][]byte{
		"msg --json workspaces": {[]byte(`[{"idx":5,"name":"5","output":"HDMI-A-1"}]`)},
		"msg --json windows":    timeoutWindows(2),
	}}
	client := New("/firefox", "/niri", processes)
	client.windowTimeout = time.Second
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Millisecond)
	defer cancel()

	err := client.OpenURL(ctx, "5", "clubhouse", "https://meet.google.com/abc-defg-hij")
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("error = %v, want caller deadline", err)
	}
	if got := len(callsOfKind(processes.calls, "start")); got != 1 {
		t.Fatalf("Firefox starts = %d, want detached single start", got)
	}
}

func TestNiriActionUsesBoundedCallerCancellableContext(t *testing.T) {
	processes := &blockingProcesses{
		fakeProcesses: fakeProcesses{},
		blockRun:      true,
		blocked:       make(chan struct{}, 1),
	}
	client := New("/firefox", "/niri", processes)
	client.commandTimeout = time.Second
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- client.action(ctx, "focus-workspace", "2") }()
	<-processes.blocked
	cancel()
	err := <-done
	if !errors.Is(err, context.Canceled) || !strings.Contains(err.Error(), "Niri action focus-workspace") {
		t.Fatalf("error = %v, want wrapped cancellation", err)
	}
}

func TestNiriActionUsesInternalTimeoutWithoutLaterAction(t *testing.T) {
	processes := &blockingProcesses{
		fakeProcesses: fakeProcesses{},
		blockRun:      true,
		blocked:       make(chan struct{}, 1),
	}
	client := New("/firefox", "/niri", processes)
	client.commandTimeout = 10 * time.Millisecond

	err := client.focusTarget(context.Background(), workspaceTargetValue{Output: "HDMI-A-1", Reference: "5"})
	if !errors.Is(err, context.DeadlineExceeded) || !strings.Contains(err.Error(), "focus-monitor") {
		t.Fatalf("error = %v, want internal command timeout", err)
	}
	select {
	case <-processes.blocked:
	default:
		t.Fatal("blocked action was not invoked")
	}
	assertActionArgs(t, processes.calls, [][]string{
		{"msg", "action", "focus-monitor", "HDMI-A-1"},
	})
}

func TestFocusWorkspaceUsesResolvedOutputAndIndex(t *testing.T) {
	processes := &fakeProcesses{outputs: map[string][][]byte{
		"msg --json workspaces": {[]byte(`[{"id":20,"idx":4,"name":"2","output":"eDP-1","active_window_id":null}]`)},
	}}
	client := newTestLauncher(processes, &fakeClock{})

	if err := client.FocusWorkspace(context.Background(), "2"); err != nil {
		t.Fatal(err)
	}
	assertActionArgs(t, processes.calls, [][]string{
		{"msg", "action", "focus-monitor", "eDP-1"},
		{"msg", "action", "focus-workspace", "4"},
	})
}

func TestMergeEnvironmentOverridesExistingAppIDs(t *testing.T) {
	base := []string{
		"HOME=/home/test",
		"MOZ_APP_REMOTINGNAME=stale",
		"MOZ_APP_LAUNCHER=stale",
	}
	overrides := []string{
		"MOZ_APP_REMOTINGNAME=firefox-profile-clubhouse",
		"MOZ_APP_LAUNCHER=firefox-profile-clubhouse",
	}
	want := []string{
		"HOME=/home/test",
		"MOZ_APP_REMOTINGNAME=firefox-profile-clubhouse",
		"MOZ_APP_LAUNCHER=firefox-profile-clubhouse",
	}
	if got := mergeEnvironment(base, overrides); !reflect.DeepEqual(got, want) {
		t.Fatalf("environment = %#v, want %#v", got, want)
	}
}

func callsOfKind(calls []processCall, kind string) []processCall {
	var result []processCall
	for _, call := range calls {
		if call.kind == kind {
			result = append(result, call)
		}
	}
	return result
}

func assertActionArgs(t *testing.T, calls []processCall, want [][]string) {
	t.Helper()
	var got [][]string
	for _, call := range callsOfKind(calls, "run") {
		if call.name != "/niri" {
			t.Fatalf("action executable = %q, want /niri", call.name)
		}
		got = append(got, call.args)
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("Niri actions = %#v, want %#v", got, want)
	}
}

func timeoutWindows(count int) [][]byte {
	result := make([][]byte, count)
	for index := range result {
		result[index] = []byte(windowsFixture)
	}
	return result
}

func repeatDuration(duration time.Duration, count int) []time.Duration {
	result := make([]time.Duration, count)
	for index := range result {
		result[index] = duration
	}
	return result
}
