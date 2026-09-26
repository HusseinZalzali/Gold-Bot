#!/usr/bin/env python3
"""
GoldBot V3 trade analyzer (transparent, standard library only).

Reads the trade CSV files written by GoldBotV3 (GoldBotV3_<tag>_trades.csv)
and prints:
  * summary metrics (actual costs and estimated costs)
  * breakdowns by direction, session, year, month, hour, weekday, ATR regime,
    score range, confirmation type, trend class, zone type, break-even use
  * a cost-sensitivity table (extra spread/slippage per trade)
  * an optional in-sample / out-of-sample split
  * a side-by-side comparison when several files (configurations) are given
  * an evaluation checklist that labels a configuration
    PROMISING / NOT PROMISING / INSUFFICIENT DATA

It never declares a strategy "profitable". Every threshold is a command-line
option, printed in the output, so nothing is hidden.

Examples:
  python3 analyze_trades.py GoldBotV3_IS_2022-2024_trades.csv
  python3 analyze_trades.py trades.csv --split 2025-01-01
  python3 analyze_trades.py rr2.csv rr3.csv rr4.csv rr5.csv --compare
  python3 analyze_trades.py trades.csv --groups direction session year
"""

import argparse
import csv
import math
import os
import sys
from collections import OrderedDict
from datetime import date, datetime

SAMPLE_VERY_WEAK = 30
SAMPLE_PRELIMINARY = 50
SAMPLE_LIMITED = 100

GROUPS = OrderedDict([
    ("direction", ("Direction", lambda t: t["direction"])),
    ("session", ("Session", lambda t: t["session"])),
    ("year", ("Year", lambda t: t["year"])),
    ("month", ("Month", lambda t: "%s-%02d" % (t["year"], int(t["month"] or 0)))),
    ("weekday", ("Weekday", lambda t: WEEKDAYS.get(t["weekday"], t["weekday"]))),
    ("hour", ("Entry hour (server)", lambda t: "%02d" % int(t["hour"] or 0))),
    ("atr_regime", ("ATR regime", lambda t: t["atr_regime"] or "unknown")),
    ("score_range", ("Quality score", lambda t: t["score_range"] or "unknown")),
    ("confirmation", ("Confirmation", lambda t: t["confirmation"] or "unknown")),
    ("trend", ("Trend class", lambda t: t["trend"] or "unknown")),
    ("zone", ("Zone type", lambda t: t["zone"] or "unknown")),
    ("break_even", ("Break-even moved", lambda t: {"1": "yes", "0": "no"}.get(t["break_even_moved"], "unknown"))),
    ("exit", ("Exit type", lambda t: t["exit"])),
])

WEEKDAYS = {"0": "0 Sunday", "1": "1 Monday", "2": "2 Tuesday", "3": "3 Wednesday",
            "4": "4 Thursday", "5": "5 Friday", "6": "6 Saturday"}


# ----------------------------------------------------------------------------
# Loading
# ----------------------------------------------------------------------------
def to_float(value, default=None):
    try:
        if value is None or value == "":
            return default
        return float(value)
    except ValueError:
        return default


def load_trades(path):
    trades = []
    with open(path, newline="", encoding="utf-8-sig", errors="replace") as handle:
        reader = csv.DictReader(handle)
        for row in reader:
            row = {k.strip(): (v.strip() if isinstance(v, str) else v) for k, v in row.items() if k}
            try:
                row["_open"] = datetime.strptime(row["open_time"], "%Y.%m.%d %H:%M")
                row["_close"] = datetime.strptime(row["close_time"], "%Y.%m.%d %H:%M")
            except (KeyError, ValueError):
                continue
            row["_net"] = to_float(row.get("net"), 0.0)
            row["_net_est"] = to_float(row.get("net_after_est_costs"), row["_net"])
            row["_r"] = to_float(row.get("r"))
            row["_r_est"] = to_float(row.get("r_after_est_costs"))
            row["_risk"] = to_float(row.get("risk_money"))
            row["_sl_pips"] = to_float(row.get("sl_pips"))
            row["_spread"] = to_float(row.get("spread_pips"))
            trades.append(row)
    trades.sort(key=lambda t: t["_open"])
    return trades


