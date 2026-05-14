// Package grouping holds the pure logic for excursion auto-grouping:
// given a sample's (user, collecting_day, time, place), figure out
// whether it joins an existing excursion or starts a new one, and
// keep the excursion's time window in sync with its samples.
//
// DB access is abstracted via the Repo interface so the orchestration
// is unit-testable without PocketBase. The PocketBase-bound
// implementation lives next to the hooks.
package grouping

import (
	"errors"
	"time"
)

// Excursion is the slim, transport-agnostic view that grouping cares
// about. The full PocketBase record carries more (centroid, locality,
// permits, …); those are filled in elsewhere.
type Excursion struct {
	ID        string
	UserID    string
	Day       time.Time
	StartedAt time.Time
	EndedAt   time.Time
	Night     bool
}

// ErrNotFound signals "no excursion for this (user, day) yet — create
// one". It is the only non-fatal error a Repo may return from
// FindByUserAndDay.
var ErrNotFound = errors.New("grouping: excursion not found")

// Repo is the persistence boundary. The PocketBase-backed impl wraps
// a daos.Dao; tests use a fake.
type Repo interface {
	FindByUserAndDay(userID string, day time.Time) (*Excursion, error)
	Create(e *Excursion) error
	Update(e *Excursion) error
}

// FindOrCreate locates the excursion for (userID, day) and extends
// its time window to include sampleAt; if none exists, creates one
// initialised to that single sample.
func FindOrCreate(repo Repo, userID string, day time.Time, sampleAt time.Time) (*Excursion, error) {
	existing, err := repo.FindByUserAndDay(userID, day)
	if err != nil && !errors.Is(err, ErrNotFound) {
		return nil, err
	}
	if existing != nil {
		ExpandWindow(existing, sampleAt)
		if err := repo.Update(existing); err != nil {
			return nil, err
		}
		return existing, nil
	}
	e := &Excursion{
		UserID:    userID,
		Day:       day,
		StartedAt: sampleAt,
		EndedAt:   sampleAt,
		Night:     false,
	}
	if err := repo.Create(e); err != nil {
		return nil, err
	}
	return e, nil
}

// ExpandWindow extends e's time window so it includes t, and
// recomputes the night flag.
func ExpandWindow(e *Excursion, t time.Time) {
	if t.Before(e.StartedAt) {
		e.StartedAt = t
	}
	if t.After(e.EndedAt) {
		e.EndedAt = t
	}
	e.Night = SpansMidnight(e.StartedAt, e.EndedAt)
}

// SpansMidnight reports whether the half-open interval [a, b] crosses
// a calendar-day boundary in a's location. Used as the trigger for the
// `night_excursion` flag.
func SpansMidnight(a, b time.Time) bool {
	bInA := b.In(a.Location())
	return a.Year() != bInA.Year() || a.YearDay() != bInA.YearDay()
}
