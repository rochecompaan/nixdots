package meeting

import (
	"errors"
	"html"
	"net/url"
	"regexp"
	"strings"
)

var httpsURL = regexp.MustCompile(`(?i)https://[^\s<>"']+`)

func ValidateURL(rawURL string, allowedHosts []string) (string, error) {
	u, err := url.Parse(rawURL)
	if err != nil {
		return "", err
	}
	if !strings.EqualFold(u.Scheme, "https") || u.Host == "" || u.User != nil {
		return "", errors.New("URL must be an HTTPS URL without user info")
	}

	host := strings.TrimSuffix(strings.ToLower(u.Hostname()), ".")
	if !allowedHost(host, allowedHosts) {
		return "", errors.New("URL host is not allowed")
	}

	return u.String(), nil
}

func selectURL(c Candidate, allowedHosts []string) (string, error) {
	for _, rawURL := range c.ConferenceURLs {
		if validURL, err := ValidateURL(rawURL, allowedHosts); err == nil {
			return validURL, nil
		}
	}
	if validURL, err := ValidateURL(c.HangoutLink, allowedHosts); err == nil {
		return validURL, nil
	}
	for _, rawURL := range extractURLs(c.Location) {
		if validURL, err := ValidateURL(rawURL, allowedHosts); err == nil {
			return validURL, nil
		}
	}
	for _, rawURL := range extractURLs(c.Description) {
		if validURL, err := ValidateURL(rawURL, allowedHosts); err == nil {
			return validURL, nil
		}
	}

	return "", errors.New("no allowed meeting URL")
}

func allowedHost(host string, allowedHosts []string) bool {
	for _, allowed := range allowedHosts {
		allowed = strings.TrimSuffix(strings.ToLower(allowed), ".")
		if strings.HasPrefix(allowed, "*.") {
			parent := strings.TrimPrefix(allowed, "*.")
			if strings.HasSuffix(host, "."+parent) {
				return true
			}
			continue
		}
		if host == allowed {
			return true
		}
	}
	return false
}

func extractURLs(text string) []string {
	decoded := html.UnescapeString(text)
	locations := httpsURL.FindAllStringIndex(decoded, -1)
	matches := make([]string, 0, len(locations))
	for _, location := range locations {
		var surrounding byte
		if location[0] != 0 {
			surrounding = decoded[location[0]-1]
		}
		matches = append(matches, trimProseDelimiters(decoded[location[0]:location[1]], surrounding, quotedHTMLAttribute(decoded, location)))
	}
	return matches
}

func trimProseDelimiters(raw string, surrounding byte, quotedAttribute bool) string {
	if quotedAttribute {
		return raw
	}
	withoutPunctuation := strings.TrimRight(raw, ".,;:!")
	closing := map[byte]byte{'(': ')', '[': ']', '{': '}'}[surrounding]
	if closing != 0 && len(withoutPunctuation) != 0 && withoutPunctuation[len(withoutPunctuation)-1] == closing {
		return withoutPunctuation[:len(withoutPunctuation)-1]
	}
	return withoutPunctuation
}

func quotedHTMLAttribute(text string, location []int) bool {
	start, end := location[0], location[1]
	if start == 0 || end >= len(text) {
		return false
	}
	quote := text[start-1]
	if (quote != '\'' && quote != '"') || text[end] != quote {
		return false
	}
	prefix := text[:start-1]
	equals := strings.LastIndexByte(prefix, '=')
	tagStart := strings.LastIndexByte(prefix, '<')
	if tagStart < 0 || equals <= tagStart {
		return false
	}
	name := strings.TrimSpace(prefix[tagStart+1 : equals])
	if space := strings.LastIndexAny(name, " \t\r\n"); space >= 0 {
		name = name[space+1:]
	}
	if name == "" {
		return false
	}
	for _, character := range name {
		if !(character >= 'a' && character <= 'z' || character >= 'A' && character <= 'Z' || character >= '0' && character <= '9' || character == ':' || character == '_' || character == '-' || character == '.') {
			return false
		}
	}
	return true
}