def select_values(trades, basis, extra_pips=0.0):
    """Return (money, r_or_None) per trade for the chosen cost basis.

    extra_pips adds a hypothetical extra cost per trade (spread/slippage stress):
    extra R = extra_pips / sl_pips, extra money = risk_money * extra R.
    """
    values = []
    for t in trades:
        money = t["_net_est"] if basis == "estimated" else t["_net"]
        r = t["_r_est"] if basis == "estimated" else t["_r"]
        if extra_pips and t["_sl_pips"] and t["_sl_pips"] > 0:
            extra_r = extra_pips / t["_sl_pips"]
            if r is not None:
                r -= extra_r
            if t["_risk"]:
                money -= t["_risk"] * extra_r
        values.append((money, r))
    return values


# ----------------------------------------------------------------------------
# Metrics
# ----------------------------------------------------------------------------
def outcome_of(money, r, band):
    if r is not None:
        if r > band:
            return "W"
        if r < -band:
            return "L"
        return "BE"
    if money > 0:
        return "W"
    if money < 0:
        return "L"
    return "BE"


def compute(trades, basis="estimated", extra_pips=0.0, band=0.10):
    vals = select_values(trades, basis, extra_pips)
    m = OrderedDict()
    n = len(vals)
    m["trades"] = n
    if n == 0:
        return m
    outcomes = [outcome_of(money, r, band) for money, r in vals]
    wins = outcomes.count("W")
    losses = outcomes.count("L")
    bes = outcomes.count("BE")
    gross_profit = sum(v for v, _ in vals if v > 0)
    gross_loss = -sum(v for v, _ in vals if v < 0)
    net = gross_profit - gross_loss
    rs = [r for _, r in vals if r is not None]
    win_r = [r for (money, r), o in zip(vals, outcomes) if o == "W" and r is not None]
    loss_r = [r for (money, r), o in zip(vals, outcomes) if o == "L" and r is not None]

    # Drawdown on the money curve and the R curve (R is account-size independent)
    def drawdown(series):
        cum = peak = max_dd = 0.0
        for x in series:
            cum += x
            peak = max(peak, cum)
            max_dd = max(max_dd, peak - cum)
        return max_dd

    # Longest drawdown duration (days) on the money curve
    cum = peak = 0.0
    peak_time = trades[0]["_open"]
    longest_days = 0.0
    for t, (money, _) in zip(trades, vals):
        cum += money
        if cum >= peak:
            peak, peak_time = cum, t["_close"]
        else:
            longest_days = max(longest_days, (t["_close"] - peak_time).total_seconds() / 86400.0)

    streak = max_streak = 0
    for o in outcomes:
        streak = streak + 1 if o == "L" else 0
        max_streak = max(max_streak, streak)

    months = OrderedDict()
    years = OrderedDict()
    for t, (money, _) in zip(trades, vals):
        months.setdefault(t["_open"].strftime("%Y-%m"), 0.0)
        months[t["_open"].strftime("%Y-%m")] += money
        years.setdefault(t["_open"].year, 0.0)
        years[t["_open"].year] += money

    first, last = trades[0]["_open"], trades[-1]["_close"]
    first_day = first.date()
    weekdays = sum(1 for d in range((last.date() - first_day).days + 1)
                   if date.fromordinal(first_day.toordinal() + d).weekday() < 5)

    max_dd_money = drawdown([v for v, _ in vals])
    m.update(OrderedDict([
        ("wins", wins), ("losses", losses), ("breakevens", bes),
        ("win_rate", 100.0 * wins / n),
        ("net", net),
        ("expectancy", net / n),
        ("profit_factor", gross_profit / gross_loss if gross_loss > 0 else (math.inf if gross_profit > 0 else None)),
        ("r_count", len(rs)),
        ("total_r", sum(rs) if rs else None),
        ("avg_r", sum(rs) / len(rs) if rs else None),
        ("avg_win", gross_profit / wins if wins else None),
        ("avg_loss", -gross_loss / losses if losses else None),
        ("avg_win_r", sum(win_r) / len(win_r) if win_r else None),
        ("avg_loss_r", sum(loss_r) / len(loss_r) if loss_r else None),
        ("largest_win", max(v for v, _ in vals)),
        ("largest_loss", min(v for v, _ in vals)),
        ("max_dd", max_dd_money),
        ("max_dd_r", drawdown(rs) if rs else None),
        ("recovery_factor", net / max_dd_money if max_dd_money > 0 else None),
        ("max_consec_losses", max_streak),
        ("longest_dd_days", longest_days),
        ("trades_per_weekday", n / weekdays if weekdays else None),
        ("months", months),
        ("years", years),
        ("avg_spread", (sum(t["_spread"] for t in trades if t["_spread"] is not None) /
                        max(1, sum(1 for t in trades if t["_spread"] is not None)))
         if any(t["_spread"] is not None for t in trades) else None),
        ("first", first), ("last", last),
    ]))
    return m


