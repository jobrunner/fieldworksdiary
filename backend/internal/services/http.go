package services

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"time"
)

// doWithRetry performs an HTTP request with capped exponential
// backoff. Retries on network errors and 5xx; gives up on 4xx (their
// inputs are wrong, not the network).
//
// Returned errors never contain the request's query string or a
// response body: our queries carry coordinates, which must not reach
// the logs (see .claude/rules/LOGGING.md). Non-2xx answers come back as
// *HTTPStatusError.
func doWithRetry(ctx context.Context, client *http.Client, method, rawURL string, body io.Reader, maxRetries int) ([]byte, error) {
	if maxRetries < 1 {
		maxRetries = 3
	}
	if client == nil {
		client = &http.Client{Timeout: 5 * time.Second}
	}

	var lastErr error
	delay := 200 * time.Millisecond
	for attempt := 0; attempt < maxRetries; attempt++ {
		req, err := http.NewRequestWithContext(ctx, method, rawURL, body)
		if err != nil {
			return nil, redactURLError(method, rawURL, err)
		}
		resp, err := client.Do(req)
		if err != nil {
			lastErr = redactURLError(method, rawURL, err)
		} else {
			data, readErr := io.ReadAll(resp.Body)
			resp.Body.Close()
			if readErr != nil {
				lastErr = redactURLError(method, rawURL, readErr)
			} else if resp.StatusCode >= 400 && resp.StatusCode < 500 {
				return nil, &HTTPStatusError{StatusCode: resp.StatusCode}
			} else if resp.StatusCode >= 500 {
				lastErr = &HTTPStatusError{StatusCode: resp.StatusCode}
			} else {
				return data, nil
			}
		}

		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-time.After(delay):
		}
		delay *= 2
		if delay > 2*time.Second {
			delay = 2 * time.Second
		}
	}
	return nil, fmt.Errorf("gave up after %d attempts: %w", maxRetries, lastErr)
}

// redactURLError replaces a *url.Error (whose message contains the full
// URL including the query) by "<method> <path>: <cause>". Errors that
// are not *url.Error are returned unchanged.
func redactURLError(method, rawURL string, err error) error {
	var ue *url.Error
	if !errors.As(err, &ue) {
		return err
	}
	path := "<invalid url>"
	if u, perr := url.Parse(rawURL); perr == nil {
		path = u.Path
	}
	return &redactedError{msg: method + " " + path, cause: ue.Err}
}

// redactedError keeps the cause unwrappable (timeouts, context errors)
// without the URL.
type redactedError struct {
	msg   string
	cause error
}

func (e *redactedError) Error() string { return e.msg + ": " + e.cause.Error() }
func (e *redactedError) Unwrap() error { return e.cause }

// HTTPStatusError is a non-2xx response. It deliberately carries no
// response body: services may echo the query (coordinates) in it.
type HTTPStatusError struct {
	StatusCode int
}

func (e *HTTPStatusError) Error() string { return fmt.Sprintf("http %d", e.StatusCode) }
