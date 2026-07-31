package meeting

import "testing"

func TestZoomWebClientURLRewritesStandardJoinLinks(t *testing.T) {
	tests := []struct {
		name  string
		input string
		want  string
	}{
		{
			name:  "apex host without password",
			input: "https://zoom.us/j/123456789?tracking=drop#fragment",
			want:  "https://zoom.us/wc/123456789/start?fromPWA=1&ref_from=launch",
		},
		{
			name:  "subdomain with encoded password",
			input: "https://sixfeetup.zoom.us/j/87625926941?pwd=a%2Bb%2Fc%3D&tracking=drop#fragment",
			want:  "https://sixfeetup.zoom.us/wc/87625926941/start?fromPWA=1&pwd=a%2Bb%2Fc%3D&ref_from=launch",
		},
		{
			name:  "first password wins and launch parameters are replaced",
			input: "https://zoom.us/j/987654321?pwd=first&pwd=second&ref_from=source&fromPWA=0",
			want:  "https://zoom.us/wc/987654321/start?fromPWA=1&pwd=first&ref_from=launch",
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got, err := ZoomWebClientURL(test.input)
			if err != nil {
				t.Fatal(err)
			}
			if got != test.want {
				t.Fatalf("ZoomWebClientURL(%q) = %q, want %q", test.input, got, test.want)
			}
		})
	}
}

func TestZoomWebClientURLLeavesNonmatchingURLsUnchanged(t *testing.T) {
	inputs := []string{
		"https://meet.google.com/abc-defg-hij",
		"https://zoom.us/my/personal-room",
		"https://zoom.us/wc/123456789/start?fromPWA=1",
		"https://zoom.us/meeting/register/example",
		"https://zoom.us/j/not-numeric",
		"https://zoom.us/j/123456789/",
		"https://zoom.us/j/123%2F456",
		"https://zoom.us.evil.example/j/123456789",
		"https://evilzoom.us/j/123456789",
	}

	for _, input := range inputs {
		got, err := ZoomWebClientURL(input)
		if err != nil {
			t.Fatalf("ZoomWebClientURL(%q): %v", input, err)
		}
		if got != input {
			t.Fatalf("ZoomWebClientURL(%q) = %q, want unchanged", input, got)
		}
	}
}

func TestZoomWebClientURLRejectsMalformedMatchingQuery(t *testing.T) {
	if _, err := ZoomWebClientURL("https://zoom.us/j/123456789?pwd=%zz"); err == nil {
		t.Fatal("expected malformed query error")
	}
}