def sample_label(n):
    if n < SAMPLE_VERY_WEAK:
        return "VERY WEAK (<30)"
    if n < SAMPLE_PRELIMINARY:
        return "PRELIMINARY (<50)"
    if n < SAMPLE_LIMITED:
        return "LIMITED (<100)"
    return ""


def fmt(value, spec="%.2f", none="n/a"):
    if value is None:
        return none
    if isinstance(value, float) and math.isinf(value):
        return "inf"
    return spec % value


# ----------------------------------------------------------------------------
# Output
# ----------------------------------------------------------------------------
def print_summary(title, m, basis):
    print("=" * 78)
    print(title)
    print("=" * 78)
    if m.get("trades", 0) == 0:
        print("No trades.")
        return
    months, years = m["months"], m["years"]
    pos_months = sum(1 for v in months.values() if v > 0)
    print("Cost basis           : %s" % ("after ESTIMATED costs (net_after_est_costs / r_after_est_costs)"
                                         if basis == "estimated" else "ACTUAL charged costs (net / r)"))
    print("Period               : %s -> %s" % (m["first"].strftime("%Y-%m-%d"), m["last"].strftime("%Y-%m-%d")))
    print("Trades               : %d  %s" % (m["trades"], sample_label(m["trades"])))
    print("Wins / Losses / BE   : %d / %d / %d   (win rate %.1f%%)" % (m["wins"], m["losses"], m["breakevens"], m["win_rate"]))
    print("Net profit           : %s" % fmt(m["net"]))
    print("Expectancy / trade   : %s (money)   %s R" % (fmt(m["expectancy"]), fmt(m["avg_r"], "%+.3f")))
    print("Total R              : %s   (R known for %d trades)" % (fmt(m["total_r"], "%+.2f"), m["r_count"]))
    print("Profit factor        : %s" % fmt(m["profit_factor"]))
    print("Average win / loss   : %s (%s R) / %s (%s R)" % (fmt(m["avg_win"]), fmt(m["avg_win_r"], "%+.2f"),
                                                             fmt(m["avg_loss"]), fmt(m["avg_loss_r"], "%+.2f")))
    print("Largest win / loss   : %s / %s" % (fmt(m["largest_win"]), fmt(m["largest_loss"])))
    print("Max drawdown         : %s money   %s R" % (fmt(m["max_dd"]), fmt(m["max_dd_r"], "%.2f")))
    print("Recovery factor      : %s   (net / max drawdown)" % fmt(m["recovery_factor"]))
    print("Max consecutive loss : %d" % m["max_consec_losses"])
    print("Longest drawdown     : %.0f days" % m["longest_dd_days"])
    print("Trades per weekday   : %s" % fmt(m["trades_per_weekday"], "%.2f"))
    print("Average entry spread : %s pips" % fmt(m["avg_spread"], "%.1f"))
    print("Positive months      : %d of %d (%.0f%%)" % (pos_months, len(months), 100.0 * pos_months / max(1, len(months))))
    print("By year              : " + ", ".join("%s: %s" % (y, fmt(v)) for y, v in years.items()))


def print_groups(trades, keys, basis, band):
    for key in keys:
        if key not in GROUPS:
            print("Unknown group '%s'. Valid: %s" % (key, ", ".join(GROUPS)))
            continue
        title, fn = GROUPS[key]
        buckets = OrderedDict()
        for t in trades:
            buckets.setdefault(fn(t), []).append(t)
        print("-" * 78)
        print("By %s" % title)
        print("  %-20s %5s %9s %6s %11s %9s %6s %8s %8s  %s" %
              ("group", "n", "W/L/BE", "win%", "net", "exp", "PF", "avgR", "DD(R)", "sample"))
        for name in sorted(buckets):
            m = compute(buckets[name], basis, band=band)
            print("  %-20s %5d %9s %5.1f%% %11s %9s %6s %8s %8s  %s" %
                  (str(name)[:20], m["trades"], "%d/%d/%d" % (m["wins"], m["losses"], m["breakevens"]),
                   m["win_rate"], fmt(m["net"]), fmt(m["expectancy"]), fmt(m["profit_factor"]),
                   fmt(m["avg_r"], "%+.3f"), fmt(m["max_dd_r"], "%.1f"), sample_label(m["trades"])))


