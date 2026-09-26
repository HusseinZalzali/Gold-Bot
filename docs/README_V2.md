# GoldBot V2: Simple XAUUSD Expert Advisor for MetaTrader 5 (archived documentation)

> This is the V2 documentation, kept for reference. See the main [README](../README.md) for V3.

GoldBot is a rule-based Expert Advisor (EA) for trading gold (XAUUSD) in MetaTrader 5. **V2** keeps the V1 core and adds better trade selection, volatility awareness, simple trade management and statistics. It stays small enough that you can read every rule and understand every decision.

The bot doesn't try to predict where gold will go. It only says:

> "The market is trending bullish" + "price reached an area that mattered before" + "price reacted bullishly" + "entry conditions are acceptable" + "risk is acceptable". **Then it trades. Otherwise it waits.**

> ⚠️ **Important: read before using**
>
> * This EA is for **demo testing and learning**. **Nothing here claims V2 is profitable.**
> * A profitable backtest does **not** prove the strategy works, because backtests can be **overfit**.
> * **Past performance does not guarantee future results.** Demo forward testing is **required**.
> * **Spread, slippage and commission** change results. **XAUUSD moves violently around major news.**
> * A **high risk/reward ratio does not guarantee profitability.**
> * There's no martingale, grid, averaging down, hedging, recovery logic, AI or machine learning, and it never forces trades.

---

