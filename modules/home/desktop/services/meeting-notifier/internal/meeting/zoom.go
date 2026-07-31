package meeting

import (
	"fmt"
	"net/url"
	"regexp"
	"strings"
)

var zoomJoinPath = regexp.MustCompile(`^/j/([0-9]+)$`)

func ZoomWebClientURL(rawURL string) (string, error) {
	parsed, err := url.Parse(rawURL)
	if err != nil {
		return "", fmt.Errorf("parse Zoom meeting URL: %w", err)
	}

	host := strings.TrimSuffix(strings.ToLower(parsed.Hostname()), ".")
	if host != "zoom.us" && !strings.HasSuffix(host, ".zoom.us") {
		return rawURL, nil
	}

	match := zoomJoinPath.FindStringSubmatch(parsed.EscapedPath())
	if match == nil {
		return rawURL, nil
	}

	sourceQuery, err := url.ParseQuery(parsed.RawQuery)
	if err != nil {
		return "", fmt.Errorf("parse Zoom meeting query: %w", err)
	}
	targetQuery := url.Values{
		"fromPWA":  {"1"},
		"ref_from": {"launch"},
	}
	if passwords, ok := sourceQuery["pwd"]; ok && len(passwords) > 0 {
		targetQuery.Set("pwd", passwords[0])
	}

	target := &url.URL{
		Scheme:   parsed.Scheme,
		Host:     parsed.Host,
		Path:     "/wc/" + match[1] + "/start",
		RawQuery: targetQuery.Encode(),
	}
	return target.String(), nil
}