def print_cost_sensitivity(trades, basis, band, steps):
    print("-" * 78)
    print("Cost sensitivity: extra cost per trade on top of the %s basis" % basis)
    print("(extra R = extra pips / SL pips of each trade; needs sl_pips in the CSV)")
    print("  %-12s %11s %8s %8s %8s" % ("extra pips", "net", "PF", "avgR", "win%"))
    for extra in steps:
        m = compute(trades, basis, extra, band)
        if m.get("trades", 0) == 0:
            continue
        print("  %-12s %11s %8s %8s %7.1f%%" % ("+%.1f" % extra, fmt(m["net"]), fmt(m["profit_factor"]),
                                               fmt(m["avg_r"], "%+.3f"), m["win_rate"]))


def evaluate(m, args, oos=None):
    """Evaluation checklist. Returns list of (criterion, status, detail)."""
    rows = []
    n = m.get("trades", 0)

    def add(name, ok, detail, insufficient=False):
        rows.append((name, "INSUFFICIENT" if insufficient else ("PASS" if ok else "FAIL"), detail))

    add("Enough trades", n >= args.min_trades, "%d trades (need >= %d)" % (n, args.min_trades))
    if n == 0:
        return rows
    add("Net profit after costs > 0", m["net"] > 0, "net %s" % fmt(m["net"]))
    add("Average R after costs >= %.2f" % args.min_avg_r,
        m["avg_r"] is not None and m["avg_r"] >= args.min_avg_r, "avg R %s" % fmt(m["avg_r"], "%+.3f"),
        insufficient=m["avg_r"] is None)
    pf = m["profit_factor"]
    add("Profit factor >= %.2f" % args.min_pf, pf is not None and pf >= args.min_pf, "PF %s" % fmt(pf))
    rf = m["recovery_factor"]
    add("Recovery factor >= %.1f" % args.min_recovery, rf is not None and rf >= args.min_recovery, "RF %s" % fmt(rf))
    share = m["largest_win"] / m["net"] * 100.0 if m["net"] > 0 else None
    add("Largest win < %.0f%% of net" % args.max_single_trade_share,
        share is not None and share < args.max_single_trade_share, "largest win = %s%% of net" % fmt(share, "%.0f"))
    months = m["months"]
    if months:
        best = max(months, key=months.get)
        without = m["net"] - months[best]
        add("Still positive without best month", without > 0, "best month %s; net without it %s" % (best, fmt(without)))
    years = m["years"]
    if len(years) >= 2:
        best_year = max(years, key=years.get)
        without = m["net"] - years[best_year]
        add("Still positive without best year", without > 0, "best year %s; net without it %s" % (best_year, fmt(without)))
        positive = sum(1 for v in years.values() if v > 0)
        add("At least half of the years positive", positive * 2 >= len(years), "%d of %d years positive" % (positive, len(years)))
    else:
        add("Multiple years tested", False, "only %d year(s) of trades" % len(years), insufficient=True)
    if oos is not None:
        on = oos.get("trades", 0)
        if on < SAMPLE_VERY_WEAK:
            add("Out-of-sample average R > 0", False, "%d OOS trades (need >= %d)" % (on, SAMPLE_VERY_WEAK), insufficient=True)
        else:
            add("Out-of-sample average R > 0", oos["avg_r"] is not None and oos["avg_r"] > 0,
                "OOS avg R %s over %d trades" % (fmt(oos["avg_r"], "%+.3f"), on))
    return rows


def print_evaluation(rows, has_oos):
    print("-" * 78)
    print("Evaluation checklist (guidance thresholds, change them with command-line options)")
    for name, status, detail in rows:
        print("  [%-12s] %-40s %s" % (status, name, detail))
    statuses = [s for _, s, _ in rows]
    if "FAIL" in statuses:
        verdict = "NOT PROMISING - at least one criterion failed (see above)."
    elif "INSUFFICIENT" in statuses:
        verdict = "INSUFFICIENT DATA - more trades / years / out-of-sample data needed."
    else:
        verdict = "PROMISING on these criteria - NOT proof of future profitability."
    print("  Verdict: " + verdict)
    if not has_oos:
        print("  Note: no out-of-sample split given (--split). In-sample results alone are never enough.")
    print("  Also required before any live use: stable results for nearby parameter values and a demo forward test.")


