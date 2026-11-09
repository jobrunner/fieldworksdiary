// Command adminlabels-gen converts the OSM admin-level YAML reference into
// the canonical admin_labels.json (see shared/admin-labels/).
package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
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

func main() {
	in := flag.String("in", "", "input YAML")
	out := flag.String("out", "", "output JSON")
	flag.Parse()
	if *in == "" || *out == "" {
		fmt.Fprintln(os.Stderr, "usage: adminlabels-gen -in <yaml> -out <json>")
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
	if err := os.WriteFile(*out, buf.Bytes(), 0o644); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
