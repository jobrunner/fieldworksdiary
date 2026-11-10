// Command adminlabels-gen converts the OSM admin-level YAML reference into
// a draft of the canonical admin_labels.json (see shared/admin-labels/).
//
// WARNING: the committed admin_labels.json is hand-curated (per-country
// column mapping reviewed and corrected after generation). Regenerating
// it discards those corrections. The tool therefore refuses to overwrite
// an existing output file unless -force is given; diff and re-apply the
// curation by hand afterwards.
package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"sort"

	"gopkg.in/yaml.v3"

	"go.mett.io/fwd-backend/internal/adminlabels"
)

type yamlLevel struct {
	Name       string `yaml:"name"`
	Equivalent string `yaml:"equivalent"`
}

type yamlCountry struct {
	Name   string            `yaml:"name"`
	Levels map[int]yamlLevel `yaml:"levels"`
}

type yamlDoc struct {
	Countries map[string]yamlCountry `yaml:"countries"`
}

func convert(doc yamlDoc) *adminlabels.Table {
	t := &adminlabels.Table{Version: 1, Countries: map[string]adminlabels.Country{}}
	for iso, yc := range doc.Countries {
		levels := make([]int, 0, len(yc.Levels))
		for l := range yc.Levels {
			levels = append(levels, l)
		}
		sort.Ints(levels)
		c := adminlabels.Country{Name: yc.Name, Levels: map[int]adminlabels.LevelEntry{}}
		taken := map[adminlabels.Tier]bool{}
		for _, l := range levels {
			yl := yc.Levels[l]
			col := adminlabels.Tier("admin_" + yl.Equivalent)
			e := adminlabels.LevelEntry{Term: yl.Name}
			if !taken[col] {
				taken[col] = true
				e.Column = &col
			}
			c.Levels[l] = e
		}
		t.Countries[iso] = c
	}
	return t
}

const curatedWarning = "warning: the committed admin_labels.json is hand-curated; " +
	"generated output is only a draft — review and re-apply the curation before committing"

// writeOutput writes data to path. An existing file is only replaced
// when force is set, so the hand-curated table is never clobbered by
// accident. The curation warning always goes to stderr.
func writeOutput(path string, data []byte, force bool, stderr io.Writer) error {
	fmt.Fprintln(stderr, curatedWarning)
	if _, err := os.Stat(path); err == nil && !force {
		return fmt.Errorf("%s exists; refusing to overwrite without -force", path)
	} else if err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	// The table is a committed repo file and must stay world-readable.
	return os.WriteFile(path, data, 0o644) //nolint:gosec // G306: committed, non-secret repo file
}

func main() {
	in := flag.String("in", "", "input YAML")
	out := flag.String("out", "", "output JSON")
	force := flag.Bool("force", false, "overwrite an existing output file (discards hand curation)")
	flag.Parse()
	if *in == "" || *out == "" {
		fmt.Fprintln(os.Stderr, "usage: adminlabels-gen -in <yaml> -out <json> [-force]")
		os.Exit(2)
	}
	raw, err := os.ReadFile(*in)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	var doc yamlDoc
	if err := yaml.Unmarshal(raw, &doc); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetIndent("", "  ")
	enc.SetEscapeHTML(false)
	if err := enc.Encode(convert(doc)); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	if err := writeOutput(*out, buf.Bytes(), *force, os.Stderr); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