def print_comparison(files, results, band):
    print("=" * 78)
    print("Configuration comparison (same cost basis for all files)")
    print("=" * 78)
    print("  %-34s %5s %6s %8s %6s %10s %7s %6s" % ("file", "n", "win%", "avgR", "PF", "net", "DD(R)", "RF"))
    avg_rs = []
    for path, m in zip(files, results):
        if m.get("trades", 0) == 0:
            print("  %-34s no trades" % os.path.basename(path)[-34:])
            continue
        avg_rs.append(m["avg_r"])
        print("  %-34s %5d %5.1f%% %8s %6s %10s %7s %6s" %
              (os.path.basename(path)[-34:], m["trades"], m["win_rate"], fmt(m["avg_r"], "%+.3f"), fmt(m["profit_factor"]),
               fmt(m["net"]), fmt(m["max_dd_r"], "%.1f"), fmt(m["recovery_factor"])))
    valid = [x for x in avg_rs if x is not None]
    if len(valid) >= 2:
        print("-" * 78)
        print("Neighbour stability: avg R ranges from %+.3f to %+.3f; %d of %d configurations positive."
              % (min(valid), max(valid), sum(1 for x in valid if x > 0), len(valid)))
        print("If only one value is positive and its neighbours are not, suspect curve-fitting.")


def main():
    parser = argparse.ArgumentParser(description="Analyze GoldBot V3 trade CSV files (no black box).")
    parser.add_argument("files", nargs="+", help="GoldBotV3_*_trades.csv file(s)")
    parser.add_argument("--costs", choices=["estimated", "actual"], default="estimated",
                        help="cost basis: estimated (default, conservative) or actual charged costs")
    parser.add_argument("--from", dest="date_from", help="only trades opened on/after YYYY-MM-DD")
    parser.add_argument("--to", dest="date_to", help="only trades opened before YYYY-MM-DD")
    parser.add_argument("--split", help="out-of-sample start date YYYY-MM-DD (trades before = in-sample)")
    parser.add_argument("--groups", nargs="*", default=list(GROUPS),
                        help="breakdowns to print (default all): " + " ".join(GROUPS))
    parser.add_argument("--compare", action="store_true", help="only print a side-by-side comparison of the files")
    parser.add_argument("--be-band", type=float, default=0.10, help="|R| <= this counts as break-even (default 0.10)")
    parser.add_argument("--cost-steps", type=float, nargs="*", default=[0.0, 0.5, 1.0, 2.0, 3.0],
                        help="extra pips per trade for the cost-sensitivity table")
    parser.add_argument("--min-trades", type=int, default=100)
    parser.add_argument("--min-avg-r", type=float, default=0.05)
    parser.add_argument("--min-pf", type=float, default=1.2)
    parser.add_argument("--min-recovery", type=float, default=2.0)
    parser.add_argument("--max-single-trade-share", type=float, default=25.0)
    args = parser.parse_args()

    def in_range(t):
        if args.date_from and t["_open"] < datetime.strptime(args.date_from, "%Y-%m-%d"):
            return False
        if args.date_to and t["_open"] >= datetime.strptime(args.date_to, "%Y-%m-%d"):
            return False
        return True

    all_trades = []
    for path in args.files:
        try:
            trades = [t for t in load_trades(path) if in_range(t)]
        except FileNotFoundError:
            print("File not found: %s" % path)
            return 1
        all_trades.append(trades)

    if args.compare or len(args.files) > 1:
        results = [compute(t, args.costs, band=args.be_band) for t in all_trades]
        print_comparison(args.files, results, args.be_band)
        if args.compare:
            return 0

    for path, trades in zip(args.files, all_trades):
        print()
        print("#" * 78)
        print("# %s" % path)
        print("#" * 78)
        if args.split:
            split = datetime.strptime(args.split, "%Y-%m-%d")
            ins = [t for t in trades if t["_open"] < split]
            oos = [t for t in trades if t["_open"] >= split]
            m_in = compute(ins, args.costs, band=args.be_band)
            m_oos = compute(oos, args.costs, band=args.be_band)
            print_summary("IN-SAMPLE (before %s)" % args.split, m_in, args.costs)
            print_summary("OUT-OF-SAMPLE (from %s)" % args.split, m_oos, args.costs)
            print_groups(ins, args.groups, args.costs, args.be_band)
            print_cost_sensitivity(ins, args.costs, args.be_band, args.cost_steps)
            print_evaluation(evaluate(m_in, args, m_oos), True)
        else:
            m = compute(trades, args.costs, band=args.be_band)
            print_summary("ALL TRADES", m, args.costs)
            print_groups(trades, args.groups, args.costs, args.be_band)
            print_cost_sensitivity(trades, args.costs, args.be_band, args.cost_steps)
            print_evaluation(evaluate(m, args), False)
        print()
        print("Reminder: historical results do not guarantee future performance.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
