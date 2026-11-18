-- =====================================================================
-- Master build script: warehouse + KPI views in one command.
-- Run from the project root AFTER generating the data:
--   python3 00_generate_data/generate_data.py
--   mysql --local-infile=1 -u root < build_all.sql
-- =====================================================================

source 01_warehouse/01_create_tables.sql
source 01_warehouse/02_load_data.sql
source 02_kpi_views/01_create_kpi_views.sql

SELECT '=== Supply chain KPI warehouse built ===' AS status;
