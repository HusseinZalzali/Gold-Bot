# GoldBot V3: Test Report Template

Copy this file once per test (for example `reports/2026-10-05_IS_RR4_ATR.md`) and fill in every field. Leave nothing blank: write "n/a" or "unknown" instead. Most numbers come straight from the EA's report file (`GoldBotV3_<tag>_report.txt`) or from `tools/analyze_trades.py`.

> A filled-in report is a record of what happened in one test. It isn't evidence that the strategy will make money.

---

## 1. Environment

| Field | Value |
|-------|-------|
| Report date | |
| EA version / file | GoldBotV3.mq5 (git commit: ) |
| Symbol (exact broker name) | |
| Broker | |
| Account type (standard / raw / ECN, demo / live) | |
| Server time zone (GMT offset, DST rule) | |
| Contract size / digits / tick size / tick value | |
| Testing model (every tick based on real ticks / every tick / …) | |
| Spread setting (variable from ticks / fixed N points) | |
| Commission charged by tester or broker | |
| Commission assumption input (`InpCommissionPerLot`) | |
| Slippage assumption input (`InpSlippageAssumptionPips`) | |
| Report tag (`InpReportTag`) | |

## 2. Periods

| Period | From | To | Purpose |
|--------|------|----|---------|
| In-sample (development) | | | choose / compare settings |
| Validation | | | check the chosen settings once |
| Out-of-sample (final, untouched) | | | final confirmation, run once |
| Demo forward test | | | live-market conditions |

Were settings changed after seeing validation or out-of-sample results? **yes / no** (if yes, explain, and treat that period as in-sample from now on)

## 3. Configuration

| Setting | Value |
|---------|-------|
| Initial balance / leverage | |
| Risk per trade / lot mode | |
| Trend mode | |
| Stop loss mode (fixed pips / ATR × m), structure SL, buffer, max SL | |
| Risk/reward | |
| Minimum score | |
| Confirmation mode / EMA 9 required | |
| ATR min / max / regime filter | |
| Multi-reaction zone required / zone distance / max distance from zone | |
| Session mode and windows | |
| Break-even (on/off, at R, buffer) | |
| Trailing (off / ATR / fixed, start R, distance) | |
| Daily loss / daily profit / consecutive losses / trades per day / cooldown | |
| Max spread | |
| BUY / SELL allowed | |

Full config line from the log (`Config: ...`):

```
paste here
```

## 4. Results (fill one column per period)

| Metric | In-sample | Validation | Out-of-sample |
|--------|-----------|------------|---------------|
| Total trades | | | |
| Sample-size label | | | |
| Winning / losing / break-even trades | | | |
| Win rate | | | |
| Net profit (actual costs) | | | |
| Net profit after estimated costs | | | |
| Profit factor (actual / est) | | | |
| Expectancy per trade (money) | | | |
| Average R per trade (actual / est) | | | |
| Total R | | | |
| Average win (money / R) | | | |
| Average loss (money / R) | | | |
| Largest win / largest loss | | | |
| Maximum drawdown (money / % / R) | | | |
| Recovery factor | | | |
| Maximum consecutive losses | | | |
| Longest drawdown period (days) | | | |
| Average trades per weekday | | | |
| Positive months (x of y) | | | |
| Positive years (x of y) | | | |

## 5. Breakdowns (after estimated costs)

| Group | Trades | Win % | PF | Avg R | Net | Max DD | Sample label |
|-------|--------|-------|----|-------|-----|--------|--------------|
| BUY | | | | | | | |
| SELL | | | | | | | |
| London only | | | | | | | |
| London/NY overlap | | | | | | | |
| New York only | | | | | | | |
| ATR LOW / NORMAL / HIGH | | | | | | | |
| Score 70-79 / 80-89 / 90-100 | | | | | | | |
| Rejection / engulfing / strong candle | | | | | | | |

## 6. Robustness

| Test | Result (avg R after est. costs, PF, trades) |
|------|---------------------------------------------|
| Extra cost +1 pip per trade (analyzer cost table) | |
| Extra cost +2 pips per trade | |
| Neighbour: min score −10 / +10 | |
| Neighbour: RR −1 / +1 | |
| Neighbour: ATR SL multiplier −0.5 / +0.5 | |
| Other broker or other spread setting | |
| Evaluation checklist verdict (analyzer) | |

## 7. Notes

* Unusual market conditions in the period (for example: major news, war, rate decisions, record highs, flash crashes):
* Tester warnings or data gaps:
* Anything that surprised you in the trade log:
* Decision (keep testing / change one thing / reject configuration) and why:
