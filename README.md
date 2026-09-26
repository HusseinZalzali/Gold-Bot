# GoldBot V3: A Testable, Cost-Aware XAUUSD Expert Advisor for MetaTrader 5

GoldBot is a rule-based Expert Advisor (EA) for trading gold (XAUUSD) in MetaTrader 5. **V3** keeps the V2 strategy and turns it into something you can **test objectively**:

* every rule can be switched on or off by itself
* real and estimated trading costs are recorded for every trade
* every trade is classified (direction, session, hour, ATR regime, score, confirmation, …)
* statistics focus on **expectancy after costs**, not on win rate or gross profit
* every result carries **sample-size warnings**
* a transparent offline analyzer (`tools/analyze_trades.py`) compares configurations and in-sample vs out-of-sample results.

> ## ⚠️ Current evidence status: NONE
>
> **V3 has not been backtested yet.** The environment used to build it has no MetaTrader 5, no Strategy Tester and no broker tick data, so **no performance numbers exist**. **Nothing in this repository claims or implies that any GoldBot version is profitable.**
>
> Section 4 lists **which rules must be tested and how**, but those are *hypotheses* with a test plan. They are not findings. Section 17's numbers are **invented** to show how to read a report.
>
> The only way to learn whether this strategy has an edge is the process in sections 12–15: separated in-sample, validation and out-of-sample tests, realistic costs, enough trades, then a demo forward test. If that process shows no edge, the honest conclusion is **"no edge found"**.

The bot doesn't predict where gold will go. It checks:

> "The market is trending" + "price reached an area that mattered before" + "price reacted in the expected direction" + "EMA 9 confirms timing" + "volatility, spread and session are acceptable" + "risk is acceptable" + "historical testing supports this configuration". **Then it trades. Otherwise it waits.**

There's no AI, machine learning, martingale, grid, averaging down, hedging, recovery logic or forced trading.

---

