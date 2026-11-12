"""Bangun supabase/seed.sql dan supabase/setup.sql dari seed.json.

    python3 tools/make_seed_sql.py [kata_sandi_demo]

seed.sql   : data contoh + akun login petugas (aman dijalankan ulang).
setup.sql  : schema.sql + seed.sql dalam satu file untuk ditempel di SQL Editor.
"""
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PASSWORD = sys.argv[1] if len(sys.argv) > 1 else "demo123"


def lit(v):
    if v is None:
        return "null"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return str(v)
    if isinstance(v, (dict, list)):
        return lit(json.dumps(v, ensure_ascii=False)) + "::jsonb"
    return "'" + str(v).replace("'", "''") + "'"


def insert(table, rows, conflict):
    out = []
    for r in rows:
        cols = list(r.keys())
        out.append(
            "insert into public.%s (%s) values (%s) on conflict (%s) do nothing;"
            % (table, ", ".join(cols), ", ".join(lit(r[c]) for c in cols), conflict)
        )
    return "\n".join(out)


def rename(row, mapping, drop=()):
    o = {}
    for k, v in row.items():
        if k in drop:
            continue
        o[mapping.get(k, k)] = v
    return o


def blank_to_null(row, keys):
    for k in keys:
        if row.get(k) == "":
            row[k] = None
    return row


seed = json.load(open(os.path.join(ROOT, "seed.json"), encoding="utf8"))
cfg = next(m for m in seed["meta"] if m["id"] == "config")

parts = [
    "-- Data contoh Universe Collection Suite (fiktif). Aman dijalankan ulang.",
    "-- Kata sandi semua akun contoh: %s. Ganti setelah uji coba." % PASSWORD,
    "",
    "update public.ucs_app_config set branch = %s, process_date = %s where id = 1;"
    % (lit(cfg["branch"]), lit(cfg["process_date"])),
    "",
    "-- Petugas dan akun login (Supabase Auth)",
]
for s in cfg["staff"]:
    parts.append(
        "select public.ucs_put_staff(%s, %s, %s, %s, %s);"
        % (lit(s["id"]), lit(s["name"]), lit(s["role"]), lit(s["scope"]), lit(PASSWORD))
    )

parts += ["", "-- Account"]
parts.append(insert("ucs_accounts", [rename(a, {"id": "contract_no"}) for a in seed["accounts"]], "contract_no"))

parts += ["", "-- Riwayat aktivitas"]
parts.append(insert(
    "ucs_activities",
    [rename(a, {"by": "actor", "at": "occurred_at"}) for a in seed["activities"]],
    "id"))

parts += ["", "-- Janji bayar"]
parts.append(insert("ucs_ptp", [rename(p, {"by": "actor", "date": "promise_date"}) for p in seed["ptp"]], "id"))

parts += ["", "-- Stok TTR"]
parts.append(insert(
    "ucs_ttr",
    [blank_to_null(rename(t, {"id": "ttr_no"}), ["contract_no", "used_at", "akh_date"]) for t in seed["ttr"]],
    "ttr_no"))

parts += ["", "-- Pengajuan RMP"]
parts.append(insert("ucs_rmp", [rename(r, {"by": "actor"}) for r in seed["rmp"]], "id"))

parts += ["", "-- Kasus skip tracing"]
parts.append(insert("ucs_skip_cases", [rename(c, {"by": "actor", "trigger": "trigger_source"}) for c in seed["skip"]], "id"))

seed_sql = "\n".join(parts) + "\n"
open(os.path.join(ROOT, "supabase", "seed.sql"), "w", encoding="utf8").write(seed_sql)

schema_sql = open(os.path.join(ROOT, "supabase", "schema.sql"), encoding="utf8").read()
open(os.path.join(ROOT, "supabase", "setup.sql"), "w", encoding="utf8").write(
    schema_sql + "\n\n-- =====================================================================\n-- DATA CONTOH\n-- =====================================================================\n" + seed_sql)
print("seed.sql dan setup.sql dibuat:", len(seed["accounts"]), "account,", len(cfg["staff"]), "petugas")
