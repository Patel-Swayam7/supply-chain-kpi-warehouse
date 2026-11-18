#!/usr/bin/env bash
# Builds the whole project in one command: data -> warehouse -> KPI views.
# Run from anywhere:  bash build_all.sh
set -euo pipefail
cd "$(dirname "$0")"

echo "== Generating data"
python3 00_generate_data/generate_data.py

for f in 01_warehouse/01_create_tables.sql \
         01_warehouse/02_load_data.sql \
         02_kpi_views/01_create_kpi_views.sql; do
  echo "== Running $f"
  mysql --local-infile=1 -u root < "$f"
done

echo "== Supply chain KPI warehouse built"
