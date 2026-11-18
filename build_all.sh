#!/usr/bin/env bash
# Builds the whole pipeline in one command: warehouse -> data marts.
# Requires the 4 CSVs in data/ (see README "How to Run").
# Run from anywhere:  bash build_all.sh
set -euo pipefail
cd "$(dirname "$0")"

for f in 01_warehouse/01_create_tables.sql \
         01_warehouse/02_load_data.sql \
         02_marts/03_create_flat_mart.sql \
         02_marts/04_create_skills_mart.sql \
         02_marts/05_create_priority_mart.sql \
         02_marts/06_update_priority_mart.sql; do
  echo "== Running $f"
  mysql --local-infile=1 -u root < "$f"
done

echo "== Pipeline build complete"
