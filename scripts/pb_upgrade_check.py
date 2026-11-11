#!/usr/bin/env python3
"""PocketBase upgrade check: seed, dump and compare the API surface.

Used by scripts/pb-upgrade-check.sh. Subcommands:

  seed     create two users plus realistic data through the REST API
           (only against a scratch instance, never against prod)
  dump     write the API responses the iOS app sees (per user) plus a
           superuser dump of every collection into one JSON file
  compare  diff two dumps: same records, field names, values, types
  schema   diff the collection schemas of two running instances

Only the standard library is used (Python >= 3.9). Tokens, passwords and
coordinates are never printed; dumps live in the caller's scratch dir.
"""

import argparse
import hashlib
import io
import json
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
import zipfile

# Collections the iOS app reads, in dump order.
USER_COLLECTIONS = [
    "samples", "fieldtrips", "localities", "people", "determinations",
    "sample_photos", "placemarks", "sample_features", "label_pdfs",
    "locality_remap_events",
]
# Server-internal collections: users must be locked out.
INTERNAL_COLLECTIONS = ["geocache", "sample_sequences"]

# A 1x1 white JPEG.
TINY_JPEG = bytes.fromhex(
    "ffd8ffe000104a46494600010100000100010000ffdb004300080606070605080707"
    "07090908 0a0c140d0c0b0b0c1912130f141d1a1f1e1d1a1c1c20242e2720222c231c"
    "1c2837292c30313434341f27393d38323c2e333432ffc0000b080001000101011100"
    "ffc4001f0000010501010101010100000000000000000102030405060708090a0bff"
    "c400b5100002010303020403050504040000017d0102030004110512213141061351"
    "6107227114328191a1082342b1c11552d1f02433627282090a161718191a25262728"
    "292a3435363738393a434445464748494a535455565758595a636465666768696a73"
    "7475767778797a838485868788898a92939495969798999aa2a3a4a5a6a7a8a9aab2"
    "b3b4b5b6b7b8b9bac2c3c4c5c6c7c8c9cad2d3d4d5d6d7d8d9dae1e2e3e4e5e6e7e8"
    "e9eaf1f2f3f4f5f6f7f8f9faffda0008010100003f00fbd3ffd9".replace(" ", "")
)


