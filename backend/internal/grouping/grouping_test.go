package grouping

import (
	"errors"
	"testing"
	"time"
)

// fakeRepo is a tiny stub that records the calls made to it.
type fakeRepo struct {
	found     *Excursion
	findErr   error
	createErr error
	updateErr error

	createdWith []*Excursion
	updatedWith []*Excursion
}

func (f *fakeRepo) FindByUserAndDay(userID string, day time.Time) (*Excursion, error) {
	if f.findErr != nil {
		return nil, f.findErr
	}
	return f.found, nil
}

func (f *fakeRepo) Create(e *Excursion) error {
	f.createdWith = append(f.createdWith, e)
	return f.createErr
}

func (f *fakeRepo) Update(e *Excursion) error {
	f.updatedWith = append(f.updatedWith, e)
	return f.updateErr
}

func TestSpansMidnight(t *testing.T) {
	berlin, _ := time.LoadLocation("Europe/Berlin")
	cases := []struct {
		name string
		a, b time.Time
		want bool
	}{
		{"same day", time.Date(2026, 5, 9, 14, 0, 0, 0, berlin), time.Date(2026, 5, 9, 18, 0, 0, 0, berlin), false},
		{"into next day", time.Date(2026, 5, 9, 22, 0, 0, 0, berlin), time.Date(2026, 5, 10, 1, 30, 0, 0, berlin), true},
		{"into next year", time.Date(2025, 12, 31, 23, 0, 0, 0, berlin), time.Date(2026, 1, 1, 1, 0, 0, 0, berlin), true},
		{"timezone equivalent same instant", time.Date(2026, 5, 9, 14, 0, 0, 0, berlin), time.Date(2026, 5, 9, 12, 0, 0, 0, time.UTC), false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := SpansMidnight(c.a, c.b); got != c.want {
				t.Errorf("SpansMidnight = %v, want %v", got, c.want)
			}
		})
	}
}

func TestExpandWindow(t *testing.T) {
	berlin, _ := time.LoadLocation("Europe/Berlin")
	base := func() *Excursion {
		return &Excursion{
			StartedAt: time.Date(2026, 5, 9, 12, 0, 0, 0, berlin),
			EndedAt:   time.Date(2026, 5, 9, 14, 0, 0, 0, berlin),
		}
	}

	t.Run("extends end forward", func(t *testing.T) {
		e := base()
		ExpandWindow(e, time.Date(2026, 5, 9, 16, 0, 0, 0, berlin))
		if !e.EndedAt.Equal(time.Date(2026, 5, 9, 16, 0, 0, 0, berlin)) {
			t.Errorf("EndedAt = %v", e.EndedAt)
		}
		if !e.StartedAt.Equal(time.Date(2026, 5, 9, 12, 0, 0, 0, berlin)) {
			t.Errorf("StartedAt should not change")
		}
		if e.Night {
			t.Errorf("Night should be false")
		}
	})

	t.Run("extends start backward", func(t *testing.T) {
		e := base()
		ExpandWindow(e, time.Date(2026, 5, 9, 10, 0, 0, 0, berlin))
		if !e.StartedAt.Equal(time.Date(2026, 5, 9, 10, 0, 0, 0, berlin)) {
			t.Errorf("StartedAt = %v", e.StartedAt)
		}
	})

	t.Run("inside window is a no-op", func(t *testing.T) {
		e := base()
		before := *e
		ExpandWindow(e, time.Date(2026, 5, 9, 13, 0, 0, 0, berlin))
		if !e.StartedAt.Equal(before.StartedAt) || !e.EndedAt.Equal(before.EndedAt) {
			t.Errorf("window changed unexpectedly")
		}
	})

	t.Run("crossing midnight sets night flag", func(t *testing.T) {
		e := base()
		ExpandWindow(e, time.Date(2026, 5, 10, 1, 0, 0, 0, berlin))
		if !e.Night {
			t.Errorf("Night should be true after crossing midnight")
		}
	})
}

func TestFindOrCreate_existingExtended(t *testing.T) {
	berlin, _ := time.LoadLocation("Europe/Berlin")
	day := time.Date(2026, 5, 9, 0, 0, 0, 0, berlin)
	repo := &fakeRepo{
		found: &Excursion{
			ID:        "exc1",
			UserID:    "u1",
			Day:       day,
			StartedAt: time.Date(2026, 5, 9, 12, 0, 0, 0, berlin),
			EndedAt:   time.Date(2026, 5, 9, 14, 0, 0, 0, berlin),
		},
	}

	sampleAt := time.Date(2026, 5, 9, 16, 30, 0, 0, berlin)
	got, err := FindOrCreate(repo, "u1", day, sampleAt)
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if got.ID != "exc1" {
		t.Errorf("expected existing excursion, got id=%q", got.ID)
	}
	if !got.EndedAt.Equal(sampleAt) {
		t.Errorf("EndedAt should have moved to sampleAt; got %v", got.EndedAt)
	}
	if len(repo.updatedWith) != 1 {
		t.Errorf("expected 1 update, got %d", len(repo.updatedWith))
	}
	if len(repo.createdWith) != 0 {
		t.Errorf("should not create when one exists")
	}
}

func TestFindOrCreate_createsWhenAbsent(t *testing.T) {
	berlin, _ := time.LoadLocation("Europe/Berlin")
	day := time.Date(2026, 5, 9, 0, 0, 0, 0, berlin)
	repo := &fakeRepo{findErr: ErrNotFound}

	sampleAt := time.Date(2026, 5, 9, 11, 0, 0, 0, berlin)
	got, err := FindOrCreate(repo, "u1", day, sampleAt)
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if !got.StartedAt.Equal(sampleAt) || !got.EndedAt.Equal(sampleAt) {
		t.Errorf("new excursion window should equal sampleAt")
	}
	if got.UserID != "u1" {
		t.Errorf("UserID = %q", got.UserID)
	}
	if !got.Day.Equal(day) {
		t.Errorf("Day = %v", got.Day)
	}
	if len(repo.createdWith) != 1 || len(repo.updatedWith) != 0 {
		t.Errorf("expected 1 create, 0 updates, got %d/%d",
			len(repo.createdWith), len(repo.updatedWith))
	}
}

func TestFindOrCreate_findErrorPropagates(t *testing.T) {
	boom := errors.New("db is on fire")
	repo := &fakeRepo{findErr: boom}
	_, err := FindOrCreate(repo, "u1", time.Now(), time.Now())
	if !errors.Is(err, boom) {
		t.Errorf("expected wrapped boom, got %v", err)
	}
}
