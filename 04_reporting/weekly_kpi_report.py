"""
Step 5: Automated weekly KPI report (MySQL -> Excel)

Pulls the KPI views and analysis queries from the supply_chain warehouse
and writes a formatted, multi-tab Excel workbook with a trend chart:

  Summary              headline KPIs: this week vs last week vs 13-week average
  OTIF Trend           13 weeks of OTIF with a 4-week rolling line + chart
  Warehouse Scorecard  DC ranking (03_analysis/02_warehouse_scorecard.sql)
  Problem SKUs         top shortfall SKUs (03_analysis/03_problem_skus.sql)
  Backlog Aging        open orders by age (03_analysis/04_backlog_aging.sql)
  Inventory Turns      last 6 months of turns by DC

The analysis tabs run the exact SQL files in 03_analysis/, so the report and
the SQL can never drift apart.

Usage (from the project root, after building the warehouse):
    python3 04_reporting/weekly_kpi_report.py

Connection: reads [client] settings from ~/.my.cnf (port, socket, user) if
present. Override with environment variables MYSQL_HOST, MYSQL_PORT,
MYSQL_USER, MYSQL_PASSWORD.
"""

import os
import re
import time
from pathlib import Path

import pandas as pd
import pymysql
from openpyxl import load_workbook
from openpyxl.chart import LineChart, Reference
from openpyxl.styles import Alignment, Font, PatternFill
from openpyxl.utils import get_column_letter

ROOT = Path(__file__).resolve().parent.parent
ANALYSIS_DIR = ROOT / "03_analysis"
REPORTS_DIR = ROOT / "reports"
DATABASE = "supply_chain"


# ---------------------------------------------------------------------
# Database helpers
# ---------------------------------------------------------------------
def connect():
    kwargs = {"database": DATABASE, "charset": "utf8mb4"}
    my_cnf = Path.home() / ".my.cnf"
    if my_cnf.exists():
        kwargs["read_default_file"] = str(my_cnf)
    if os.getenv("MYSQL_HOST"):
        kwargs["host"] = os.environ["MYSQL_HOST"]
    if os.getenv("MYSQL_PORT"):
        kwargs["port"] = int(os.environ["MYSQL_PORT"])
    kwargs["user"] = os.getenv("MYSQL_USER", "root")
    if os.getenv("MYSQL_PASSWORD"):
        kwargs["password"] = os.environ["MYSQL_PASSWORD"]
    return pymysql.connect(**kwargs)


def query(conn, sql, params=None):
    with conn.cursor() as cur:
        cur.execute(sql, params)
        cols = [c[0] for c in cur.description]
        rows = cur.fetchall()
    df = pd.DataFrame(rows, columns=cols)
    # MySQL returns DECIMAL as Python Decimal; convert to float for Excel math
    for c in df.columns:
        if df[c].dtype == object and len(df) and type(df[c].iloc[0]).__name__ == "Decimal":
            df[c] = df[c].astype(float)
    return df


def run_sql_file(conn, filename):
    """Run an analysis .sql file (drops the USE line and block comments)."""
    sql = (ANALYSIS_DIR / filename).read_text()
    sql = re.sub(r"/\*.*?\*/", "", sql, flags=re.S)
    sql = re.sub(r"^\s*USE\s+\w+\s*;", "", sql, flags=re.M | re.I)
    return query(conn, sql.strip().rstrip(";"))


