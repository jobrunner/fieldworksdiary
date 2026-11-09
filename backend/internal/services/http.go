package services

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"time"
)

// doWithRetry performs an HTTP request with capped exponential
// backoff. Retries on network errors and 5xx; gives up on 4xx (their
// inputs are wrong, not the network).
func doWithRetry(ctx context.Context, client *http.Client, method, url string, body io.Reader, maxRetries int) ([]byte, error) {
	if maxRetries < 1 {
		maxRetries = 3
	}
	if client == nil {
		client = &http.Client{Timeout: 5 * time.Second}
	}

	var lastErr error
	delay := 200 * time.Millisecond
	for attempt := 0; attempt < maxRetries; attempt++ {
		req, err := http.NewRequestWithContext(ctx, method, url, body)
		if err != nil {
			return nil, err
		}
		resp, err := client.Do(req)
		if err != nil {
			lastErr = err
		} else {
			data, readErr := io.ReadAll(resp.Body)
			resp.Body.Close()
			if readErr != nil {
				lastErr = readErr
			} else if resp.StatusCode >= 400 && resp.StatusCode < 500 {
				return nil, fmt.Errorf("http %d: %s", resp.StatusCode, truncate(string(data), 200))
			} else if resp.StatusCode >= 500 {
				lastErr = fmt.Errorf("http %d", resp.StatusCode)
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

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "…"
}
