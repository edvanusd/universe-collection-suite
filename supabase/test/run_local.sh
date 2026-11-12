#!/usr/bin/env bash
# Buat ulang database uji lokal lalu jalankan semua pengujian backend.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
export PGOPTIONS="-c client_min_messages=warning"
P="psql -h ${PGHOST:-/tmp} -p ${PGPORT:-54329} -U postgres -v ON_ERROR_STOP=1 -q"
$P -c "drop database if exists ucs" -c "create database ucs"
$P -d ucs -f "$HERE/supabase_stub.sql" 2>&1 | grep -v -i "wal_level\|HINT" || true
$P -d ucs -f "$HERE/../setup.sql" >/dev/null
$P -d ucs -f "$HERE/../setup.sql" >/dev/null   # harus aman dijalankan dua kali
python3 "$HERE/test_backend.py" "host=${PGHOST:-/tmp} port=${PGPORT:-54329} dbname=ucs user=postgres"