# ---------------------------------------------------------------------
# Build the report data
# ---------------------------------------------------------------------
def build_summary(conn):
    weekly = query(conn, """
        SELECT o.week_start,
               SUM(o.lines_due) AS lines_due, SUM(o.lines_otif) AS lines_otif,
               SUM(o.lines_on_time) AS lines_on_time, SUM(o.lines_in_full) AS lines_in_full,
               SUM(f.units_ordered) AS units_ordered, SUM(f.units_shipped) AS units_shipped
        FROM vw_otif_weekly o
        JOIN vw_fill_rate_weekly f
          ON f.week_start = o.week_start AND f.warehouse_name = o.warehouse_name
        GROUP BY o.week_start
        ORDER BY o.week_start
    """)
    backlog = query(conn, """
        SELECT week_end, SUM(open_value) AS open_value, SUM(past_due_value) AS past_due_value
        FROM vw_backlog_weekly GROUP BY week_end ORDER BY week_end
    """)
    turns = query(conn, """
        SELECT month, SUM(cogs) * 12 / SUM(avg_inventory_value) AS turns
        FROM vw_inventory_turns_monthly GROUP BY month ORDER BY month
    """)

    weekly["otif"] = weekly.lines_otif / weekly.lines_due
    weekly["on_time"] = weekly.lines_on_time / weekly.lines_due
    weekly["in_full"] = weekly.lines_in_full / weekly.lines_due
    weekly["fill_rate"] = weekly.units_shipped / weekly.units_ordered

    this_wk, last_wk = weekly.iloc[-1], weekly.iloc[-2]
    last13 = weekly.tail(13)
    report_week = pd.Timestamp(this_wk.week_start)
    week_end = report_week + pd.Timedelta(days=6)

    backlog["week_end"] = pd.to_datetime(backlog.week_end)
    b_now = backlog[backlog.week_end == week_end].iloc[0]
    b_prev = backlog[backlog.week_end == week_end - pd.Timedelta(days=7)].iloc[0]
    b_13 = backlog[backlog.week_end <= week_end].tail(13)

    # Latest COMPLETE month for turns (the report week's month may be partial)
    complete_months = turns[turns.month < week_end.strftime("%Y-%m")]
    t_now, t_prev = complete_months.iloc[-1], complete_months.iloc[-2]

    def rate(sum_num, sum_den):
        return sum_num / sum_den

    rows = [
        ("OTIF (on time in full)", this_wk.otif, last_wk.otif,
         rate(last13.lines_otif.sum(), last13.lines_due.sum()), "pct", True),
        ("On time", this_wk.on_time, last_wk.on_time,
         rate(last13.lines_on_time.sum(), last13.lines_due.sum()), "pct", True),
        ("In full", this_wk.in_full, last_wk.in_full,
         rate(last13.lines_in_full.sum(), last13.lines_due.sum()), "pct", True),
        ("Unit fill rate", this_wk.fill_rate, last_wk.fill_rate,
         rate(last13.units_shipped.sum(), last13.units_ordered.sum()), "pct", True),
        ("Open backlog value ($)", b_now.open_value, b_prev.open_value,
         b_13.open_value.mean(), "usd", False),
        ("Past due backlog value ($)", b_now.past_due_value, b_prev.past_due_value,
         b_13.past_due_value.mean(), "usd", False),
        (f"Inventory turns (annualized, {t_now.month})", t_now.turns, t_prev.turns,
         complete_months.tail(3).turns.mean(), "num", True),
    ]
    summary = pd.DataFrame(rows, columns=["KPI", "This period", "Prior period",
                                          "13 week / 3 month avg", "fmt", "higher_is_better"])
    summary["Change"] = summary["This period"] - summary["Prior period"]

    trend = weekly.tail(13).copy()
    trend["otif_rolling_4wk"] = (weekly.lines_otif.rolling(4).sum()
                                 / weekly.lines_due.rolling(4).sum()).tail(13)
    trend = trend[["week_start", "lines_due", "otif", "otif_rolling_4wk", "on_time", "in_full", "fill_rate"]]
    trend.columns = ["Week start", "Lines due", "OTIF", "OTIF 4 wk rolling",
                     "On time", "In full", "Unit fill rate"]
    return summary, trend, report_week


def build_turns_table(conn):
    t = query(conn, """
        SELECT month, warehouse_name, annualized_turns
        FROM vw_inventory_turns_monthly
        ORDER BY month
    """)
    pivot = t.pivot(index="month", columns="warehouse_name", values="annualized_turns").tail(6)
    return pivot.reset_index().rename(columns={"month": "Month"})


# ---------------------------------------------------------------------
# Excel formatting
# ---------------------------------------------------------------------
HEADER_FILL = PatternFill("solid", fgColor="1F3864")
HEADER_FONT = Font(bold=True, color="FFFFFF")
GOOD = Font(color="1E7B34", bold=True)
BAD = Font(color="C00000", bold=True)


def style_sheet(ws, pct_cols=(), usd_cols=(), num_cols=()):
    for cell in ws[1]:
        cell.fill, cell.font = HEADER_FILL, HEADER_FONT
        cell.alignment = Alignment(horizontal="center", vertical="center", wrap_text=True)
    ws.freeze_panes = "A2"
    for col in ws.columns:
        letter = get_column_letter(col[0].column)
        width = max(len(str(c.value)) if c.value is not None else 0 for c in col)
        ws.column_dimensions[letter].width = min(max(width + 2, 10), 45)
        header = col[0].value
        for c in col[1:]:
            if header in pct_cols:
                c.number_format = "0.0%"
            elif header in usd_cols:
                c.number_format = "$#,##0"
            elif header in num_cols:
                c.number_format = "0.0"