class Client:
    def __init__(self, base, token=None):
        self.base = base.rstrip("/")
        self.token = token

    def request(self, method, path, body=None, raw=None, ctype=None, token=None):
        url = self.base + path
        headers = {}
        data = None
        if body is not None:
            data = json.dumps(body).encode()
            headers["Content-Type"] = "application/json"
        elif raw is not None:
            data = raw
            headers["Content-Type"] = ctype
        tok = token if token is not None else self.token
        if tok:
            headers["Authorization"] = tok
        req = urllib.request.Request(url, data=data, method=method, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                return resp.status, resp.headers.get("Content-Type", ""), resp.read()
        except urllib.error.HTTPError as err:
            return err.code, err.headers.get("Content-Type", ""), err.read()

    def json(self, method, path, body=None, token=None, expect=None):
        status, _, payload = self.request(method, path, body=body, token=token)
        try:
            parsed = json.loads(payload) if payload else None
        except ValueError:
            parsed = {"_raw": payload.decode("utf-8", "replace")[:500]}
        if expect is not None and status != expect:
            raise SystemExit(f"{method} {path}: HTTP {status} (want {expect}): {json.dumps(parsed)[:800]}")
        return status, parsed

    def multipart(self, path, fields, files):
        boundary = "----pbcheck" + uuid.uuid4().hex
        buf = io.BytesIO()
        for k, v in fields.items():
            buf.write(f"--{boundary}\r\nContent-Disposition: form-data; name=\"{k}\"\r\n\r\n{v}\r\n".encode())
        for k, (name, mime, blob) in files.items():
            buf.write(
                f"--{boundary}\r\nContent-Disposition: form-data; name=\"{k}\"; filename=\"{name}\"\r\n"
                f"Content-Type: {mime}\r\n\r\n".encode())
            buf.write(blob)
            buf.write(b"\r\n")
        buf.write(f"--{boundary}--\r\n".encode())
        status, _, payload = self.request("POST", path, raw=buf.getvalue(),
                                          ctype="multipart/form-data; boundary=" + boundary)
        return status, json.loads(payload) if payload else None


def q(params):
    return "?" + urllib.parse.urlencode(params)


# --------------------------------------------------------------------------
# Superuser / admin auth across both PocketBase generations.
# --------------------------------------------------------------------------

def superuser_login(base, email, password):
    """Returns (token, flavour) where flavour is 'admins' (0.22) or
    'superusers' (>= 0.23)."""
    c = Client(base)
    status, body = c.json("POST", "/api/collections/_superusers/auth-with-password",
                          {"identity": email, "password": password})
    if status == 200:
        return body["token"], "superusers"
    status2, body2 = c.json("POST", "/api/admins/auth-with-password",
                            {"identity": email, "password": password})
    if status2 == 200:
        return body2["token"], "admins"
    raise SystemExit(f"superuser login failed: {status} / {status2}")


# --------------------------------------------------------------------------
# seed
# --------------------------------------------------------------------------

def seed(args):
    c = Client(args.base)
    out = {"users": {}}
    users = [("a", args.user_a, args.password), ("b", args.user_b, args.password)]
    for key, email, pw in users:
        c.json("POST", "/api/collections/users/records", {
            "email": email, "password": pw, "passwordConfirm": pw,
            "display_name": "Tester " + key.upper(), "abbreviation": key.upper() + ".",
        }, expect=200)
        _, auth = c.json("POST", "/api/collections/users/auth-with-password",
                         {"identity": email, "password": pw}, expect=200)
        uc = Client(args.base, auth["token"])
        uid = auth["record"]["id"]
        seed_user(uc, key, uid)
        out["users"][key] = {"id": uid, "email": email}
    # Let the async hooks (fusion, enrichment no-op) settle.
    time.sleep(3)
    print(json.dumps(out))


def seed_user(c, key, uid):
    c.json("PATCH", f"/api/collections/users/records/{uid}", {
        "day_cutoff_hour": 5, "default_fieldtrip_split_km": 2.5,
        "sample_id_format": "YYMMDD/N", "sample_id_prefix": key.upper(), "sample_id_offset": 3,
    }, expect=200)
    _, person = c.json("POST", "/api/collections/people/records", {
        "full_name": f"Person {key.upper()}", "abbreviation": f"P.{key.upper()}",
        "email": f"person-{key}@example.org", "notes": "<p>Bestimmer</p>",
    }, expect=200)
    _, pm_shared = c.json("POST", "/api/placemarks/resolve", {
        "geocoding_source": "backend_service", "country_iso": "DE",
        "admin_country": "Deutschland", "admin_state": "Bayern",
        "admin_state_level": 4, "admin_municipality": "Würzburg",
        "admin_municipality_level": 8,
    }, expect=200)
    _, pm_manual = c.json("POST", "/api/placemarks/resolve", {
        "geocoding_source": "manual", "country_iso": "ES",
        "admin_country": "España", "admin_state": "Canarias",
        "island": "La Palma", "mountain": "Roque de los Muchachos",
    }, expect=200)
    lat0 = 49.7913 if key == "a" else 48.1371
    lon0 = 9.9534 if key == "a" else 11.5754
    _, loc1 = c.json("POST", "/api/collections/localities/records", {
        "name": f"Fundort {key.upper()}1", "latitude": lat0, "longitude": lon0,
        "altitude": 180.5, "horizontal_accuracy": 8, "location_source": "location_service",
        "location_number": "FO-1", "radius_m": 150, "version": 1, "notes": "<p>Wiese</p>",
        "client_uuid": str(uuid.uuid5(uuid.NAMESPACE_URL, key + "loc1")),
        "client_updated_at": "2026-05-10T12:00:00.000Z",
    }, expect=200)
    c.json("PATCH", f"/api/localities/{loc1['id']}/placemark", {
        "country_iso": "DE", "admin_state": "Bayern", "admin_county": "Unterfranken",
        "admin_municipality": "Veitshöchheim",
    }, expect=200)
    # Two localities 3 m apart: the fusion hook merges the second into
    # the first and emits a locality_remap_events row.
    _, loc2 = c.json("POST", "/api/collections/localities/records", {
        "name": f"Fundort {key.upper()}2", "latitude": lat0 + 0.05, "longitude": lon0 + 0.05,
        "location_source": "user", "version": 1,
    }, expect=200)
    time.sleep(1)
    c.json("POST", "/api/collections/localities/records", {
        "name": f"Fundort {key.upper()}2-dup", "latitude": lat0 + 0.05 + 0.00002,
        "longitude": lon0 + 0.05, "location_source": "user", "version": 1,
    }, expect=200)

    base = {"timezone": "Europe/Berlin", "timezone_source": "device", "version": 1, "is_all_day": False}
    # 1. sample with coordinate, elevation, locality, notes, mark
    s1 = dict(base, **{
        "sample_id": f"260510/{key}1", "begin_date": "2026-05-10T12:30:00.000Z",
        "end_date": "2026-05-10T12:45:00.000Z", "collecting_day": "2026-05-10",
        "latitude": lat0 + 0.0001, "longitude": lon0 + 0.0001, "horizontal_accuracy": 5.5,
        "vertical_accuracy": 3, "elevation": 181.25, "elevation_source": "location_service",
        "location_source": "location_service", "location_status": "pending",
        "locality": loc1["id"], "notes": "<p>Kescher</p>", "marked": True,
        "client_uuid": str(uuid.uuid5(uuid.NAMESPACE_URL, key + "s1")),
        "client_updated_at": "2026-05-10T12:30:00.000Z",
    })
    _, smp1 = c.json("POST", "/api/collections/samples/records", s1, expect=200)
    # 2. sample without coordinate
    _, smp2 = c.json("POST", "/api/collections/samples/records", dict(base, **{
        "sample_id": f"260510/{key}2", "begin_date": "2026-05-10T14:00:00.000Z",
        "location_source": "user", "location_status": "manual",
        "client_uuid": str(uuid.uuid5(uuid.NAMESPACE_URL, key + "s2")),
    }), expect=200)
    # 3. retrospective sample on an older day
    _, smp3 = c.json("POST", "/api/collections/samples/records", dict(base, **{
        "sample_id": f"250301/{key}1", "begin_date": "2025-03-01T00:00:00.000Z",
        "is_all_day": True, "is_retrospective": True, "collecting_day": "2025-03-01",
        "latitude": lat0 - 0.01, "longitude": lon0 - 0.01, "location_source": "user",
        "location_status": "manual", "placemark": pm_manual["id"],
    }), expect=200)
    # 4. colliding sample_id -> " (2)" suffix + original_code
    c.json("POST", "/api/collections/samples/records", dict(base, **{
        "sample_id": f"260510/{key}1", "begin_date": "2026-05-10T15:00:00.000Z",
        "latitude": lat0 + 0.0002, "longitude": lon0, "location_source": "location_service",
        "location_status": "backend_service", "placemark": pm_shared["id"],
    }), expect=200)
    # 5. night sample after midnight (cutoff rollover)
    c.json("POST", "/api/collections/samples/records", dict(base, **{
        "begin_date": "2026-05-11T01:30:00.000Z", "latitude": lat0, "longitude": lon0,
        "location_source": "location_service",
    }), expect=200)
    # updates: version bump, notes change; a stale write (409)
    c.json("PATCH", f"/api/collections/samples/records/{smp1['id']}", {
        "notes": "<p>Kescher, Eiche</p>", "version": 2,
    }, expect=200)
    c.json("PATCH", f"/api/collections/samples/records/{smp2['id']}", {"version": 1, "notes": "x"})
    # retrospective sample moves to another day (new fieldtrip)
    c.json("PATCH", f"/api/collections/samples/records/{smp3['id']}", {
        "collecting_day": "2025-03-02", "version": 2,
    }, expect=200)
    c.json("PATCH", f"/api/collections/fieldtrips/records/{smp1['fieldtrip']}", {
        "permit_number": f"BV-2026/{key}", "notes": "<p>sonnig</p>", "version": 2,
    }, expect=200)
    c.json("POST", "/api/collections/determinations/records", {
        "sample": smp1["id"], "species_text": "Otiorhynchus ligustici", "kind": "det",
        "person": person["id"], "determined_on": "2026-05-12 00:00:00.000Z", "notes": "Habitus",
    }, expect=200)
    c.json("POST", "/api/collections/determinations/records", {
        "sample": smp1["id"], "species_text": "Curculio nucum", "kind": "vid",
    }, expect=200)
    status, photo = c.multipart("/api/collections/sample_photos/records", {
        "sample": smp1["id"], "client_uuid": str(uuid.uuid5(uuid.NAMESPACE_URL, key + "p1")),
        "client_updated_at": "2026-05-10T12:31:00.000Z",
    }, {"photo_file": ("photo.jpg", "image/jpeg", TINY_JPEG)})
    if status != 200:
        raise SystemExit(f"photo upload: HTTP {status}: {photo}")
    status, _, _ = c.request("PUT", f"/api/samples/{smp1['id']}/features", body={"features": [{
        "source_id": "natura2000", "source_name": "Natura 2000", "layer": "ffh",
        "feature_id": f"DE6225-{key}", "properties": {"name": "Maintal", "area_ha": 12.5},
        "license": {"name": "dl-de/by-2-0"},
    }]})
    if status != 204:
        raise SystemExit(f"features: HTTP {status}")
    c.json("POST", "/api/label-pdfs/locality", {"sample_ids": [smp1["id"]]}, expect=200)
    c.json("POST", "/api/label-pdfs/determination", {"sample_ids": [smp1["id"]]}, expect=200)


# --------------------------------------------------------------------------
# dump
# --------------------------------------------------------------------------

def ios_queries(ids):
    """The list queries the iOS client sends (Core/PocketBaseClient/*)."""
    sample_ids = ids.get("samples", [])
    pm_ids = ids.get("placemarks", [])
    qs = {
        "fieldtrips:ios": ("fieldtrips", {"perPage": 30, "sort": "-collecting_day,-started_at"}),
        "fieldtrips:sorted": ("fieldtrips", {"perPage": 30, "sort": "-collecting_day,-begin_date"}),
        "localities:ios": ("localities", {"perPage": 200, "sort": "name"}),
        "people:ios": ("people", {"perPage": 200, "sort": "full_name"}),
        "locality_remap_events:ios": ("locality_remap_events", {"perPage": 200, "sort": "created"}),
        "locality_remap_events:since": ("locality_remap_events", {
            "perPage": 200, "sort": "created", "filter": 'created > "2000-01-01T00:00:00.000Z"'}),
        "samples:ios-full": ("samples", {"perPage": 200, "sort": "updated,id", "skipTotal": 1}),
        "samples:ios-since": ("samples", {"perPage": 200, "sort": "updated,id", "skipTotal": 1,
                                          "filter": '(updated >= "2000-01-01 00:00:00.000Z")'}),
        "samples:filter-marked": ("samples", {"filter": "marked = true", "sort": "id"}),
        "samples:filter-retro": ("samples", {"filter": "is_retrospective = true", "sort": "id"}),
        "fieldtrips:filter-day": ("fieldtrips", {"filter": "collecting_day = '2026-05-10'", "sort": "id"}),
    }
    if sample_ids:
        clauses = " || ".join(f"sample='{s}'" for s in sample_ids)
        qs["sample_features:ios"] = ("sample_features", {"filter": clauses, "perPage": 500})
        qs["determinations:ios"] = ("determinations", {
            "filter": f"sample='{sample_ids[0]}'", "sort": "-determined_on,-created", "perPage": 50})
        qs["label_pdfs:ios"] = ("label_pdfs", {
            "filter": " || ".join(f"samples ?= '{s}'" for s in sample_ids), "sort": "-created", "perPage": 50})
    if pm_ids:
        qs["placemarks:ios"] = ("placemarks", {
            "filter": " || ".join(f"id='{p}'" for p in pm_ids), "perPage": max(len(pm_ids), 1), "skipTotal": 1})
    return qs


def dump_user(base, email, password, legacy_token=None):
    c = Client(base)
    out = {}
    status, auth = c.json("POST", "/api/collections/users/auth-with-password",
                          {"identity": email, "password": password})
    out["auth_status"] = status
    if status != 200:
        out["auth_error"] = auth
        return out, None
    token = auth.pop("token", None)
    auth["token"] = "<present>" if isinstance(token, str) and token else "<missing>"
    out["auth"] = auth
    uid = auth["record"]["id"]
    uc = Client(base, token)
    status, refresh = uc.json("POST", "/api/collections/users/auth-refresh", {})
    if isinstance(refresh, dict) and "token" in refresh:
        refresh["token"] = "<present>"
    out["auth_refresh"] = {"status": status, "body": refresh}
    out["self_view"] = uc.json("GET", f"/api/collections/users/records/{uid}")
    st, body = uc.json("GET", "/api/collections/users/records")
    out["users_list"] = {"status": st, "body": body}

    out["collections"] = {}
    ids = {}
    for coll in USER_COLLECTIONS:
        st, body = uc.json("GET", f"/api/collections/{coll}/records" + q({"perPage": 500, "sort": "id"}))
        entry = {"list_status": st, "list": body, "view": {}}
        if st == 200:
            ids[coll] = [it["id"] for it in body["items"]]
            for rid in ids[coll]:
                entry["view"][rid] = uc.json("GET", f"/api/collections/{coll}/records/{rid}")
        out["collections"][coll] = entry
    for coll in INTERNAL_COLLECTIONS:
        st, body = uc.json("GET", f"/api/collections/{coll}/records")
        out["collections"][coll] = {"list_status": st, "list": body}
    out["ios_queries"] = {}
    for name, (coll, params) in ios_queries(ids).items():
        out["ios_queries"][name] = uc.json("GET", f"/api/collections/{coll}/records" + q(params))

    # files: photo + label pdf bytes
    out["files"] = {}
    for coll, field in (("sample_photos", "photo_file"), ("label_pdfs", "pdf_file")):
        for rid, (st, rec) in out["collections"][coll]["view"].items():
            name = rec.get(field) if isinstance(rec, dict) else None
            if not name:
                continue
            fst, ctype, blob = uc.request("GET", f"/api/files/{coll}/{rid}/{name}")
            digest = hashlib.sha256(blob).hexdigest() if fst == 200 else None
            out["files"][f"{coll}/{rid}"] = {"status": fst, "type": ctype.split(";")[0],
                                             "sha256": digest if coll == "sample_photos" else bool(digest)}
    # export (zip): data.json without the timestamp, entry list
    st, ctype, blob = uc.request("GET", "/api/export")
    exp = {"status": st, "type": ctype}
    if st == 200:
        zf = zipfile.ZipFile(io.BytesIO(blob))
        exp["entries"] = sorted(zf.namelist())
        data = json.loads(zf.read("data.json"))
        data.pop("exported_at", None)
        exp["data"] = data
    out["export"] = exp

    if legacy_token:
        lt = Client(base, legacy_token)
        st, body = lt.json("GET", "/api/collections/samples/records" + q({"perPage": 1, "sort": "id"}))
        out["legacy_token"] = {"list_status": st,
                               "list_items": len(body.get("items", [])) if isinstance(body, dict) else None}
        st, body = lt.json("POST", "/api/collections/users/auth-refresh", {})
        out["legacy_token"]["refresh_status"] = st
    return out, token


def isolation(base, tok_a, tok_b, dump_b):
    """User A against every record of user B: view/update/delete must fail."""
    a = Client(base, tok_a)
    res = {}
    for coll in USER_COLLECTIONS:
        view = dump_b["collections"].get(coll, {}).get("view", {})
        for rid, (st, rec) in sorted(view.items()):
            if coll == "placemarks" and isinstance(rec, dict) and rec.get("owner", "") == "":
                continue  # shared reference rows are visible to everybody
            vs, vb = a.json("GET", f"/api/collections/{coll}/records/{rid}")
            us, ub = a.json("PATCH", f"/api/collections/{coll}/records/{rid}", {"notes": "hijack"})
            ds, db = a.json("DELETE", f"/api/collections/{coll}/records/{rid}")
            ls, lb = a.json("GET", f"/api/collections/{coll}/records" + q({"filter": f"id='{rid}'"}))
            res[f"{coll}/{rid}"] = {
                "view": vs, "update": us, "delete": ds,
                "list_hits": lb.get("totalItems") if isinstance(lb, dict) else ls,
            }
    # owner spoofing on create
    uid_b = dump_b["auth"]["record"]["id"]
    st, body = a.json("POST", "/api/collections/people/records", {"full_name": "spoof", "owner": uid_b})
    res["create_with_foreign_owner"] = {"status": st, "body": body}
    if st == 200 and isinstance(body, dict):
        a.json("DELETE", f"/api/collections/people/records/{body['id']}")
    return res


def error_shapes(base, token, dump_self, dump_other):
    """Requests that must fail without changing data; their bodies are
    compared (iOS reads message, data.<field>.code, data.current_version)."""
    c = Client(base, token)
    res = {}
    samples = sorted(dump_self["collections"]["samples"]["view"].items())
    versioned = [(rid, rec) for rid, (st, rec) in samples if isinstance(rec, dict) and rec.get("version", 0) >= 2]
    if versioned:
        rid, rec = versioned[0]
        res["stale_write_409"] = c.json("PATCH", f"/api/collections/samples/records/{rid}",
                                        {"version": 1, "notes": "stale"})
    foreign_manual = [prid for prid, (st, rec) in sorted(dump_other["collections"]["placemarks"]["view"].items())
                      if isinstance(rec, dict) and rec.get("owner")]
    if samples and foreign_manual:
        rid, (_, rec) = samples[0]
        # version+1 passes the 409 guard; the placemark guard must reject.
        res["foreign_placemark_400"] = c.json("PATCH", f"/api/collections/samples/records/{rid}",
                                              {"placemark": foreign_manual[0],
                                               "version": rec.get("version", 0) + 1})
    if samples:
        res["bad_select_400"] = c.json("POST", "/api/collections/determinations/records",
                                       {"sample": samples[0][0], "species_text": "X", "kind": "bogus"})
        res["missing_required_400"] = c.json("POST", "/api/collections/determinations/records",
                                             {"sample": samples[0][0], "kind": "det"})
    res["unknown_record_404"] = c.json("GET", "/api/collections/samples/records/doesnotexist123")
    res["bad_filter_400"] = c.json("GET", "/api/collections/samples/records" + q({"filter": "nope ~~ 1"}))
    res["label_empty_400"] = c.json("POST", "/api/label-pdfs/locality", {"sample_ids": []})
    res["resolve_bad_iso_400"] = c.json("POST", "/api/placemarks/resolve",
                                        {"geocoding_source": "manual", "country_iso": "D"})
    return res


def anonymous(base):
    c = Client(base)
    res = {}
    for coll in USER_COLLECTIONS + ["users"]:
        st, body = c.json("GET", f"/api/collections/{coll}/records")
        res[f"list:{coll}"] = {"status": st, "total": body.get("totalItems") if isinstance(body, dict) else None}
    res["create:samples"] = c.json("POST", "/api/collections/samples/records", {"sample_id": "anon"})[0]
    res["create:people"] = c.json("POST", "/api/collections/people/records", {"full_name": "anon"})[0]
    for path in ("/api/export",):
        res["get:" + path] = c.request("GET", path)[0]
    for path, body in (("/api/label-pdfs/locality", {"sample_ids": ["x"]}),
                       ("/api/placemarks/resolve", {"geocoding_source": "manual", "country_iso": "DE"}),
                       ("/api/auth/apple-native", {"identity_token": "garbage"}),
                       ("/api/auth/apple-native", {})):
        res[f"post:{path}:{json.dumps(body)}"] = c.json("POST", path, body)
    res["health"] = c.request("GET", "/api/health")[0]
    st, _, body = c.request("GET", "/api/version")
    res["version"] = {"status": st, "keys": sorted(json.loads(body).keys()) if st == 200 else None}
    return res


def superuser_dump(base, email, password):
    token, flavour = superuser_login(base, email, password)
    c = Client(base, token)
    st, cols = c.json("GET", "/api/collections" + q({"perPage": 500, "sort": "name"}))
    out = {"login": "ok", "records": {}}
    for col in cols["items"]:
        name = col["name"]
        if name.startswith("_") or col.get("system") and name not in ("users",):
            if name != "users":
                continue
        items = []
        page = 1
        while True:
            st, body = c.json("GET", f"/api/collections/{name}/records" +
                              q({"perPage": 500, "page": page, "sort": "id"}))
            if st != 200:
                items = {"status": st, "body": body}
                break
            items.extend(body["items"])
            if page >= body["totalPages"]:
                break
            page += 1
        out["records"][name] = items
    return out, flavour


def dump(args):
    tokens = {}
    out = {"base": "<redacted>", "users": {}}
    legacy = {}
    if args.legacy_tokens:
        with open(args.legacy_tokens) as fh:
            legacy = json.load(fh)
    for key, email in (("a", args.user_a), ("b", args.user_b)):
        if not email:
            continue
        d, tok = dump_user(args.base, email, args.password, legacy.get(key))
        out["users"][key] = d
        tokens[key] = tok
    if tokens.get("a") and tokens.get("b"):
        out["isolation_a_on_b"] = isolation(args.base, tokens["a"], tokens["b"], out["users"]["b"])
        out["isolation_b_on_a"] = isolation(args.base, tokens["b"], tokens["a"], out["users"]["a"])
        out["error_shapes_a"] = error_shapes(args.base, tokens["a"], out["users"]["a"], out["users"]["b"])
    out["anonymous"] = anonymous(args.base)
    if args.su_email:
        out["superuser"], flavour = superuser_dump(args.base, args.su_email, args.su_password)
        out["superuser_flavour"] = flavour
    with open(args.out, "w") as fh:
        json.dump(out, fh, indent=1, sort_keys=True, ensure_ascii=False)
    if args.tokens_out:
        with open(args.tokens_out, "w") as fh:
            json.dump(tokens, fh)
    print(f"dump written: {args.out}")


# --------------------------------------------------------------------------
# compare
# --------------------------------------------------------------------------

def typename(v):
    if v is None:
        return "null"
    if isinstance(v, bool):
        return "bool"
    if isinstance(v, (int, float)):
        return "number"
    return type(v).__name__


def diff(a, b, path, out, ignore):
    for pat in ignore:
        if pat(path):
            return
    if isinstance(a, dict) and isinstance(b, dict):
        for k in sorted(set(a) | set(b)):
            p = f"{path}.{k}"
            if k not in a:
                if not any(pat(p) for pat in ignore):
                    out.append(("added", p, None, b[k]))
            elif k not in b:
                if not any(pat(p) for pat in ignore):
                    out.append(("removed", p, a[k], None))
            else:
                diff(a[k], b[k], p, out, ignore)
        return
    if isinstance(a, list) and isinstance(b, list):
        if len(a) != len(b):
            out.append(("length", path, len(a), len(b)))
        for i, (x, y) in enumerate(zip(a, b)):
            diff(x, y, f"{path}[{i}]", out, ignore)
        return
    if typename(a) != typename(b):
        out.append(("type", path, a, b))
    elif a != b:
        out.append(("value", path, a, b))


# Lists that come from requests without a sort; PocketBase guarantees no
# order there, so they are compared as sets (sorted by id).
UNORDERED = ("placemarks:ios", ".export.data.placemarks")


def sort_unordered(node, path=""):
    if isinstance(node, dict):
        return {k: sort_unordered(v, f"{path}.{k}") for k, v in node.items()}
    if isinstance(node, list):
        items = [sort_unordered(v, f"{path}[]") for v in node]
        if any(u in path for u in UNORDERED) and all(isinstance(i, dict) and "id" in i for i in items):
            items.sort(key=lambda i: i["id"])
        return items
    return node


def compare(args):
    with open(args.before) as fh:
        before = sort_unordered(json.load(fh))
    with open(args.after) as fh:
        after = sort_unordered(json.load(fh))
    ignore = [
        lambda p: p.endswith(".version.keys") and False,
        lambda p: p.startswith(".superuser_flavour"),
        lambda p: ".legacy_token" in p,
    ]
    for extra in args.ignore or []:
        ignore.append(lambda p, e=extra: e in p)
    out = []
    diff(before, after, "", out, ignore)
    if args.ignore_error_format:
        out = [d for d in out if not is_error_format_diff(d)]
    report = {"differences": len(out), "items": [
        {"kind": k, "path": p, "before": trunc(x), "after": trunc(y)} for k, p, x, y in out]}
    if args.out:
        with open(args.out, "w") as fh:
            json.dump(report, fh, indent=1, ensure_ascii=False)
    # Collapse record ids so the summary groups identical differences.
    groups = {}
    for k, p, x, y in out:
        key = (k, collapse(p), json.dumps(trunc(x), ensure_ascii=False), json.dumps(trunc(y), ensure_ascii=False))
        groups[key] = groups.get(key, 0) + 1
    print(f"{len(out)} differences, {len(groups)} distinct")
    for (k, p, x, y), n in sorted(groups.items()):
        print(f"  [{k}] x{n} {p}: {x[:160]} -> {y[:160]}")
    return 1 if out else 0


def is_error_format_diff(d):
    """PocketBase >= 0.23 renamed the error JSON key `code` to `status`,
    reworded some built-in messages and adds `params` to some field
    errors. The iOS client reads none of these (only `message` for
    display, `data.<field>.code`, `data.current_version`)."""
    kind, path, old, new = d
    last = path.rsplit(".", 1)[-1]
    if kind == "removed" and last == "code" and isinstance(old, int):
        return True
    if kind == "added" and last == "status" and isinstance(new, int):
        return True
    if kind == "added" and last == "params":
        return True
    if kind == "value" and last == "message" and isinstance(old, str) and isinstance(new, str):
        return True
    return False


def collapse(path):
    import re
    path = re.sub(r"\[\d+\]", "[*]", path)
    return re.sub(r"\.[a-z0-9]{15}(?=\.|$|\[)", ".<id>", path)


def trunc(v):
    s = json.dumps(v, ensure_ascii=False)
    return v if len(s) <= 300 else s[:300] + "…"


# --------------------------------------------------------------------------
# schema (two running >= 0.23 instances, or 0.22 vs >= 0.23 normalised)
# --------------------------------------------------------------------------

NORM_KEYS = ("name", "type", "required", "hidden", "system", "presentable", "maxSelect",
             "minSelect", "values", "min", "max", "onlyInt", "pattern", "maxSize",
             "mimeTypes", "thumbs", "protected", "cascadeDelete", "collectionName",
             "onCreate", "onUpdate", "autogeneratePattern", "exceptDomains", "onlyDomains",
             "convertURLs", "primaryKey", "cost")


def normalise_collections(base, email, password):
    token, flavour = superuser_login(base, email, password)
    c = Client(base, token)
    _, cols = c.json("GET", "/api/collections" + q({"perPage": 500, "sort": "name"}))
    by_id = {col["id"]: col["name"] for col in cols["items"]}
    res = {}
    for col in cols["items"]:
        fields = []
        for f in col.get("fields", col.get("schema", [])):
            flat = dict(f)
            flat.update(f.get("options") or {})
            if "collectionId" in flat:
                flat["collectionName"] = by_id.get(flat["collectionId"], flat["collectionId"])
            fields.append({k: flat[k] for k in NORM_KEYS if k in flat})
        # Field order differs between fresh and upgraded databases (the
        # 0.23 upgrade appends created/updated last) and does not reach
        # the API (records are JSON objects), so fields are keyed by name.
        entry = {
            "type": col["type"], "fields": {f["name"]: f for f in fields},
            "indexes": sorted(col.get("indexes") or []),
        }
        for r in ("listRule", "viewRule", "createRule", "updateRule", "deleteRule", "authRule", "manageRule"):
            if r in col:
                entry[r] = col[r]
        for opt in ("passwordAuth", "oauth2", "authAlert", "mfa", "otp", "authToken"):
            if opt in col:
                v = dict(col[opt]) if isinstance(col[opt], dict) else col[opt]
                if isinstance(v, dict):
                    v.pop("secret", None)
                    if opt == "oauth2":
                        v = {"enabled": v.get("enabled"), "providers": len(v.get("providers") or [])}
                entry[opt] = v
        res[col["name"]] = entry
    return res, flavour


def schema(args):
    a, _ = normalise_collections(args.base_a, args.su_email, args.su_password)
    b, _ = normalise_collections(args.base_b, args.su_email_b or args.su_email,
                                 args.su_password_b or args.su_password)
    if args.out:
        with open(args.out, "w") as fh:
            json.dump({"a": a, "b": b}, fh, indent=1, sort_keys=True, ensure_ascii=False)
    out = []
    ignore = [lambda p, e=e: e in p for e in (args.ignore or [])]
    diff(a, b, "", out, ignore)
    print(f"{len(out)} schema differences")
    for k, p, x, y in out:
        print(f"  [{k}] {p}: {json.dumps(x, ensure_ascii=False)[:200]} -> {json.dumps(y, ensure_ascii=False)[:200]}")
    return 1 if out else 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    def users(p):
        p.add_argument("--base", required=True)
        p.add_argument("--user-a")
        p.add_argument("--user-b")
        p.add_argument("--password", default="")

    p = sub.add_parser("seed")
    users(p)
    p = sub.add_parser("dump")
    users(p)
    p.add_argument("--su-email")
    p.add_argument("--su-password")
    p.add_argument("--out", required=True)
    p.add_argument("--tokens-out")
    p.add_argument("--legacy-tokens")
    p = sub.add_parser("compare")
    p.add_argument("before")
    p.add_argument("after")
    p.add_argument("--out")
    p.add_argument("--ignore", action="append")
    p.add_argument("--ignore-error-format", action="store_true",
                   help="ignore the known 0.23 error JSON changes (code->status, message wording)")
    p = sub.add_parser("schema")
    p.add_argument("--base-a", required=True)
    p.add_argument("--base-b", required=True)
    p.add_argument("--su-email", required=True)
    p.add_argument("--su-password", required=True)
    p.add_argument("--su-email-b")
    p.add_argument("--su-password-b")
    p.add_argument("--out")
    p.add_argument("--ignore", action="append")
    args = ap.parse_args()
    if args.cmd == "seed":
        seed(args)
    elif args.cmd == "dump":
        dump(args)
    elif args.cmd == "compare":
        sys.exit(compare(args))
    elif args.cmd == "schema":
        sys.exit(schema(args))


if __name__ == "__main__":
    main()
