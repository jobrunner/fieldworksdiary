// Shared helpers for the app migrations. This file registers no
// migration itself (PocketBase keys migrations by the file name of the
// `m.Register` caller).
package migrations

import (
	"hash/crc32"
	"strconv"

	"github.com/pocketbase/pocketbase/core"
)

// autodateFields returns the `created`/`updated` fields every base
// collection had implicitly before PocketBase 0.23. Since 0.23 they are
// ordinary AutodateFields; the 0.23 upgrade migration adds them to every
// existing collection with exactly these settings and ids
// (`autodate` + CRC32 of the name), so a freshly migrated database ends
// up with the same schema as an upgraded 0.22 one.
func autodateFields() []core.Field {
	return []core.Field{
		&core.AutodateField{Id: autodateFieldID("created"), Name: "created", OnCreate: true},
		&core.AutodateField{Id: autodateFieldID("updated"), Name: "updated", OnCreate: true, OnUpdate: true},
	}
}

func autodateFieldID(name string) string {
	return "autodate" + strconv.FormatInt(int64(crc32.ChecksumIEEE([]byte(name))), 10)
}

// newBaseCollection builds a base collection with the given fields plus
// the created/updated autodate fields appended at the end.
func newBaseCollection(name string, fields ...core.Field) *core.Collection {
	c := core.NewBaseCollection(name)
	c.Fields.Add(fields...)
	c.Fields.Add(autodateFields()...)
	return c
}

// manyRelations is the MaxSelect the 0.23 upgrade writes for a 0.22
// relation without a MaxSelect (= unlimited).
const manyRelations = 2147483647

// removeFields drops the named fields (missing ones are ignored).
func removeFields(c *core.Collection, names ...string) {
	for _, n := range names {
		c.Fields.RemoveByName(n)
	}
}

// renameField renames a field in place; the field id stays, so the
// column is renamed and its data kept. Missing fields are ignored.
func renameField(c *core.Collection, from, to string) {
	if f := c.Fields.GetByName(from); f != nil {
		f.SetName(to)
	}
}

// addFieldIfMissing adds f unless a field with its name exists.
func addFieldIfMissing(c *core.Collection, f core.Field) {
	if c.Fields.GetByName(f.GetName()) == nil {
		c.Fields.Add(f)
	}
}

// deleteCollectionIfExists deletes the named collection (missing ones
// are ignored).
func deleteCollectionIfExists(app core.App, name string) error {
	c, err := app.FindCollectionByNameOrId(name)
	if err != nil || c == nil {
		return nil //nolint:nilerr // missing collection: nothing to delete
	}
	return app.Delete(c)
}