def format_summary(ws, summary):
    # Column order: KPI | This | Prior | Change | Avg
    for i, row in enumerate(summary.itertuples(index=False), start=2):
        fmt = {"pct": "0.0%", "usd": "$#,##0", "num": "0.0"}[row.fmt]
        for col in (2, 3, 5):
            ws.cell(row=i, column=col).number_format = fmt
        change = ws.cell(row=i, column=4)
        change.number_format = {"pct": '+0.0" pts";-0.0" pts"',
                                "usd": '+$#,##0;-$#,##0', "num": "+0.0;-0.0"}[row.fmt]
        if row.fmt == "pct":
            change.value = row.Change * 100
        improved = (row.Change > 0) == bool(row.higher_is_better)
        if abs(row.Change) > 1e-9:
            change.font = GOOD if improved else BAD


def add_trend_chart(ws, n_rows):
    chart = LineChart()
    chart.title = "OTIF: weekly vs 4 week rolling"
    chart.y_axis.title = "OTIF"
    chart.y_axis.number_format = "0%"
    chart.x_axis.title = "Week start"
    chart.height, chart.width = 8, 18
    data = Reference(ws, min_col=3, max_col=4, min_row=1, max_row=n_rows + 1)
    cats = Reference(ws, min_col=1, min_row=2, max_row=n_rows + 1)
    chart.add_data(data, titles_from_data=True)
    chart.set_categories(cats)
    ws.add_chart(chart, "J2")


# ---------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------
def main():
    started = time.perf_counter()
    conn = connect()
    try:
        summary, trend, report_week = build_summary(conn)
        scorecard = run_sql_file(conn, "02_warehouse_scorecard.sql")
        skus = run_sql_file(conn, "03_problem_skus.sql")
        backlog = run_sql_file(conn, "04_backlog_aging.sql")
        turns = build_turns_table(conn)
    finally:
        conn.close()

    REPORTS_DIR.mkdir(exist_ok=True)
    out = REPORTS_DIR / f"weekly_kpi_report_{report_week:%Y-%m-%d}.xlsx"

    summary_out = summary[["KPI", "This period", "Prior period", "Change", "13 week / 3 month avg"]]
    trend["Week start"] = pd.to_datetime(trend["Week start"]).dt.date

    with pd.ExcelWriter(out, engine="openpyxl") as xw:
        summary_out.to_excel(xw, sheet_name="Summary", index=False, startrow=0)
        trend.to_excel(xw, sheet_name="OTIF Trend", index=False)
        scorecard.to_excel(xw, sheet_name="Warehouse Scorecard", index=False)
        skus.to_excel(xw, sheet_name="Problem SKUs", index=False)
        backlog.to_excel(xw, sheet_name="Backlog Aging", index=False)
        turns.to_excel(xw, sheet_name="Inventory Turns", index=False)

    wb = load_workbook(out)
    style_sheet(wb["Summary"])
    format_summary(wb["Summary"], summary)
    ws = wb["Summary"]
    ws.column_dimensions["A"].width = 40
    note_row = len(summary) + 3
    ws.cell(row=note_row, column=1,
            value=f"Report week: {report_week:%b %d, %Y}. Rates use complete weeks; "
                  "inventory turns use the latest complete month.").font = Font(italic=True)

    style_sheet(wb["OTIF Trend"], pct_cols=("OTIF", "OTIF 4 wk rolling", "On time", "In full", "Unit fill rate"))
    add_trend_chart(wb["OTIF Trend"], len(trend))
    style_sheet(wb["Warehouse Scorecard"])
    style_sheet(wb["Problem SKUs"])
    style_sheet(wb["Backlog Aging"], usd_cols=("open_value",))
    style_sheet(wb["Inventory Turns"], num_cols=tuple(turns.columns[1:]))
    wb.save(out)

    elapsed = time.perf_counter() - started
    print(f"Report week: {report_week:%Y-%m-%d}")
    print(f"Saved: {out.relative_to(ROOT)}")
    print(f"Tabs: {', '.join(wb.sheetnames)}")
    print(f"Generated in {elapsed:.1f} seconds")


if __name__ == "__main__":
    main()
