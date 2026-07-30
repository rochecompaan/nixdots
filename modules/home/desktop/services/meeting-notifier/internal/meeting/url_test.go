package meeting

import "testing"

func TestSelectURLPrecedence(t *testing.T) {
	c := Candidate{
		ConferenceURLs: []string{"https://meet.google.com/abc-defg-hij"},
		HangoutLink:    "https://meet.google.com/mno-pqrs-tuv",
		Location:       "https://sixfeetup.zoom.us/j/123",
	}
	got, err := selectURL(c, []string{"meet.google.com", "zoom.us", "*.zoom.us"})
	if err != nil {
		t.Fatal(err)
	}
	if got != "https://meet.google.com/abc-defg-hij" {
		t.Fatalf("got %q", got)
	}
}

func TestExtractsZoomFromHTMLDescription(t *testing.T) {
	c := Candidate{Description: `<a href="https://sixfeetup.zoom.us/j/123?source=a&amp;b=c">Join</a>`}
	got, err := selectURL(c, []string{"meet.google.com", "zoom.us", "*.zoom.us"})
	if err != nil {
		t.Fatal(err)
	}
	if got != "https://sixfeetup.zoom.us/j/123?source=a&b=c" {
		t.Fatalf("got %q", got)
	}
}

func TestValidateURLPreservesEntityLikeData(t *testing.T) {
	rawURL := "https://sixfeetup.zoom.us/j/123?pwd=alpha&amp;beta#token=gamma&amp;delta"
	got, err := ValidateURL(rawURL, []string{"*.zoom.us"})
	if err != nil {
		t.Fatal(err)
	}
	if got != rawURL {
		t.Fatalf("got %q, want %q", got, rawURL)
	}
}

func TestExtractedURLUnescapesNestedEntitiesOnce(t *testing.T) {
	c := Candidate{Description: `<a href="https://sixfeetup.zoom.us/j/123?pwd=alpha&amp;amp;beta#token=gamma&amp;amp;delta">Join</a>`}
	want := "https://sixfeetup.zoom.us/j/123?pwd=alpha&amp;beta#token=gamma&amp;delta"
	got, err := selectURL(c, []string{"*.zoom.us"})
	if err != nil {
		t.Fatal(err)
	}
	if got != want {
		t.Fatalf("got %q, want %q", got, want)
	}
}

func TestExtractURLDropsOnlySurroundingProseDelimiters(t *testing.T) {
	tests := []struct {
		text string
		want string
	}{
		{"Join (https://zoom.us/j/123).", "https://zoom.us/j/123"},
		{"Join [https://meet.google.com/abc-defg-hij], thanks.", "https://meet.google.com/abc-defg-hij"},
		{"Use https://zoom.us/j/123, then wait.", "https://zoom.us/j/123"},
		{"Join (https://zoom.us/j/(team)?pwd=a.b,c;d!).", "https://zoom.us/j/(team)?pwd=a.b,c;d!"},
	}
	for _, test := range tests {
		got, err := selectURL(Candidate{Description: test.text}, []string{"meet.google.com", "zoom.us"})
		if err != nil {
			t.Fatalf("selectURL(%q): %v", test.text, err)
		}
		if got != test.want {
			t.Fatalf("selectURL(%q) = %q, want %q", test.text, got, test.want)
		}
	}
}

func TestExtractURLPreservesBalancedInternalDelimitersAndHTMLAttributes(t *testing.T) {
	want := "https://zoom.us/j/(team)[west]?pwd=a.b,c;d!&room=weekly"
	for _, test := range []struct {
		text string
		want string
	}{
		{want, want},
		{`<a data-note="(prose)" href="https://zoom.us/j/(team)[west]?pwd=a.b,c;d!&room=weekly">Join</a>`, want},
		{"https://zoom.us/j/123?redirect=value)", "https://zoom.us/j/123?redirect=value)"},
	} {
		got, err := selectURL(Candidate{Description: test.text}, []string{"zoom.us"})
		if err != nil {
			t.Fatal(err)
		}
		if got != test.want {
			t.Fatalf("got %q, want %q", got, test.want)
		}
	}
}

func TestExtractURLHandlesPlaintextQueryPunctuationWithoutChangingAttributeURLs(t *testing.T) {
	tests := []struct {
		name string
		text string
		want string
	}{
		{
			name: "plaintext terminal period",
			text: "Join https://zoom.us/j/123?pwd=secret.",
			want: "https://zoom.us/j/123?pwd=secret",
		},
		{
			name: "plaintext internal query punctuation",
			text: "Join https://zoom.us/j/123?pwd=a.b,c;d!&room=weekly.",
			want: "https://zoom.us/j/123?pwd=a.b,c;d!&room=weekly",
		},
		{
			name: "plaintext unmatched terminal closing parenthesis",
			text: "Join https://zoom.us/j/123?redirect=value)",
			want: "https://zoom.us/j/123?redirect=value)",
		},
		{
			name: "quoted HTML attribute preserves terminal punctuation",
			text: `<a href="https://zoom.us/j/123?pwd=secret.">Join</a>`,
			want: "https://zoom.us/j/123?pwd=secret.",
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got, err := selectURL(Candidate{Description: test.text}, []string{"zoom.us"})
			if err != nil {
				t.Fatal(err)
			}
			if got != test.want {
				t.Fatalf("selectURL(%q) = %q, want %q", test.text, got, test.want)
			}
		})
	}
}

func TestValidateURLRejectsUnsafeInputs(t *testing.T) {
	inputs := []string{
		"http://meet.google.com/abc",
		"https://user@meet.google.com/abc",
		"https://meet.google.com.evil.example/abc",
		"https://zoom.us.evil.example/j/123",
		"javascript:alert(1)",
	}
	for _, input := range inputs {
		if _, err := ValidateURL(input, []string{"meet.google.com", "zoom.us", "*.zoom.us"}); err == nil {
			t.Fatalf("expected %q to be rejected", input)
		}
	}
}