## Contents
1. [Project structure](#1-project-structure)
2. [What changed from V2](#2-what-changed-from-v2)
3. [Exact V3 trading rules](#3-exact-v3-trading-rules)
4. [Rule review: purpose, status and test plan](#4-rule-review-purpose-status-and-test-plan)
5. [Quality score](#5-quality-score)
6. [Stop loss, take profit and trade management](#6-stop-loss-take-profit-and-trade-management)
7. [Risk, daily and account protection](#7-risk-daily-and-account-protection)
8. [Trading costs: how they are included](#8-trading-costs-how-they-are-included)
9. [Performance metrics explained](#9-performance-metrics-explained)
10. [Installation](#10-installation)
11. [Backtesting](#11-backtesting)
12. [In-sample, validation, out-of-sample and walk-forward testing](#12-in-sample-validation-out-of-sample-and-walk-forward-testing)
13. [Robustness and curve-fitting](#13-robustness-and-curve-fitting)
14. [Comparing BUY vs SELL and sessions](#14-comparing-buy-vs-sell-and-sessions)
15. [When is a configuration promising?](#15-when-is-a-configuration-promising)
16. [Reports, CSV and the analyzer](#16-reports-csv-and-the-analyzer)
17. [Example backtest interpretation (invented numbers)](#17-example-backtest-interpretation-invented-numbers)
18. [Recommended demo testing procedure](#18-recommended-demo-testing-procedure)
19. [All parameters](#19-all-parameters)
20. [Known limitations](#20-known-limitations)

---

## 1. Project structure

```
Gold-Bot/
├── README.md                              ← this file (V3)
├── MQL5/Experts/GoldBot/
│   ├── GoldBotV3.mq5                      ← V3 EA (use this)
│   ├── GoldBotV2.mq5                      ← V2 (kept for comparison)
│   └── GoldBot.mq5                        ← V1 (kept for comparison)
├── tools/
│   └── analyze_trades.py                  ← offline analyzer (Python 3, standard library only)
└── docs/
    ├── TEST_REPORT_TEMPLATE.md            ← fill one per test
    ├── README_V2.md                       ← V2 documentation
    └── README_V1.md                       ← V1 documentation
```

The default magic numbers are 55200125 (V1), 55200226 (V2) and 55200327 (V3), so statistics never mix. All versions allow only **one gold position at a time** on the account.

---

## 2. What changed from V2

| Area | V2 | V3 |
|------|----|----|
| Rule testing | Most rules fixed | **Each rule can be switched on or off by itself** (section 4) |
| Trend filter | EMA 55/200, always on | Mode: **EMA55+200** (default) / **EMA200 only** / **OFF** (test only) |
| Zone | Multi-reaction scored | Optional **"require multi-reaction zone"** |
| Confirmation | All three patterns | Mode: **all** / **rejection + engulfing** / **rejection only** |
| ATR | Min/max pips | Same (0 = off), plus a **relative ATR regime** (LOW/NORMAL/HIGH vs the 24 h average) that is logged, analyzed and can optionally be filtered |
| Chasing filter | Always on | 0 = off, so its effect can be tested |
| Trailing | ATR only | Mode: **off / ATR / fixed pips** |
| Sessions | London / NY / both / custom | Plus **All day** (test only), and the dashboard shows LONDON / NEW YORK / OVERLAP / CLOSED |
| Costs | Not modelled | Commission assumption **used in lot sizing**, estimated commission and slippage in **cost-adjusted statistics**, and actual spread, commission and swap recorded |
| Break-even trades | Could count as losses | **±0.10R band**: tiny results count as break-even (they don't trigger the cooldown or the loss streak) |
| Account protection | None | **Equity drawdown halt** (default 10%) and an **emergency switch** |
| Duplicate protection | New-bar gate + position check | Plus the **last traded signal candle**, stored across restarts |
| Metadata per trade | Spread only | Score, ATR and regime, confirmation, trend class, zone type, distance from zone, ask/bid, SL/TP, estimated commission, break-even and trailing use |
| Statistics | Overall, BUY/SELL, session | Plus **year, month, hour, weekday, ATR regime, score range, confirmation, trend class, zone type**, break-even trades, total R, expectancy, recovery factor, longest drawdown, monthly consistency, and **sample-size labels** |
| Output | Log + CSV | Log + **report file** + **41-column trade CSV** + **offline analyzer** + optimizer criterion |
| Logging | Checklist | Checklist, plus a full sizing breakdown, the config line, and entry context on every closed trade |

**Retained, modified or removed V2 rules:** no V2 rule was removed, because removing a rule needs test evidence and none exists yet. Every rule was **retained**. Several were **made switchable** (trend mode, confirmation mode, chasing filter, ATR limits, daily limits, cooldown, sessions) so each one can be tested. Two behaviours were **modified** for correctness, not performance: the break-even band and cost-aware sizing. **V2 defaults are unchanged**, again because there is no evidence to justify different ones.

---

## 3. Exact V3 trading rules

Evaluation happens **once per closed M15 candle**, on the first tick of the next candle. The candle is marked as processed first, and the signal candle of the last trade is stored across restarts, so no candle can be traded twice.

**Step 1: trend (H1, last closed candle)**
* **EMA55+200 mode (default):**
  * BUY environment: H1 close > EMA 200 **and** EMA 55 > EMA 200.
  * SELL environment: the mirror image.
  * Otherwise: WAIT.
  * The trend is graded *strong* if the H1 close is also beyond EMA 55, otherwise *pullback*.
* **EMA200-only mode (test):** direction comes from the H1 close vs EMA 200 alone.
* **OFF (test):** there's no trend filter. Direction comes from which zone was reached (support → BUY, resistance → SELL; both → WAIT). The trend score is 0, and each trade is still classified as trend-aligned or not.
* `AllowBuy` / `AllowSell` can block a direction.

**Step 2: zone (M15)**
* **Swings:** swing lows (BUY) or swing highs (SELL) with `Swing strength` candles on each side, within `Swing lookback` candles.
* **Discarded swings:** swings that a later candle **closed** through, and swings that aren't formed before the last two candles.
* **Merging:** swings within `Zone merge` pips become one zone. Each merged swing is one *reaction*.
* **Zone used:** the nearest zone below the last close (BUY) or above it (SELL).
* **Reached:** the last two candles came within `Zone distance` of the zone, without piercing more than `Zone distance` beyond its far edge.
* If no zone was reached, the EA logs `WAIT:` and stops. Otherwise it continues to the full checklist.

**Step 3: checklist**

Every check is evaluated, even after one fails, and each one is logged with `[OK]`, `[X]` or `[--]`:

| Check | Rule | Can be switched off for testing |
|-------|------|---------------------------------|
| Zone reactions | if `Require multi-reaction zone`: 2+ reactions | yes (default off) |
| Candle | closes in the trade direction, range ≥ 50% ATR, **and** is an accepted pattern: rejection (wick ≥ 50% of range into the zone, opposite wick ≤ 30%), engulfing, or strong candle (body ≥ 60%, closes in the outer 25%), as allowed by `Confirmation mode` | pattern set only |
| EMA 9 | BUY: close > M15 EMA 9; SELL: close < EMA 9 | `Require EMA confirm` = false makes it score-only |
| ATR | `Min ATR` ≤ ATR ≤ `Max ATR`, and the regime is allowed by `ATR regime filter` | 0 = off; filter "all" |
| Entry distance | entry within `Max distance from zone` of the zone | 0 = off |
| Stop loss | computed SL ≤ `Max SL`, and outside the broker's stop level | no (risk control) |
| Spread | ≤ `Max spread` (checked again right before sending) | no (risk control) |
| Session | inside the selected session and not in the news blackout | session "All day" (test) |
| Score | ≥ `Min score` | 0 = off |
| Risk | daily trading not stopped, and not in cooldown | limits 0 = off (test only) |
| Account | emergency switch on, and no equity drawdown halt | no |
| Position | no gold position open, and this signal candle not traded before | no |

If **everything** passes, the EA checks terminal/account permissions, sizes the lot (section 7), checks margin, and sends **one** market order with SL and TP attached.

---

## 4. Rule review: purpose, status and test plan

**Status of every rule: RETAINED, UNTESTED.** The table says what each rule is *for*, how to test its contribution by switching only that rule, and what would justify keeping, changing or removing it. Put the results in your test reports (`docs/TEST_REPORT_TEMPLATE.md`). Where the per-trade CSV already contains the needed classification, you can analyze the rule **without an extra run**.

Keep the other settings at baseline for each test, and compare on the **in-sample period only** (section 12).

| Rule | Type | Purpose | How to test its contribution |
|------|------|---------|------------------------------|
| H1 trend filter | edge | Trade only with the higher-timeframe direction | `Trend filter` = OFF vs default. The CSV `trend` column also shows "not trend-aligned" trades in OFF mode. |
| EMA 55/200 alignment | edge | Avoid weak trends where EMA 55 hasn't crossed | `Trend filter` = EMA200 only vs default |
| Trend strength (strong/pullback) | score | Grade trend quality | Analyzer `--groups trend` |
| M15 support/resistance | edge (core) | Enter where price reacted before | Can't be switched off: it defines the strategy. Tune `Zone distance` in broad steps (10/20/30). |
| Multi-reaction zone | edge | Prefer levels that held more than once | Analyzer `--groups zone`, then `Require multi-reaction zone` = true |
| Rejection candle | edge | Evidence of a reaction | Analyzer `--groups confirmation` |
| Engulfing candle | edge | Same | `Confirmation mode` = rejection only vs rejection + engulfing |
| Strong candle | edge | Same | `Confirmation mode` = rejection + engulfing vs all |
| EMA 9 confirmation | timing | Enter after short-term momentum turns | `Require EMA confirm` = false (score-only) vs true |
| ATR minimum | risk / edge | Skip dead markets (bad R:R after costs) | `Min ATR` = 0 vs default. Also analyzer `--groups atr_regime`. |
| ATR maximum | risk | Skip chaotic markets (slippage, gaps) | `Max ATR` = 0 vs default |
| ATR regime filter | edge | Test whether relative volatility matters | Analyzer `atr_regime` first. Filter only if one regime is clearly negative in several periods. |
| Session filter | edge / cost | Trade when liquidity and spreads are good | `Session` = All day, then read the analyzer `session` and `hour` groups |
| Spread filter | cost | Avoid expensive entries | Risk control, keep it. Check the analyzer cost-sensitivity table. |
| Minimum score | edge | Filter weak combinations | `Min score` = 0 / 60 / 70 / 80, plus analyzer `score_range` |
| Max distance from zone | edge | Avoid chasing exploded candles | 0 (off) vs 30. Does it remove winners or losers? |
| Break-even | management | Cut losses on reversals after +1R | Off vs on. Compare avg R, drawdown and exit types. |
| Trailing stop | management | Protect large winners | Off (default) vs ATR vs fixed |
| Cooldown after loss | risk | Avoid revenge-like clustering | 0 vs 30 min. Does it change avg R, or only the trade count? |
| Daily loss limit | risk | Cap a bad day | Keep it for risk control. Its effect on expectancy is usually small. |
| Daily profit boundary | risk | Stop after an unusually good day | 0 vs 3%. Keep it only if it doesn't lower avg R. |
| Max consecutive losses | risk | Stop on a bad day | Risk control, keep it |
| Max trades per day | risk | Prevent overtrading | Risk control, keep it. Check how often it's hit (log). |

How to decide:
* **Keep** an *edge* rule if switching it off lowers the cost-adjusted average R **in most periods**, not just one.
* **Remove or make optional** an edge rule if switching it off doesn't lower avg R and adds trades. That's evidence the rule does nothing.
* **Risk-control** rules (spread, max SL, daily limits, one position, account halt) are kept even if they cost a little expectancy. Their job is to limit damage.
* If a rule helps in one year and hurts in others, treat it as **noise**, not an edge.

---

## 5. Quality score

The score grades the quality of rules that already passed. The default minimum is 70 (0 = off).

| Component | Points |
|-----------|--------|
| Trend strong / pullback / OFF mode | 30 / 15 / 0 |
| Zone with 2+ reactions / single swing | 25 / 10 |
| Rejection or engulfing / strong candle | 20 / 10 |
| EMA 9 confirmed | 15 |
| ATR accepted | 10 |

With the defaults, only "pullback + single swing + strong candle" (60) is rejected. Test the score with `Min score` = 0, 60, 70, 80, and read the analyzer's `score_range` breakdown.

**A higher score is not automatically better.** If 90–100 shows the best numbers from 40 trades, that's a small sample. Check whether the ranking of the ranges is **monotonic and repeats across periods** before trusting it.

---

## 6. Stop loss, take profit and trade management

* **Base SL:** `Fixed pips` or `ATR × multiplier` (default ATR × 1.0).
* **Structure SL** (default on): moved beyond `min(zone bottom, last 2 lows) − buffer` for a BUY (mirror image for a SELL) when that is further.
* **Max SL:** if the final SL is above `Max SL` (80 pips), then **NO TRADE**. The SL is never enlarged to keep a setup alive.
* **TP** = SL distance × `Risk reward` (default 4). Test **2, 3, 4, 5**, and choose by cost-adjusted avg R, drawdown and neighbour stability, **not** by the highest return.
* **Break-even** (default on): at +`BreakEvenAtR` (1.0R), the SL moves to entry ± `buffer` (2 pips), once.
* **Trailing** (default **off**): ATR × `multiplier` or fixed pips. It starts at `Trail start R` (2R), only moves in the trade's favour, and only in steps of at least 10% of the initial risk.
* TP is never changed. The SL never moves backwards.

---

## 7. Risk, daily and account protection

**Position sizing (risk mode)**
```
base        = min(balance, equity)
risk budget = base × RiskPercent / 100
loss/lot    = money lost by 1.00 lot from entry to SL (OrderCalcProfit: uses the broker's
              tick size, tick value and contract size, correct for any digits)
              + CommissionPerLot (your round-turn commission assumption)
raw lots    = risk budget / loss per lot
lots        = rounded DOWN on the broker grid (min lot + n × step), capped at min(broker max, Max lot)
```
* If `raw lots < min lot`, the trade is **rejected**, with a log line showing how much the minimum lot *would* have risked. The EA never rounds up to the minimum lot.
* Every trade logs: balance, equity, base, risk %, risk amount, SL pips, loss per lot, commission, raw lot, final lot, and estimated money risk (%).
* Margin must be ≤ 90% of free margin.

**Daily limits** (reset at 00:00 server time, latched until the next day, rebuilt from history after a restart). The defaults are shown; **0 = off, for testing only**.

| Limit | Default |
|-------|---------|
| Max daily loss (realized + floating) | 2% of the day-start balance |
| Daily profit boundary | 3%. This isn't a target; nothing is forced to reach it. |
| Max consecutive losses (today) | 3 |
| Max trades per day | 3 |
| Cooldown after a losing trade | 30 min. Afterwards a completely new valid setup is still required. |

**Account protection**
* **Emergency switch** (`Trading enabled` = false): no new trades. Open trades keep their SL/TP and management.
* **Equity drawdown halt** (default 10%, 0 = off): the EA tracks the highest equity it has seen. If equity falls ≥ 10% below that peak, **new trades stop until you reset**. The halt and peak are stored in terminal global variables (live/demo) and survive restarts. To resume, set `Reset account protection` = true once, then set it back to false. In the Strategy Tester every run starts clean.

**Always on:**
* Maximum 1 open gold position (counting any magic number).
* One evaluation per M15 candle.
* The last traded signal candle is never traded again.
* Orders are sent synchronously.
* At most one retry, and only for requote or price-change errors.
* No lot increase after losses, no martingale, grid or averaging down, and no recovery trades.

---

## 8. Trading costs: how they are included

| Cost | How V3 handles it |
|------|-------------------|
| **Spread** | Filtered before entry and re-checked right before sending. Recorded at entry together with the ask and bid. Already inside every fill price, so it's in `net`. |
| **Commission** | The actual commission charged is recorded per trade and included in `net`. `CommissionPerLot` (your assumption) is added to the risk per lot in **sizing**. In statistics, it's applied as an **estimated** cost only to trades that were charged **no** commission, for example in a tester without commission. |
| **Swap** | Recorded per trade and included in `net`. |
| **Slippage** | Real slippage is inside the fill prices. `SlippageAssumptionPips` subtracts an extra assumed slippage per trade in the **"after estimated costs"** figures. |
| **Stress test** | The analyzer's **cost-sensitivity table** subtracts +0.5 / +1 / +2 / +3 pips per trade (as R: pips ÷ SL pips) to show how fast the edge disappears. |
| **Broker specifications** | Tick size, tick value, contract size, digits, stop level and freeze level come from the broker's symbol. They're printed at start-up. |

The statistics always show **both**: *actual* (what was charged) and *est* (after estimated extra costs). Judge a configuration on the **est** figures.

**Why backtests and live results differ:**
* Spread widens at news, rollover and low liquidity.
* Slippage and execution delay vary.
* Liquidity is thin at some hours.
* Each broker's price feed differs.
* Commission and swap change.
* News volatility can jump price straight through stops.

Small edges, such as +0.05R per trade, can disappear entirely under these differences.

---

## 9. Performance metrics explained

| Metric | Definition | How to read it |
|--------|-----------|----------------|
| **Net profit after costs** | Sum of all trade results after costs | Must be positive, but it depends on risk size. Compare configurations with R metrics. |
| **Expectancy per trade** | Net profit ÷ number of trades | The average money result per trade |
| **Average R per trade** | Total R ÷ trades, where R = result ÷ money at risk at the initial SL | Expectancy independent of account size. +0.10R means +0.10 × risk per trade on average. This is the **main metric**. |
| **Total R** | Sum of R over all trades | +40R at 0.25% risk ≈ +10% of the account |
| **Profit factor** | Gross profit ÷ gross loss | 1.0 = break-even. 1.1 is fragile after costs. Above 1.3 over 100+ trades is worth studying further, and is still not proof. |
| **Win rate** | Wins ÷ trades (break-even band excluded from wins) | Meaningless alone |
| **Average win / average loss** | In money and in R | With a 4R target, the average win is ≈ +4R and the average loss ≈ −1R, plus costs |
| **Max drawdown** | Largest peak-to-trough fall of the closed-trade curve (money, %, R) | Could you sit through it? Compare with the net profit. |
| **Recovery factor** | Net profit ÷ max drawdown | Return relative to pain. Below ~2 is weak. |
| **Max consecutive losses** | Longest losing streak | At 0.25% risk, a 12-loss streak ≈ −3% |
| **Longest drawdown period** | Longest time between a closed-trade equity peak and its recovery | Long flat periods are hard to trade psychologically |
| **Monthly / yearly consistency** | Share of positive months and years, and the longest run of non-positive months | Profit concentrated in one month or year suggests luck |
| **Trades per weekday** | Trades ÷ weekdays in the period | Low frequency is fine by design |

**Why a high win rate doesn't guarantee profit:** a 70% win rate with +0.3R wins and −1R losses has expectancy 0.7 × 0.3 − 0.3 × 1 = **−0.09R**. That's a loss.

**Why a high R:R doesn't guarantee profit:** with 4R targets you need more than 20% wins before costs to break even. At 18% wins the expectancy is 0.18 × 4 − 0.82 × 1 = **−0.10R**.

**Break-even rate for R:R *k*:** 1 ÷ (1 + *k*): 33% for 2R, 25% for 3R, 20% for 4R, 17% for 5R, before costs. Costs push these higher.

**Why sample size matters:** with 30 trades at a 25% win rate, one or two lucky wins change the profit factor enormously. The EA and the analyzer label groups as **VERY WEAK (<30)**, **PRELIMINARY (<50)** or **LIMITED (<100)**. These are guidance thresholds, not guarantees. A PF of 2.5 from 25 trades is **not** reliable evidence.

---

## 10. Installation

1. MT5: **File → Open Data Folder**. Copy `MQL5/Experts/GoldBot/GoldBotV3.mq5` to `<Data Folder>/MQL5/Experts/GoldBot/`.
2. Open **MetaEditor** (F4), open the file and press **F7**. You should see **0 errors**. (The file hasn't been compiled in this repository; report any errors or warnings.)
3. In MT5's Navigator, right-click **Expert Advisors** and choose **Refresh**.
4. On a **demo** account, open a gold chart (M15 recommended) and drag **GoldBotV3** onto it. Tick **Allow Algo Trading**, set the inputs, and click OK. The toolbar **Algo Trading** button must be green.
5. Check the start-up log:
   * `1 pip = 0.10 price = N points`
   * tick size and tick value
   * `Value of 1 pip` per lot
   * the `Config:` line
   * the daily and account protection settings.
6. **Server time:** the session defaults (London 10:00–19:00, New York 15:00–22:00) assume a GMT+2/+3 server. Check the Market Watch clock and adjust if yours differs.
7. Analyzer (optional): install Python 3.8+. There's nothing else to install. Run `python3 tools/analyze_trades.py --help`.

---

## 11. Backtesting

**Tester settings:**
* **Expert:** `GoldBot\GoldBotV3`
* **Symbol:** your gold symbol
* **Timeframe:** M15
* **Modelling: "Every tick based on real ticks"**, which gives variable spread from real tick data. Don't use "Open prices only".
* **Deposit and leverage:** the same as your demo account
* **Commission:** the MT5 tester uses the broker's commission settings where available. If yours shows none, set `Commission per lot` so it's included in sizing and in the *est* statistics.
* **Spread stress:** run the same test again with a **fixed, higher spread** (tester "Current" or a custom value), and/or read the analyzer's cost-sensitivity table.
* **Optimization: Disabled** by default (see below).
* **`Report tag`:** give every run a descriptive tag, for example `IS_2022-2024_base`, `IS_2022-2024_RR3`, `VAL_2025_base`. The files are then named after it.

**After each run:**
* The Journal ends with the V3 statistics report.
* `GoldBotV3_<tag>_report.txt` and `GoldBotV3_<tag>_trades.csv` are written to **Common Data Folder → Files** (`File → Open Data Folder`, go up one level, then `Common/Files`).
* Run `python3 tools/analyze_trades.py <csv>`.
* Fill in `docs/TEST_REPORT_TEMPLATE.md`.

**What to test (one change at a time, broad values only):**

| Question | Values |
|----------|--------|
| Rule contribution | Section 4 switches |
| SL mode | Fixed vs ATR |
| ATR SL multiplier | 1.0 / 1.5 / 2.0 |
| Risk:reward | 2 / 3 / 4 / 5 |
| Min score | 0 / 60 / 70 / 80 |
| ATR min / max | off / default / wider |
| Sessions | London / New York / London+NY / All day |
| Direction | BUY only / SELL only / both |
| Break-even | on / off |
| Trailing | off / ATR / fixed |
| Cost stress | analyzer +1 / +2 pips, higher fixed tester spread |

**Using the optimizer (optional, carefully):**
* If you use it, **only** for a small grid of broad values on the **in-sample** period. For example, RR ∈ {2,3,4,5} × SL multiplier ∈ {1.0,1.5,2.0} is 12 runs.
* Select **"Custom max"**: `OnTester()` returns the **cost-adjusted average R**, and returns **0 for fewer than 30 trades**.
* Look at the whole table, not the top row. You're looking for a *region* of similar results, not a peak.
* Never optimize dozens of inputs at once, and never optimize on the validation or out-of-sample periods.

---

## 12. In-sample, validation, out-of-sample and walk-forward testing

| Period | Example dates | Rule |
|--------|---------------|------|
| **In-sample (development)** | 2022-01-01 → 2024-12-31 | All comparisons, rule tests and choices happen here |
| **Validation** | 2025-01-01 → 2025-12-31 | Run the chosen configuration **once**. If it fails, go back to in-sample thinking. Don't tune on validation. |
| **Out-of-sample (final)** | 2026-01-01 → today | Untouched until the very end. Run **once** with frozen settings. |
| **Demo forward test** | from now | Truly unseen data under live conditions |

The dates are examples; **fix your split before you start testing** and write it in the report.

**Rules:**
* **Don't optimize and evaluate on the same data.** In-sample results are always optimistic, because every choice you make fits the noise a little.
* **Don't pick the best configuration from the entire history and call it out-of-sample.** Once you've looked at a period's results to choose settings, that period is in-sample.
* **Don't repeatedly adjust rules against the validation period.** After two or three rounds, validation has become in-sample. Keep a **final untouched period**.
* **Re-evaluate when new data arrives:** every few months, the newest data is a fresh out-of-sample test for frozen settings.

**Walk-forward testing** repeats that idea in rolling windows. For example:

| Step | Develop / choose on | Then test once on |
|------|---------------------|-------------------|
| 1 | 2021–2022 | 2023 |
| 2 | 2022–2023 | 2024 |
| 3 | 2023–2024 | 2025 |

1. In each develop window, choose the configuration with the section 11 process: small grid, broad values, a stable region.
2. Test it once on the next year, and record that year's result.
3. Combine only the test-year results. That combined curve is the walk-forward result, and it's much closer to what you'd have experienced live.
4. If the chosen settings change a lot from window to window, or the test years are mostly negative, there's no stable edge.

With the analyzer, `--split YYYY-MM-DD` prints in-sample and out-of-sample side by side from one CSV. Remember that a single tester run over both periods is only valid if the settings were chosen **before** looking at the later period.

---

## 13. Robustness and curve-fitting

Test robustness across:
* **multiple years** (trending up, trending down, ranging)
* **different spreads** (real ticks, then a fixed higher spread)
* **commission and slippage assumptions** (the analyzer cost table and the `CommissionPerLot` / `SlippageAssumptionPips` inputs)
* **different brokers** (tick data and specifications differ), and different gold symbols where relevant
* **nearby parameter values.**

**Sensitivity rule:** if you use `Min score = 70`, also test 60 and 80. Likewise RR 3 → 2 and 4, ATR multiplier 1.5 → 1.0 and 2.0, zone distance 20 → 10 and 30. The results should change **gradually**.

**Signs of curve-fitting:**
* Performance collapses when one parameter moves one step.
* The "best" values are oddly precise (17.3 pips, 1.17 ATR, 73 points, a 42-minute cooldown).
* Most of the profit comes from one month, one year, or a few trades.
* The in-sample result is excellent but validation or out-of-sample is flat or negative.
* A filter improves results by removing very few trades that happened to be losers.
* BUY-only looks great, but only during a strong bull market.
* The rule set keeps growing each time a test disappoints.

---

## 14. Comparing BUY vs SELL and sessions

**BUY vs SELL**
* The report and the analyzer show, per direction:
  * trades, win rate, profit factor, expectancy and net
  * the **drawdown of that direction's own trades**.
* Compare **average R after costs**, and do it **per year**. Gold rose strongly in several recent years, so BUY-only may look better only because of that trend.
* Disable a direction (`AllowBuy` / `AllowSell`) **only** if it's negative after costs across several periods and market conditions, with enough trades (100+). One period isn't evidence.
* Confirm with a separate run (BUY only, then SELL only). The two directions can interact through daily limits and the one-position rule.

**Sessions and hours**
1. Run once with `Session = All day` (test) so that nothing is pre-filtered.
2. Read the analyzer's `--groups session hour`. Hours are server time.
3. Look for **broad** blocks that are consistently negative after costs in several years, such as late New York or the Asian hours. Ignore single hours with 15 trades.
4. Restrict the session only to such blocks, then confirm on validation data. Don't build a patchwork of individual "good hours". That's curve-fitting.

---

## 15. When is a configuration promising?

Consider a configuration **promising** (still not proven) only if **all** of these hold, across multiple periods, **after estimated costs**:

| Criterion | Guidance (the analyzer's default thresholds) |
|-----------|----------------------------------------------|
| Enough trades | ≥ 100 in-sample, ≥ 30 in each later period |
| Positive net profit and expectancy | net > 0, avg R ≥ +0.05R |
| Acceptable profit factor | ≥ 1.2 |
| Controlled drawdown | a max drawdown you can tolerate; recovery factor ≥ 2 |
| No dependence on one trade | largest win < 25% of net |
| No dependence on one month or year | still positive without the best month and without the best year; at least half the years positive |
| Out-of-sample | average R > 0 on untouched data |
| Parameter stability | nearby values are also positive (analyzer `--compare`) |
| Cost robustness | still positive with +1 pip extra cost per trade |
| No curve-fitting signs | section 13 |

The analyzer prints these as PASS / FAIL / INSUFFICIENT with the thresholds shown, and gives one verdict: **PROMISING**, **NOT PROMISING** or **INSUFFICIENT DATA**. "Promising" means *worth a demo forward test*. It never means "profitable".

**If results are negative or unstable, say so.** Record which conditions caused the failure (years, sessions, direction, regime, costs) in the test report. "No edge found" is a valid and useful result.

---

## 16. Reports, CSV and the analyzer

**In the Experts log / Journal**
* `WAIT:` on every candle without a potential trade (verbose)
* the full `SETUP CHECK` / `SETUP REJECTED` checklist, with every rule, the score components and all rejection reasons
* `TRADE OPENED` with the entry, ask/bid, SL, TP, lots, spread, estimated commission, ATR and regime, score, session, confirmation, the sizing breakdown and the config line
* `MANAGE:` break-even and trailing moves
* `TRADE CLOSED` with net, gross, commission, swap, net after estimated costs, R and estimated R, outcome, holding time and entry context
* daily and account stops, and order errors.

**Report file** `GoldBotV3_<tag>_report.txt`:
* It's the same report as the Journal.
* It's written when the EA stops and, on live/demo, once per new server day.
* Sections: summary, direction, session, year, ATR regime, score range, confirmation, trend class, zone type, weekday, hour and month, each with a sample-size label.

**Trade CSV** `GoldBotV3_<tag>_trades.csv` has 41 columns:
* position, direction, times, year, month, weekday, hour, session
* prices, initial SL, volume, SL/TP pips, risk money
* spread, ask, bid, ATR and regime, score and range, confirmation, trend class, zone type, distance from zone
* SL mode, R:R, break-even and trailing moved, estimated commission
* gross, commission, swap, net, net after estimated costs, R and estimated R
* outcome and exit type.

**Restarts:** live and demo metadata is stored in `GoldBotV3_meta_<login>_<symbol>_<magic>.csv` (Common Files), so statistics stay complete after a restart. Tester runs keep metadata in memory.

**Analyzer examples**
```bash
python3 tools/analyze_trades.py GoldBotV3_IS_base_trades.csv
python3 tools/analyze_trades.py all_years.csv --split 2025-01-01          # in-sample vs out-of-sample
python3 tools/analyze_trades.py rr2.csv rr3.csv rr4.csv rr5.csv --compare  # neighbour stability
python3 tools/analyze_trades.py run.csv --groups direction session year hour
python3 tools/analyze_trades.py run.csv --costs actual                     # use charged costs only
python3 tools/analyze_trades.py run.csv --min-pf 1.3 --min-avg-r 0.1       # stricter thresholds
```

The analyzer only reads your CSV and does arithmetic. Every formula is in the script, and every threshold is printed.

**Reporting template:** `docs/TEST_REPORT_TEMPLATE.md` has every field required for a test report: environment, periods, configuration, results per period, breakdowns, robustness, notes.

---

## 17. Example backtest interpretation (invented numbers)

> **These numbers are invented for illustration. They are not GoldBot results.**

```
In-sample 2022-2024, after estimated costs:  212 trades | win 27.4% | BE 21 | avg R +0.11 | PF 1.19
                                             max DD 14.2R | RF 1.9 | max consecutive losses 12
By direction:  BUY 150 trades avg R +0.19 | SELL 62 trades avg R -0.08 [PRELIMINARY]
By session:    overlap +0.24R (88) | London only +0.02R (71) | New York only +0.01R (53)
By score:      70-79 +0.03R (118) | 80-89 +0.19R (61) | 90-100 +0.31R (33)
Cost table:    +0 pips +0.11R | +1 pip +0.08R | +2 pips +0.05R | +3 pips +0.02R
Analyzer:      FAIL profit factor (1.19 < 1.2), FAIL recovery factor (1.9 < 2.0) -> NOT PROMISING
```

How to read it:
* **+0.11R per trade** is a thin edge, and **+2 pips of extra cost removes half of it**. Real spreads and slippage could erase it.
* **PF 1.19 and RF 1.9 fail the checklist.** That's the honest verdict, even though net profit is positive.
* **BUY positive, SELL negative with only 62 trades.** Gold rose strongly in the period. Check SELL per year before concluding anything. Disabling SELL now would be a decision based on one market regime.
* **Scores increase monotonically** (70-79 < 80-89 < 90-100). That's a *hypothesis* worth testing: min score 80 on the **same in-sample** period, and its neighbours 70 and 90. Only then should it be confirmed once on validation.
* **Overlap best.** It's plausible (liquidity), but the other sessions are near zero, not clearly negative. Test "London+NY" vs overlap-only on validation before restricting.
* **Next step:** change **one** thing (for example min score 80), re-run in-sample, compare with neighbours, and run validation **once**. If validation fails, record it and don't keep tuning.

---

## 18. Recommended demo testing procedure

1. **Freeze** the configuration that passed in-sample and validation. Save the `.set` file and note the git commit.
2. Run GoldBotV3 on a **demo** account, on a VPS or an always-on PC, for at least **8–12 weeks**, and ideally 50+ trades. Use the same `Commission per lot` as your intended account.
3. **Daily:** read the log. Does each `TRADE OPENED` checklist match the chart? Note any surprises.
4. **Weekly:**
   * run the analyzer on the demo trade CSV (the report files refresh every server day)
   * compare avg R, win rate, average spread, trade frequency and exit types with the backtest of the **same weeks**
   * large differences usually come from spread, slippage or server time; investigate before touching strategy settings.
5. **Don't change settings during the forward test.** If you must, the forward test restarts.
6. **Decide** with the section 15 checklist. The demo verdict counts as out-of-sample evidence. With fewer than 30 demo trades, the verdict is "insufficient".

**Demo checklist**
- [ ] Compiles with 0 errors; start-up log shows the correct symbol, pip conversion, tick value and config
- [ ] One decision per M15 candle; never two trades from the same signal candle
- [ ] Never more than one gold position
- [ ] Every rejection lists its reason(s); every trade logs sizing, costs, score, session and confirmation
- [ ] The lot risk matches the configured % (see `Sizing:`); a trade is rejected when the minimum lot would exceed the risk
- [ ] Break-even and trailing move the SL only forward, and are logged
- [ ] Daily limits, cooldown, the emergency switch and the equity halt block new trades as described
- [ ] Counters and statistics survive a terminal restart
- [ ] The report and CSV are written to Common Files; the analyzer runs on the CSV

---

## 19. All parameters

"Test" means: allowed for rule testing, not intended for real accounts.

| Group | Input | Default | Explanation |
|-------|-------|---------|-------------|
| Symbol | `InpSymbol` | *(empty)* | Symbol. Empty means the chart symbol, or auto-detect `XAUUSD*` / `GOLD*` |
| Symbol | `InpPipSize` | 0 | Price value of 1 pip. 0 means auto (0.10 for gold) |
| Master | `InpTradingEnabled` | true | Emergency switch. false means no new trades; open trades are still managed |
| Direction | `InpAllowBuy` / `InpAllowSell` | true / true | Allow each direction |
| Trend | `InpTrendMode` | EMA55+EMA200 | EMA55+200 / EMA200 only (test) / OFF (test) |
| Trend | `InpTrendFastEMA` / `InpTrendSlowEMA` | 55 / 200 | H1 trend EMAs. Don't optimize. |
| Zones | `InpSwingStrength` | 3 | Candles on each side of a swing |
| Zones | `InpSwingLookbackBars` | 150 | M15 candles searched for swings |
| Zones | `InpZoneMergePips` | 15 | Swings within this distance form one zone |
| Zones | `InpZoneDistancePips` | 20 | How close price must come to the zone (and the break tolerance). Test 10 / 20 / 30. |
| Zones | `InpRequireMultiTouchZone` | false | Require 2+ reactions |
| Zones | `InpMaxDistanceFromZonePips` | 30 | Don't chase. 0 = off. |
| Confirmation | `InpConfirmMode` | all | all / rejection + engulfing / rejection only |
| Confirmation | `InpEntryEMA` | 9 | M15 timing EMA. Don't optimize. |
| Confirmation | `InpRequireEMAConfirm` | true | false = score only |
| Volatility | `InpATRPeriod` | 14 | M15 ATR period. Don't optimize. |
| Volatility | `InpMinATRPips` / `InpMaxATRPips` | 15 / 120 | ATR limits in pips. 0 = off. |
| Volatility | `InpATRRegimeFilter` | all | all / not LOW / not HIGH / NORMAL only (regime = ATR vs 24 h average: < 0.8 LOW, > 1.25 HIGH) |
| Score | `InpMinScore` | 70 | Minimum score. 0 = off. Test 0 / 60 / 70 / 80. |
| SL/TP | `InpSLMode` | ATR | Fixed pips / ATR × multiplier |
| SL/TP | `InpFixedSLPips` | 25 | Fixed-mode SL |
| SL/TP | `InpATRSLMultiplier` | 1.0 | ATR-mode SL. Test 1.0 / 1.5 / 2.0. |
| SL/TP | `InpUseStructureSL` | true | Push the SL beyond the zone and the reaction candles when that's further |
| SL/TP | `InpSLBufferPips` | 5 | Buffer beyond the zone |
| SL/TP | `InpMaxStopLossPips` | 80 | Larger required SL means no trade |
| SL/TP | `InpRiskReward` | 4.0 | TP in R. Test 2 / 3 / 4 / 5. |
| Management | `InpBreakEvenEnabled` / `InpBreakEvenAtR` / `InpBreakEvenBufferPips` | true / 1.0 / 2 | Break-even |
| Management | `InpTrailMode` | off | off / ATR / fixed |
| Management | `InpTrailStartR` / `InpTrailATRMultiplier` / `InpTrailFixedPips` | 2.0 / 2.0 / 50 | Trailing settings |
| Size | `InpLotMode` | risk | Risk % / fixed lot |
| Size | `InpRiskPercent` | 0.25 | % of min(balance, equity) per trade (max 5). Don't optimize: it scales results, not the edge. |
| Size | `InpFixedLotSize` / `InpMaxLotSize` | 0.01 / 1.00 | Fixed lot / hard lot cap |
| Costs | `InpCommissionPerLot` | 0 | Your round-turn commission per 1.00 lot. Used in sizing, and in the *est* statistics when no commission was charged. |
| Costs | `InpSlippageAssumptionPips` | 1.0 | Extra slippage per trade in the *est* statistics |
| Daily | `InpMaxDailyLossPercent` | 2.0 | 0 = off (test) |
| Daily | `InpMaxDailyProfitPercent` | 3.0 | 0 = off |
| Daily | `InpMaxConsecutiveLosses` | 3 | 0 = off (test) |
| Daily | `InpMaxTradesPerDay` | 3 | 0 = off (test) |
| Daily | `InpCooldownAfterLossMinutes` | 30 | 0 = off. Test 0 vs 30 only. |
| Account | `InpMaxAccountDrawdownPercent` | 10 | Equity drawdown halt. 0 = off. |
| Account | `InpResetAccountProtection` | false | Set true once to clear a stored halt or peak |
| Execution | `InpMaxSpreadPips` | 5 | Max spread |
| Execution | `InpMaxSlippagePips` | 3 | Max accepted deviation on entry |
| Execution | `InpMagicNumber` | 55200327 | Identifies V3 trades |
| Sessions | `InpSessionMode` | London + New York | London / New York / London+NY / Custom / All day (test) |
| Sessions | `InpLondonSession` / `InpNewYorkSession` / `InpCustomSession` | 10:00-19:00 / 15:00-22:00 / 09:00-21:00 | Server time, `HH:MM-HH:MM`. Also used for statistics. |
| News | `InpNewsFilterEnabled` / `InpNewsStartTime` / `InpNewsEndTime` | false / 15:25 / 16:00 | Manual daily blackout (server time) |
| Reporting | `InpShowDashboard` / `InpVerboseLog` | true / true | Dashboard / WAIT lines |
| Reporting | `InpWriteReports` / `InpReportTag` | true / "" | Report and CSV files, and the file-name tag |

**Don't over-optimize:**
* EMA periods, ATR period, swing strength and lookback, candle-shape constants, score weights, risk %, and precise session minutes.
* Test only broad values: RR, SL multiplier, min score, zone distance, and broad session blocks.

---

## 20. Known limitations

* **No backtest evidence exists yet** (see the top of this file). All rule assessments are pending your tests.
* **Not compiled in this repository**, because there's no MetaEditor here. Compile it, and report errors or warnings.
* **The news filter is manual**: one daily window, no calendar.
* **Zones use swing points only.** The EA tests only the nearest zone to the last close.
* **The score weights are heuristics.** Validate them with the score-range statistics.
* **The ATR regime is relative to the last 24 h.** It doesn't know about longer volatility cycles.
* **"After estimated costs" is an approximation.** Real costs vary by trade.
* **R is measured against the price risk at the initial SL**, so costs make a full stop slightly worse than −1R, and gaps can make it much worse.
* **Statistics count only this EA's trades.** Max drawdown is closed-trade drawdown of the EA (the tester report shows account drawdown including floating).
* **Session defaults assume a GMT+2/+3 server** and don't adjust for daylight saving.
* **Tester limitations:** simplified slippage and liquidity, and the history quality depends on the broker.
* **The equity drawdown halt counts the whole account's equity** (other EAs and manual trades included).
* **Break-even and trailing act on ticks**, so results depend on the tester's tick modelling.