## Contents
1. [Project structure](#1-project-structure)
2. [What changed from V1](#2-what-changed-from-v1)
3. [Exact V2 trading rules](#3-exact-v2-trading-rules)
4. [Quality score](#4-quality-score)
5. [Stop loss, take profit and trade management](#5-stop-loss-take-profit-and-trade-management)
6. [Risk and daily protection](#6-risk-and-daily-protection)
7. [XAUUSD pips](#7-xauusd-pips)
8. [Installation](#8-installation)
9. [Backtesting](#9-backtesting)
10. [Out-of-sample testing](#10-out-of-sample-testing-read-this)
11. [Statistics, dashboard and logs](#11-statistics-dashboard-and-logs)
12. [Example backtest interpretation](#12-example-backtest-interpretation)
13. [Recommended demo testing procedure](#13-recommended-demo-testing-procedure)
14. [All parameters](#14-all-parameters)
15. [Known limitations](#15-known-limitations)

---

## 1. Project structure

```
Gold-Bot/
├── README.md                          ← this file (V2)
├── docs/
│   └── README_V1.md                   ← V1 documentation (reference)
└── MQL5/
    └── Experts/
        └── GoldBot/
            ├── GoldBotV2.mq5          ← V2 EA (use this)
            └── GoldBot.mq5            ← V1 EA (kept as a baseline for comparison)
```

V1 and V2 use **different default magic numbers** (55200125 and 55200226), so you can run and compare both on demo without them mixing statistics. The one-position rule still counts **all** positions on the gold symbol, so they won't stack on the same account.

---

## 2. What changed from V1

| Area | V1 | V2 |
|------|----|----|
| Trend | H1 EMA 55/200 | **Same** (required), now graded as *strong* (close beyond both EMAs) or *pullback* (close between the EMAs) |
| Support/resistance | Nearest single swing | **Zones**: nearby unbroken swings are merged, and a zone with 2+ reactions scores higher |
| Confirmation | Rejection / engulfing / strong close | Same patterns, but the candle **must close in the trade direction**, and its size is measured against ATR |
| Entry timing | none | **M15 EMA 9**: close above it for BUY, below it for SELL |
| Volatility | Fixed minimum candle size | **M15 ATR** filter: minimum ATR (dead market) and optional maximum ATR (chaos) |
| Chasing | none | **Max distance from zone**: if price has already run away, it waits |
| Stop loss | Fixed 25 pips | **Fixed or ATR-based**, pushed **beyond the zone** when that's further, and the trade is **rejected** if the SL would exceed **Max SL** |
| Take profit | Fixed 125 pips | **Risk:reward multiple** (default 4R) |
| Trade management | none | **Break-even** at +1R (on by default), optional **ATR trailing stop** (off by default) |
| Trading hours | One window | **Sessions**: London / New York / London+NY / Custom |
| Daily protection | Loss %, consecutive losses, trades/day | Same, plus a **daily profit boundary** and a **cooldown after a loss** |
| Direction | Both | **AllowBuy / AllowSell** switches |
| Position sizing | Risk % of balance | Risk % of the **lower of balance and equity** |
| Decision quality | all-or-nothing | **0–100 score** with a minimum score |
| Logging | One line per decision | **Full checklist** for every potential trade |
| Statistics | Today only | **Full statistics** (overall, BUY/SELL, per session), printed when the EA stops, plus a **CSV trade list** |

Unchanged: one evaluation per closed M15 candle, **maximum one open position**, max spread filter, manual news blackout, lots never rounded up, safety lot cap, margin check, and restart-safe counters.

---

## 3. Exact V2 trading rules

The EA evaluates **once per closed M15 candle**, on the first tick of the next candle. The candle is marked as processed **before** evaluation, so no candle can be traded twice.

### Step 1: H1 trend (required)
Uses the **last closed H1 candle**:

| Environment | Condition | Grade |
|-------------|-----------|-------|
| BULLISH (BUY only) | H1 close > EMA 200 **and** EMA 55 > EMA 200 | *strong* if the close is also > EMA 55, otherwise *pullback* |
| BEARISH (SELL only) | H1 close < EMA 200 **and** EMA 55 < EMA 200 | *strong* if the close is also < EMA 55, otherwise *pullback* |
| NEUTRAL | anything else | **no trade** |

If the direction is switched off (`AllowBuy` / `AllowSell`), the EA waits.

### Step 2: Support/resistance zone (required)
1. Find M15 **swing lows** (for BUY) or **swing highs** (for SELL). A swing is a candle whose low (high) is beyond the `Swing strength` (3) candles on each side, within the last `Swing lookback` (150) candles.
2. Ignore swings that are **broken**, meaning a later candle **closed** through them.
3. Ignore swings that aren't fully formed before the last two candles, so the tested candles can't create their own level.
4. **Merge** swings that are within `Zone merge` (15 pips) of each other into one zone. Each merged swing is one *reaction*.
5. For a **BUY**, use the nearest support zone below the last close. For a **SELL**, use the nearest resistance zone above it.
6. **Reached:** the last two candles must have come within `Zone distance` (20 pips) of the zone.
7. **Not broken:** they must not have pierced more than `Zone distance` beyond the far edge of the zone.

If price hasn't reached a zone, there's no potential trade. The EA logs a short `WAIT:` line and stops there.

### Step 3: Full checklist (only when a zone was reached)
Every check below is evaluated, even after one fails, so the log shows the full picture:

| Check | BUY rule | SELL rule | Required |
|-------|----------|-----------|----------|
| **Candle** | Closes **bullish**, is at least 50% of ATR in size, **and** is a bullish rejection (lower wick ≥ 50% of the range, upper wick ≤ 30%, wick reached the zone), a bullish engulfing, or a strong bullish candle (body ≥ 60%, closes in the top 25%) | Mirror image | Yes |
| **EMA 9** | Close > M15 EMA 9 | Close < M15 EMA 9 | Yes (default). If `Require EMA confirm` = false it only affects the score. |
| **ATR** | `Min ATR` ≤ ATR ≤ `Max ATR` | same | Yes |
| **Entry (no chasing)** | Ask is at most `Max distance from zone` (30 pips) above the zone top | Bid is at most 30 pips below the zone bottom | Yes |
| **Stop loss** | The calculated SL is ≤ `Max SL` and outside the broker's minimum stop distance | same | Yes |
| **Spread** | ≤ `Max spread` | same | Yes |
| **Score** | ≥ `Min score` | same | Yes |
| **Time** | Inside the selected session and not in the news blackout | same | Yes |
| **Risk** | Daily trading not stopped, and not in cooldown | same | Yes |
| **Position** | No gold position open | same | Yes |

**All must pass.** Then the EA checks terminal/account permissions, calculates the lot, checks margin, and sends **one** market order with SL and TP attached.

---

## 4. Quality score

The score is a **simple checklist total**, not AI. Trend, zone and candle are **required** anyway. The score grades **how good** each one is, so the minimum score can filter out weak combinations.

| Component | Points |
|-----------|--------|
| Trend: strong (H1 close beyond both EMAs) | 30 |
| Trend: pullback (H1 close between EMA 55 and EMA 200) | 15 |
| Zone: 2+ swing reactions | 25 |
| Zone: single swing | 10 |
| Candle: rejection or engulfing | 20 |
| Candle: strong directional candle | 10 |
| EMA 9 confirmation | 15 |
| ATR inside limits | 10 |
| **Maximum** | **100** |

With the defaults (EMA 9 required, minimum score **70**):

| Example | Score | Trades? |
|---------|-------|---------|
| strong trend + multi-reaction zone + rejection | 30+25+20+15+10 = **100** | yes |
| strong trend + single swing + strong candle | 30+10+10+15+10 = **75** | yes |
| pullback trend + single swing + rejection | 15+10+20+15+10 = **70** | yes |
| pullback trend + single swing + strong candle | 15+10+10+15+10 = **60** | **no** |

Raise `Min score` to 80 or 85 to only take the cleaner combinations. Compare the results in backtests **without** tuning it to one period.

---

## 5. Stop loss, take profit and trade management

### Stop loss
1. **Base distance:**
   * `Fixed pips` mode: `Fixed SL` (25 pips).
   * `ATR` mode (**default**): ATR × `ATR SL multiplier` (1.0).
2. **Structure** (`Use structure SL` = true): the SL is placed beyond the zone and the last two candles, plus `SL buffer` (5 pips), **if that is further away** than the base distance.
   * BUY: `min(zone bottom, low of the last 2 candles) − buffer`
   * SELL: `max(zone top, high of the last 2 candles) + buffer`
3. **Maximum:** if the final SL is larger than `Max SL` (80 pips), then **NO TRADE**. The EA never widens the stop to fit a bad setup.

### Take profit
`TP distance = SL distance × Risk reward` (default **4.0**, allowed 1–10). For example, a 40-pip SL gives a 160-pip TP. TP is **never** changed after entry.

### Break-even (on by default)
When the trade is `Break-even at R` (1.0R) in profit, the SL moves to **entry ± `Break-even buffer`** (2 pips). It happens once, and the SL never moves back.

### Trailing stop (off by default)
If enabled, it starts at `Trail start R` (2.0R) profit, and the SL follows price at **ATR × `Trail ATR multiplier`** (2.0 × ATR). It only moves in the trade's favour, in steps of at least 10% of the initial risk, so it doesn't react to tiny moves.

Management runs on every tick for this EA's position only. If the broker's stop/freeze level blocks a change, it quietly tries again on a later tick. After a failed modification it waits 30 s.

---

## 6. Risk and daily protection

### Lot size
* **Risk mode (default):** lots = (lower of balance and equity × `Risk %`) ÷ (money lost per 1.00 lot at the SL). The money per lot comes from `OrderCalcProfit`, which uses the broker's tick size and tick value, so it's correct whatever digits the broker uses.
* **Fixed mode:** `Fixed lot`.
* Lots are rounded **down** to the lot step, capped at min(broker maximum, `Max lot` safety cap), and **skipped** if below the broker minimum (never rounded up). Margin must be ≤ 90% of free margin.
* A wider (ATR/structure) SL means a **smaller lot**, so the money at risk stays the same.

### Daily limits (reset at 00:00 broker server time)
| Limit | Default | Effect |
|-------|---------|--------|
| Max daily loss | 2% | Realized + floating P/L ≤ −2% of the day-start balance: **stop for the day** |
| Daily profit boundary | 3% | Realized + floating ≥ +3%: **stop for the day**. This is a boundary, not a target, and nothing is forced to reach it. |
| Max consecutive losses | 3 | 3 losing trades in a row today: **stop for the day** |
| Max trades per day | 3 | Stop opening trades after 3 today |
| Cooldown after loss | 30 min | After any losing trade, no new entries for 30 minutes. After that, a **completely new valid setup** is still required. |

"Stop for the day" is **latched** until the next server day. Open trades continue under their normal SL/TP and break-even. All counters are rebuilt from the account history, so restarting the terminal doesn't reset them.

### Hard safety rules
* Maximum **1** open gold position (any magic number, including manual trades).
* One evaluation per M15 candle. Open positions are re-checked right before every send. Orders are sent synchronously. At most one retry, and only for requote or price-changed errors.
* No martingale, grid, averaging down, hedging or recovery sizing. The lot never depends on previous results.

---

## 7. XAUUSD pips

**1 pip = 0.10 in price** (for example 2350.00 → 2350.10). The EA converts this to broker points automatically: 10 points on a 2-digit quote, or 100 points on a 3-digit quote. Every pip input (SL, max SL, ATR limits, zone distances, spread, slippage, buffers) uses the same unit. The startup log prints `1 pip = 0.10 price = N points`, so always check it.

| Pips | Price move |
|------|-----------|
| 20 | $2.00 |
| 25 | $2.50 |
| 80 | $8.00 |
| 160 | $16.00 |

Gold symbols (`XAUUSD*`, `GOLD*`) are detected automatically. For any other name, the EA refuses to start unless you set `Price value of 1 pip` yourself. If you prefer a different pip definition, set that input and **rescale every pip input**.

**Calibrate the ATR limits for your period.** With gold at $2,000–4,000, M15 ATR is often 20–80 pips. The defaults (15 min / 120 max) are only a starting point. Check the `ATR` line in the setup log or on the dashboard.

---

## 8. Installation

1. MT5: **File → Open Data Folder**.
2. Copy `MQL5/Experts/GoldBot/GoldBotV2.mq5` into `<Data Folder>/MQL5/Experts/GoldBot/`.
3. Open **MetaEditor** (F4), open the file and press **F7** (Compile). You should see **0 errors**.
4. In MT5's Navigator, right-click **Expert Advisors** and choose **Refresh**.
5. Log in to a **DEMO** account and open a chart of your gold symbol. M15 is recommended; the EA reads M15 and H1 itself.
6. Drag **GoldBotV2** onto the chart. On the **Common** tab tick **Allow Algo Trading**, review the **Inputs**, then click OK.
7. The toolbar **Algo Trading** button must be green. The dashboard appears top-left, and the startup summary appears in **Toolbox → Experts**.

**Check your broker's server time.** The Market Watch clock shows it. Sessions and the news blackout use **server time**. The default session times assume a common **GMT+2 / GMT+3** server:

| Session | Default (server) | Roughly in GMT |
|---------|------------------|----------------|
| London | 10:00–19:00 | 07/08:00–16/17:00 |
| New York | 15:00–22:00 | 12/13:00–19/20:00 |

If your server runs on GMT, subtract 2–3 hours.

---

## 9. Backtesting

1. **View → Strategy Tester** (Ctrl+R).
2. Settings:
   * **Expert:** `GoldBot\GoldBotV2`
   * **Symbol:** your gold symbol
   * **Timeframe:** M15
   * **Modelling:** **Every tick based on real ticks** (preferred) or *Every tick*. Don't use *Open prices only*, because break-even and SL/TP need intra-candle prices.
   * **Deposit and leverage:** the same as your planned demo account
   * **Optimization: Disabled**
3. Tick **Visualize** to watch decisions candle by candle, with the dashboard and the Journal.
4. When the test finishes, read the **Backtest** report, the **Graph**, and the **Journal**. The Journal ends with the V2 statistics report (section 11).

The EA needs about 200 H1 candles before the start date for EMA 200. MT5 loads them automatically. `WAIT: H1 indicator data not ready yet` on the first day is normal.

### Tests worth running (one change at a time)
| Question | How |
|----------|-----|
| Different years and market conditions | Same settings on 2021, 2022, 2023, 2024, 2025 separately |
| SL mode | `Stop loss mode` = Fixed vs ATR |
| Risk:reward | `Risk reward` = 2, 3, 4, 5 |
| Sessions | `Trading session` = London / New York / London+NY |
| Direction | `Allow SELL` = false (BUY only), then `Allow BUY` = false (SELL only) |
| Score filter | `Min score` = 70 / 80 / 90 |
| Management | Break-even on vs off; trailing on vs off |
| Costs | Set a higher fixed spread in the tester and see whether results survive |

**Don't** use the optimizer to search hundreds of combinations. With enough combinations, *something* always looks good on past data by pure luck.

---

## 10. Out-of-sample testing (read this)

**Never judge the EA only on the period you used to choose its settings.**

Split your data into two parts:

| Part | Example | Use |
|------|---------|-----|
| **In-sample** (development) | 2022-01-01 → 2025-12-31 | Understand the rules, choose settings, and run the comparisons above |
| **Out-of-sample** (validation) | 2026-01-01 → today | Run **once**, with settings **frozen**, and see whether behaviour is similar |

Why this matters:
* Every time you change a setting because it improved the in-sample result, you fit the settings a little more to *that* history, noise included. The in-sample result becomes more optimistic than reality.
* The out-of-sample period is data the settings have never "seen". If results collapse there, the in-sample edge was probably curve-fitting.
* If you then change settings **after** seeing out-of-sample results, that period is no longer out-of-sample. Treat the **demo forward test** as the next, truly unseen sample.
* Similar (not identical) behaviour in both periods is encouraging: comparable win rate, average R, drawdown and trade frequency. Much better or much worse is a warning sign.

The dates are examples; use whatever split fits the data you have. A good rule: **decide the split before you start testing.**

---

## 11. Statistics, dashboard and logs

### Checklist log (every potential trade)
```
[M15 2025.03.12 11:00] SETUP CHECK - BUY
   Trend    [OK] BULLISH, strong (H1 close 2915.40, EMA55 2909.10, EMA200 2880.35)  +30
   Zone     [OK] support zone 2905.20-2906.40 (2 reactions)  +25
   Candle   [OK] bullish rejection candle (long lower wick into support)  +20
   EMA9     [OK] close 2910.35 > EMA9 2909.80  +15
   ATR      [OK] ATR 38.5 pips (min 15 / max 120)  +10
   Entry    [OK] entry 8.4 pips from zone (max 30.0)
   ...
   ACTION: BUY
```
When something fails:
```
[M15 2025.03.12 11:15] SETUP REJECTED - BUY
   Trend    [OK] BULLISH, strong (...)  +30
   Zone     [OK] support zone 2905.20-2906.40 (2 reactions)  +25
   Candle   [OK] bullish engulfing candle  +20
   EMA9     [X]  close 2908.10 <= EMA9 2909.80
   ATR      [OK] ATR 36.0 pips (min 15 / max 120)  +10
   Entry    [OK] entry 12.3 pips from zone (max 30.0)
   StopLoss [OK] SL 42.0 pips (ATR + beyond zone, max 80) -> TP 168.0 pips (4.0R)
   Spread   [OK] 2.8 pips (max 5.0)
   Score    [OK] 85/100 (minimum 70)
   Time     [OK] inside session (London+NY 10:00-19:00 / 15:00-22:00)
   Risk     [OK] daily limits OK
   Position [OK] no open position
   ACTION: NO TRADE - Reason: EMA9 confirmation missing.
```
Markers are ASCII (`[OK]`, `[X]`, and `[--]` for an optional check) so they display correctly in every MT5 log.

Other log lines: `WAIT: ...` (no potential trade on this candle), `TRADE OPENED`, `MANAGE: Break-even ...`, `TRADE CLOSED: ... (+4.00R) WIN`, `DAILY TRADING STOPPED: ...`, `NEW TRADING DAY: ...`, `ORDER ERROR: ...`.

### Dashboard
The dashboard shows:
* trend, setup, last score, ATR, spread, and the session (IN or OUT)
* today's trades, wins, losses and P/L, plus consecutive losses and daily status (ACTIVE / STOPPED / COOLDOWN)
* the current position (NONE / BUY / SELL, and whether the SL is already protected)
* risk per trade
* all-time trades, win rate, profit factor, net, max drawdown, average R, and BUY vs SELL.

### Statistics report (printed when the EA is removed or a backtest ends)
Calculated only from **this EA's** trades (symbol + magic number), rebuilt from the account history:
* **Overall:** total trades, wins, losses, win rate, average win, average loss, profit factor, net profit, average R, average entry spread
* **Max drawdown** (closed trades, money and %), **max consecutive losses**, **average trades per weekday**
* **BUY vs SELL:** the same metrics
* **Session:** London only / London–NY overlap / New York only / other hours, by entry time, using the London and New York windows

**R multiple** = net result ÷ money at risk with the initial SL. For example, +4.0R is a full TP, −1.0R a full SL, and ~0R a break-even exit.

### CSV trade list
If `Write trade CSV` = true, `GoldBotV2_trades_<symbol>_<magic>.csv` is written to the **Common Data Folder** (`File → Open Data Folder`, go up one level to `Common/Files`). It's written in live trading and in the tester. It has one row per trade: direction, session, times, prices, initial SL, lots, spread at entry, net, R, and exit type. Open it in Excel or Google Sheets for your own analysis.

---

## 12. Example backtest interpretation

> The numbers below are **invented for illustration**. They are **not** real GoldBot results.

```
ALL               : 180 trades | W 49 / L 118 | win 27.2% | net 1,420.00 | PF 1.25 | avg win 146.10 | avg loss -48.63 | avg R +0.14 | avg spread 2.6
Max drawdown (closed trades): 910.00 USD (8.6%) | Max consecutive losses: 11 | Avg trades per weekday: 0.35
BUY               : 131 trades | ... | net 1,690.00 | PF 1.42 | avg R +0.22
SELL              :  49 trades | ... | net -270.00 | PF 0.88 | avg R -0.09
London only       :  52 trades | ... | avg R +0.05
London/NY overlap :  81 trades | ... | avg R +0.25
New York only     :  47 trades | ... | avg R +0.06
```

How to read it:
* **Win rate 27% with 4R targets.** That's plausible for this design. Break-even for a pure 4R system is about 20%, but break-even exits (~0R) and costs change the maths, so look at **average R** instead. Here +0.14R per trade is a thin edge. Spread and slippage can erase that.
* **13 trades aren't wins or losses.** Those are break-even exits (180 − 49 − 118). That's normal with break-even on.
* **11 losses in a row.** Low-win-rate systems produce long losing streaks. At 0.25% risk that's about −2.75%. Could you sit through it without interfering?
* **BUY positive, SELL negative.** Is that the strategy, or just that gold rose in the test period? Check the **same** split on a period where gold fell before concluding "BUY only".
* **Overlap best.** That's plausible (most liquidity), but 81 trades is a small sample. See whether it holds **out-of-sample** before restricting sessions.
* **0.35 trades per weekday.** The bot skipped most days. That's by design, not a bug.
* **Profit factor 1.25 over 180 trades.** Encouraging but fragile. Re-run with a higher tester spread. If PF drops below ~1.1, the edge is probably too small for real conditions.

**Conclusion for this invented example:** worth a **demo forward test** with frozen settings. It is **not** a reason to go live, and not a reason to start tuning until the numbers look better.

---

## 13. Recommended demo testing procedure

1. **Freeze settings** after your backtests. Write them down, or save a `.set` file from the Inputs tab.
2. Run **GoldBotV2 on a demo account** for at least **8 weeks** on a VPS or an always-on computer. Longer and more trades is better.
3. **Daily (5 minutes):** read the Experts log. For every `TRADE OPENED`, look at the chart. Do the checklist lines match what you see? Note anything surprising.
4. **Weekly:** remove and re-attach the EA (or check the dashboard) to see the statistics report. Compare the win rate, average R, average spread and trades per day with your backtest.
5. **Compare demo with a backtest of the same weeks.** Large differences usually come from spread, slippage, server time or execution. Investigate before changing any strategy setting.
6. **Change at most one thing at a time**, and only for a clear reason. After a change, the forward test starts again.

### Demo checklist
**Setup**
- [ ] Compiles with 0 errors
- [ ] Demo account, gold chart, Algo Trading green
- [ ] Startup log: correct symbol, `1 pip = 0.10 price`, sensible "Value of 1 pip" per lot
- [ ] Session times match your broker's server time
- [ ] ATR limits make sense for current volatility (check the dashboard ATR)
- [ ] `Max spread` suits your broker's normal gold spread

**Behaviour**
- [ ] At most one `SETUP CHECK` / `WAIT` decision per M15 candle, never per tick
- [ ] No trades with a NEUTRAL trend, and none against the H1 trend
- [ ] No trade when EMA 9, ATR, spread, session, score or max SL fails, and the log says which
- [ ] Never more than one gold position
- [ ] Every trade has SL and TP at entry. TP ≈ SL × `Risk reward`
- [ ] The lot size matches the expected risk (`Risk~` line)
- [ ] Break-even moves the SL once at +1R, and it never moves back
- [ ] After a loss, no new trade during the cooldown
- [ ] Daily loss, profit, consecutive-loss and trades/day limits stop new trades, and the log says why
- [ ] Counters reset on the new server day, and survive a terminal restart
- [ ] The statistics report and CSV are produced when the EA is removed

---

## 14. All parameters

| Group | Input | Default | Explanation |
|-------|-------|---------|-------------|
| Symbol | `InpSymbol` | *(empty)* | Symbol to trade. Empty means the chart symbol, or auto-detect `XAUUSD*` / `GOLD*` |
| Symbol | `InpPipSize` | 0 | Price value of 1 pip. 0 means automatic (0.10 for gold) |
| Direction | `InpAllowBuy` | true | Allow BUY trades |
| Direction | `InpAllowSell` | true | Allow SELL trades |
| Trend | `InpTrendFastEMA` | 55 | H1 fast EMA for the trend |
| Trend | `InpTrendSlowEMA` | 200 | H1 slow EMA for the trend |
| Timing | `InpEntryEMA` | 9 | M15 EMA used **only** for entry timing |
| Timing | `InpRequireEMAConfirm` | true | true: the close must be beyond the EMA. false: only affects the score |
| Volatility | `InpATRPeriod` | 14 | M15 ATR period |
| Volatility | `InpMinATRPips` | 15 | No trade if ATR is below this (dead market) |
| Volatility | `InpMaxATRPips` | 120 | No trade if ATR is above this (chaos). 0 means off |
| Zones | `InpSwingStrength` | 3 | Candles on each side that define a swing high/low |
| Zones | `InpSwingLookbackBars` | 150 | How many M15 candles back to look for swings (~37 hours) |
| Zones | `InpZoneMergePips` | 15 | Swings within this distance are merged into one zone (more reactions) |
| Zones | `InpZoneDistancePips` | 20 | How close price must come to the zone, and how far past it counts as broken |
| Zones | `InpMaxDistanceFromZonePips` | 30 | Don't chase: maximum entry distance from the zone |
| Score | `InpMinScore` | 70 | Minimum quality score (0–100) |
| SL/TP | `InpSLMode` | ATR | *Fixed pips* or *ATR × multiplier* |
| SL/TP | `InpFixedSLPips` | 25 | SL distance in fixed mode |
| SL/TP | `InpATRSLMultiplier` | 1.0 | SL = ATR × this in ATR mode |
| SL/TP | `InpUseStructureSL` | true | Push the SL beyond the zone and the reaction candles when that's further |
| SL/TP | `InpSLBufferPips` | 5 | Extra distance beyond the zone for the structure SL |
| SL/TP | `InpMaxStopLossPips` | 80 | If the required SL is larger, **no trade** |
| SL/TP | `InpRiskReward` | 4.0 | TP = SL distance × this (1–10) |
| Management | `InpBreakEvenEnabled` | true | Move the SL to break-even |
| Management | `InpBreakEvenAtR` | 1.0 | Profit (in R) that triggers break-even |
| Management | `InpBreakEvenBufferPips` | 2 | The break-even SL sits this far beyond entry |
| Management | `InpTrailingEnabled` | false | Enable the ATR trailing stop |
| Management | `InpTrailStartR` | 2.0 | Profit (in R) before trailing starts |
| Management | `InpTrailATRMultiplier` | 2.0 | Trailing distance = ATR × this |
| Lots | `InpLotMode` | Risk-based | *Risk-based* or *Fixed lot* |
| Lots | `InpRiskPercent` | 0.25 | % of the lower of balance and equity risked per trade (max 5) |
| Lots | `InpFixedLotSize` | 0.01 | Lot size in fixed mode |
| Lots | `InpMaxLotSize` | 1.00 | Hard cap on any order's lot size |
| Daily | `InpMaxDailyLossPercent` | 2.0 | Stop for the day at this loss (realized + floating) |
| Daily | `InpMaxDailyProfitPercent` | 3.0 | Stop for the day at this profit. 0 means off |
| Daily | `InpMaxConsecutiveLosses` | 3 | Stop for the day after this many losses in a row |
| Daily | `InpMaxTradesPerDay` | 3 | Max new trades per day |
| Daily | `InpCooldownAfterLossMinutes` | 30 | Minutes without new entries after a losing trade. 0 means off |
| Execution | `InpMaxSpreadPips` | 5 | No trade if the spread is above this. Also checked again right before sending |
| Execution | `InpMaxSlippagePips` | 3 | Maximum accepted slippage |
| Execution | `InpMagicNumber` | 55200226 | Identifies this EA's trades and statistics |
| Sessions | `InpSessionMode` | London + New York | London / New York / London+NY / Custom |
| Sessions | `InpLondonSession` | 10:00-19:00 | London window (server time). Also used for statistics |
| Sessions | `InpNewYorkSession` | 15:00-22:00 | New York window (server time). Also used for statistics |
| Sessions | `InpCustomSession` | 09:00-21:00 | Used when the mode is Custom |
| News | `InpNewsFilterEnabled` | false | Enable the manual daily blackout |
| News | `InpNewsStartTime` | 15:25 | Blackout start (server time) |
| News | `InpNewsEndTime` | 16:00 | Blackout end (server time) |
| Display | `InpShowDashboard` | true | On-chart dashboard |
| Display | `InpVerboseLog` | true | Log a `WAIT:` line on every candle without a potential trade. Checklists are always logged. |
| Display | `InpWriteTradeCSV` | true | Write the CSV trade list when the EA stops |

Time windows are `HH:MM-HH:MM`, the end time is not included, windows may cross midnight, and `24:00` is allowed as an end time.

Fixed by design (constants at the top of the source): candle-shape ratios, the candle ≥ 50% of ATR rule, the score weights, max 1 position, one retry, 90% margin usage, and the trailing step of 10% of risk.

---

## 15. Known limitations

* **The news filter is manual.** It's one daily time window, with no calendar. You must update it for each event, and it repeats every day while enabled.
* **Simple zones.** Swing points only: no volume, no higher-timeframe zones. Some meaningful levels are missed, and some weak ones used.
* **The score is a heuristic.** The weights are reasonable defaults, not proven values.
* **Session defaults assume a GMT+2/+3 server** and ignore daylight-saving differences between the UK/US and your broker. Adjust them yourself.
* **Server-time day.** Daily limits reset at 00:00 server time. A position held over midnight counts its whole floating P/L towards the new day.
* **Daily and all-time statistics count only this EA's trades.** Max drawdown is closed-trade drawdown of this EA (the tester report shows account drawdown including floating).
* **Commission isn't included in lot sizing** (it is included in P/L and R). Real risk per trade is slightly higher on commission accounts.
* **A break-even exit that ends slightly negative** (commission or slippage bigger than the break-even buffer) counts as a loss. It triggers the cooldown and adds to the consecutive-loss count. Raise `Break-even buffer` if that happens often.
* **Zone choice:** the EA tests only the nearest zone below or above the last close. If a wick pierces that zone and bounces from a lower one, the setup is rejected as "broken".
* **Gaps, news spikes and slippage** can fill SLs worse than planned, so a loss can exceed −1R.
* **Break-even and trailing act on ticks.** In the tester, results depend on the modelling mode. Use real ticks.
* **The SL is anchored to the price at send time.** On a retry after a requote, the SL keeps the same *distance*, so it can shift by the requote amount.
* **Evaluation happens on the first tick after an M15 close**, which can be slightly late on quiet markets.
* **Tester limitations:** simplified spread and slippage, no real liquidity.
* **Not compiled in this repository.** Compile it in MetaEditor, and report any errors or warnings.
