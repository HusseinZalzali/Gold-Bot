# GoldBot V1: Simple XAUUSD Expert Advisor for MetaTrader 5 (archived documentation)

> This is the V1 documentation, kept for reference. See the main [README](../README.md) for V2.

GoldBot is a small, rule-based Expert Advisor (EA) for MetaTrader 5 that trades gold (XAUUSD). It is built so you can **read and understand every decision it makes**. It looks for a small number of quality setups, and if nothing qualifies it does nothing.

> ⚠️ **Important: read before using**
>
> * This EA is for **demo testing and learning**. It is **not** a proven or profitable strategy, and nothing here says it will make money.
> * A profitable backtest does **not** mean the strategy works. Backtests can be **overfit** to past data.
> * **Past performance does not guarantee future results.**
> * **Demo forward testing is required** before you even think about real money.
> * **Spread, slippage, commission and execution quality** change results, sometimes a lot. They matter even more with a small stop loss.
> * **XAUUSD can move violently around major news** (NFP, CPI, FOMC, geopolitical events). Price can jump through stop losses.
> * A **high risk/reward ratio (1:5) does not guarantee profitability.** With 1:5 you can lose most of your trades and still break even, but if the win rate is too low the account still loses money.
> * You are fully responsible for anything you do with this code.

---

## 1. Project structure

```
Gold-Bot/
├── README.md                          ← this file
└── MQL5/
    └── Experts/
        └── GoldBot/
            └── GoldBot.mq5            ← the complete EA (single file)
```

The folder layout matches the MetaTrader 5 data folder, so you can copy `MQL5/Experts/GoldBot/` straight into your terminal.

---

## 2. Exact trading rules

The EA evaluates **once per closed M15 candle**, on the first tick of the new candle. It never evaluates on every tick, so one candle can only give one decision.

A trade needs **all three** of these (they're all required):

| # | Component | Required? |
|---|-----------|-----------|
| 1 | H1 trend | **Required** |
| 2 | M15 support/resistance zone | **Required** |
| 3 | M15 price-action confirmation | **Required** |

### 2.1 Trend (H1)
Calculated on the **last closed H1 candle**, so the value doesn't flicker while a candle is forming:

| Environment | Condition |
|-------------|-----------|
| **BULLISH** (only BUYs allowed) | H1 close > EMA 200 **and** EMA 55 > EMA 200 |
| **BEARISH** (only SELLs allowed) | H1 close < EMA 200 **and** EMA 55 < EMA 200 |
| **NEUTRAL** (no trades) | Anything else (mixed signals) |

### 2.2 Support / resistance (M15)
Built from simple **swing points** (fractals):

* A **swing low** is a candle whose low is lower than the `Swing strength` (default 3) candles on each side.
* A **swing high** is the mirror image.
* Only swings from the last `Swing lookback` (default 100) M15 candles are used.
* A swing only counts if it formed **before** the last two candles. The candles being tested can't create their own level.
* A level is thrown out as **broken** if any later candle **closed** through it.
* **Support** = the nearest valid swing low **below** the confirmation candle's close.
* **Resistance** = the nearest valid swing high **above** the confirmation candle's close.

**Near the zone (BUY):** the lowest low of the last 2 closed candles must be within `Zone tolerance` (default 10 pips) of support, above or below it. If price went **more** than the tolerance below support, the level is treated as broken and there's no trade.
**Near the zone (SELL):** the mirror image, using the highest high and resistance.

### 2.3 Confirmation (M15, the candle that just closed)
The candle must be at least `Min candle range` (default 10 pips) from high to low. **Any one** of these is enough:

| BUY confirmation | SELL confirmation |
|------------------|-------------------|
| **Bullish engulfing:** previous candle bearish, current candle bullish, and its body covers the previous body | **Bearish engulfing:** the mirror image |
| **Bullish rejection:** lower wick ≥ 50% of the range, upper wick ≤ 25%, and the wick reached the support zone | **Bearish rejection:** upper wick ≥ 50%, lower wick ≤ 25%, and the wick reached resistance |
| **Strong bullish close:** bullish body ≥ 60% of the range, closing in the top 20% of the candle | **Strong bearish close:** bearish body ≥ 60%, closing in the bottom 20% |

The shape thresholds (50% / 25% / 60% / 20%) are constants near the top of the source file (`REJECTION_WICK_MIN` and so on), so there are fewer inputs to manage. You can edit them there.

### 2.4 Decision order on each new M15 candle
1. New M15 candle detected
2. H1 trend. If NEUTRAL, then **NO TRADE**
3. Support/resistance zone. If not near a zone, then **NO TRADE**
4. Confirmation candle. If none, then **NO TRADE**
5. Spread ≤ `Max spread`. If too high, then **NO TRADE**
6. Daily risk limits (daily loss, consecutive losses, trades per day). If hit, then **NO TRADE**
7. Trading hours and news blackout. If outside the allowed time, then **NO TRADE**
8. No XAUUSD position already open. If one is open, then **NO TRADE**
9. Terminal, account and symbol allow trading. Lot size is valid. Margin is enough. **Then open ONE trade** at market.

### 2.5 Exits
* A **fixed SL and TP** are attached to the order when it's sent.
* V1 **never changes SL or TP** after entry: no trailing, no break-even, no partial closes.
* The EA never closes trades early. They end at SL, TP, or when you close them by hand.

---

## 3. XAUUSD pips (read this carefully)

Brokers quote gold with different numbers of digits (for example `2350.12` or `2350.123`). The EA **does not** treat a "pip" as one point. It uses a price-based definition:

> **1 pip = 0.10 in price** (the common convention for gold). Example: 2350.00 → 2350.10 is 1 pip.

It then converts to the broker's points automatically:

| Broker digits | Point | 1 pip (0.10) = |
|---------------|-------|----------------|
| 2 (2350.12) | 0.01 | 10 points |
| 3 (2350.123) | 0.001 | 100 points |

So with the defaults:

| Setting | Pips | Price distance |
|---------|------|----------------|
| Stop Loss | 25 | **$2.50** |
| Take Profit | 125 | **$12.50** |
| Wider test SL | 40 | $4.00 |
| Max spread | 5 | $0.50 |
| Zone tolerance | 10 | $1.00 |

When the EA starts, it **prints the conversion** in the Experts log, for example: `1 pip = 0.10 price = 10.0 points (auto)`. Always check this line.

**If you use a different pip definition** (some traders call $1.00 a pip), set `Price value of 1 pip` (`InpPipSize`) to `1.0`. **Every** pip-based input (SL, TP, spread, slippage, zone tolerance, min candle range) then uses that unit, so change all of them to match. For example, a max spread of 5 would then mean $5, which is far too large.

> **Reality check:** a 25-pip ($2.50) stop is **small** compared with typical M15 gold volatility, and the spread alone can be 10–20% of it. Expect many trades to be stopped out by normal noise. That's exactly why the `Use wider test SL` option exists. Test both.

---

## 4. Installation and compiling

1. Open MetaTrader 5, then **File → Open Data Folder**.
2. Copy `MQL5/Experts/GoldBot/GoldBot.mq5` from this repository into `<Data Folder>/MQL5/Experts/GoldBot/`.
3. Open **MetaEditor** (press F4 in MT5, or Tools → MetaQuotes Language Editor).
4. In the Navigator, open `Experts/GoldBot/GoldBot.mq5`.
5. Press **F7** (Compile). The *Errors* tab should show `0 errors`. A file `GoldBot.ex5` is created next to the source.
6. Back in MT5, right-click **Expert Advisors** in the Navigator and choose **Refresh**. *GoldBot* appears in the list.

---

## 5. Attaching to a chart (demo account)

1. Log in to a **DEMO** account.
2. Open **Market Watch** (Ctrl+M) and make sure your gold symbol is visible (`XAUUSD`, `XAUUSDm`, `XAUUSD.a`, `GOLD`, and so on).
3. Open a chart of that symbol. **M15 is recommended**, although the EA always reads M15 and H1 itself whatever the chart timeframe.
4. Drag *GoldBot* onto the chart.
5. On the **Common** tab, tick **Allow Algo Trading**.
6. On the **Inputs** tab, review the settings (see section 8).
7. Click OK, and make sure the **Algo Trading** button on the toolbar is green.
8. The dashboard appears in the top-left of the chart, and the **Experts** tab (Toolbox, Ctrl+T) shows the startup summary.

**Symbol detection:** if the `Symbol` input is empty, the EA uses the chart symbol if it looks like gold (the name contains `XAUUSD` or starts with `GOLD`). Otherwise it searches your broker's symbols for one. You can always type the exact name into the `Symbol` input. If you pick a symbol the EA doesn't recognise as gold, it refuses to start unless you set `Price value of 1 pip` yourself. This prevents a silently wrong pip size. Always attach the EA to a chart of the symbol it trades, because it acts on that chart's ticks.

---

## 6. Backtesting in the Strategy Tester

1. In MT5, open **View → Strategy Tester** (Ctrl+R).
2. Settings:
   * **Expert:** `GoldBot\GoldBot`
   * **Symbol:** your gold symbol
   * **Timeframe:** M15
   * **Date:** start with 6–12 months, for example the last full year
   * **Modelling:** **Every tick based on real ticks** (most realistic). "Every tick" is acceptable. Avoid "Open prices only", because it misses intra-candle SL/TP hits.
   * **Deposit / Leverage:** match your planned demo account (for example 10,000 USD, 1:100)
   * **Optimization:** **Disabled**. Don't optimize V1. Understand it first.
3. On the **Inputs** tab, check the parameters.
4. Click **Start**.
5. When it finishes, look at the **Backtest** (report), **Graph** and **Journal** tabs.

The tester needs history for the M15 **and** H1 timeframes, plus about 200 H1 candles before your start date for EMA 200. MT5 downloads these automatically. If the first days show `H1 indicator data not ready`, that's normal warm-up.

### Visual mode
Tick **Visualize** (Visual mode) before clicking Start. A chart opens and replays the market with the dashboard. You can:
* Slow down or pause the replay to watch each decision.
* Add EMA 55 and EMA 200 on an H1 chart to see the trend yourself.
* Read the **Journal** tab of the visual window: every closed M15 candle logs a `NO TRADE: ...` reason (with `Verbose log` on) or a `TRADE: ...` block.

Visual mode is the best way to understand **why** the bot trades.

---

## 7. Common changes

| I want to... | Change this input |
|--------------|-------------------|
| Change the stop loss | `Stop Loss (pips)` (`InpStopLossPips`) |
| Test a wider stop | Set `Use the wider test Stop Loss` = true and `Wider Stop Loss for testing (pips)` = e.g. 40 |
| Change the take profit | `Take Profit (pips)` (`InpTakeProfitPips`) |
| Risk a different % per trade | `Risk per trade (%)` (`InpRiskPercent`), e.g. 0.25 = a quarter of 1% |
| Use a fixed lot instead | `Lot size mode` = *Fixed lot size*, and set `Fixed lot size` |
| Allow bigger lots | Raise `Safety cap` (`InpMaxLotSize`). Be careful. |
| Change the EMA trend filter | `Fast EMA period` (55) / `Slow EMA period` (200) |
| Change trading hours | `Trading start/end hour/minute` (server time; the end time is not included) |
| Block trading around a news release | `Enable manual news blackout` = true, then set the start/end time for that day |
| Reduce log noise | `Verbose log` = false (blocked setups, trades and errors are still logged) |

**Risk mode example:** with a balance of 10,000 USD and 0.25% risk, the risk budget is 25 USD. With a 25-pip ($2.50) SL on a standard 100-oz contract, 1.00 lot loses about $250, so the EA uses **0.10 lots**. Lots are always rounded **down** to the broker's lot step. If the result is below the broker's minimum lot, the trade is **skipped**, never rounded up.

**Fixed mode warning:** in fixed mode the risk per trade is `lot × SL`, however large that is. The `TRADE:` log line shows the money at risk and the % of balance, so check it. A lot size too large for the SL can hit the daily loss limit with one trade.

---

## 8. All configurable parameters

| Group | Input | Default | Meaning |
|-------|-------|---------|---------|
| Symbol | `InpSymbol` | *(empty)* | Symbol to trade. Empty means the chart symbol, or auto-detect `XAUUSD*` / `GOLD*` |
| Symbol | `InpPipSize` | 0 | Price value of 1 pip. 0 means auto (0.10 for gold) |
| Trend | `InpFastEMAPeriod` | 55 | Fast EMA on H1 |
| Trend | `InpSlowEMAPeriod` | 200 | Slow EMA on H1 |
| S/R | `InpSwingStrength` | 3 | Candles on each side that define a swing high/low |
| S/R | `InpSwingLookbackBars` | 100 | How many M15 candles back to search for swings (100 ≈ 25 hours) |
| S/R | `InpZoneTolerancePips` | 10 | Maximum distance between price and the level to count as "at the zone" |
| S/R | `InpMinCandleRangePips` | 10 | Minimum high-low size of a confirmation candle |
| SL/TP | `InpStopLossPips` | 25 | Stop loss |
| SL/TP | `InpTakeProfitPips` | 125 | Take profit (1:5 with the default SL) |
| SL/TP | `InpUseWiderStopLoss` | false | Use the wider SL below instead |
| SL/TP | `InpWiderStopLossPips` | 40 | Wider SL for testing. Lot size adapts, so money risk stays the same in risk mode |
| Lots | `InpLotMode` | Risk-based | *Risk-based* or *Fixed lot size* |
| Lots | `InpRiskPercent` | 0.25 | % of balance risked per trade (risk mode). Allowed range 0–5 |
| Lots | `InpFixedLotSize` | 0.01 | Lot size in fixed mode |
| Lots | `InpMaxLotSize` | 1.00 | Hard safety cap on any order's lot size |
| Daily | `InpMaxDailyLossPercent` | 2.0 | Stop new trades for the day when realized + floating P/L ≤ −2% of the day-start balance |
| Daily | `InpMaxConsecutiveLosses` | 3 | Stop for the day after 3 losses in a row (counted within the day) |
| Daily | `InpMaxTradesPerDay` | 3 | Maximum new trades per day |
| Execution | `InpMaxSpreadPips` | 5 | No trade if the spread is larger than this |
| Execution | `InpMaxSlippagePips` | 3 | Maximum accepted slippage (deviation) on market orders |
| Execution | `InpMagicNumber` | 55200125 | Identifies this EA's trades. Use a different number per chart/EA |
| Execution | `InpTradeComment` | GoldBot V1 | Order comment |
| Hours | `InpStartHour` / `InpStartMinute` | 08:00 | Trading window start (server time) |
| Hours | `InpEndHour` / `InpEndMinute` | 20:00 | Trading window end, not included. Start = end means all day |
| News | `InpNewsFilterEnabled` | false | Turn on the manual blackout |
| News | `InpNewsStart*` / `InpNewsEnd*` | 14:15–15:00 | Blackout window (server time), repeats every day while enabled |
| Display | `InpShowDashboard` | true | On-chart dashboard |
| Display | `InpVerboseLog` | true | Log a NO TRADE reason on every closed M15 candle |

Fixed by design (constants in the code, not inputs):
* **Maximum open positions: 1.** Positions on the symbol are counted whatever their magic number, so the EA also won't add to a manual gold trade.
* A failed order is retried **at most once**, and only for requote or price-changed errors.

---

## 9. Safety features

| Protection | How |
|------------|-----|
| No martingale / no lot increase after losses | Lot size depends only on balance, risk % and SL distance, or on the fixed lot. Past results aren't used. |
| No grid / no averaging down / no hedging | Maximum 1 open position on the symbol. Opposite trades are impossible while one is open. |
| No duplicate trades | One evaluation per M15 candle, and the candle is marked as processed *before* evaluation. Open positions are re-checked immediately before every send attempt. Orders are sent synchronously. |
| Daily loss limit | Realized + floating P/L checked against the day-start balance. When hit, trading is **latched off** until the next server day. |
| Consecutive-loss limit | Counted from today's closed trades, including costs. Latched off when hit. |
| Max trades per day | Counted from today's entry deals. Latched off when hit. |
| Spread filter | Checked right before entry |
| Margin check | `OrderCalcMargin`. The trade is skipped if it needs more than 90% of free margin. |
| Lot validation | Rounded down to the lot step. Must be ≥ broker minimum and ≤ min(broker maximum, safety cap), otherwise skipped. |
| Broker stop level | If SL/TP is inside the broker's minimum stop distance (spread included), the trade is skipped. The SL is never silently widened. |
| Restart-safe | Daily counters are rebuilt from the account history, so restarting the terminal doesn't reset the limits. |
| Error handling | Every failed order logs the retcode, its description, the last error, and the lot size, price, SL and TP. |

---

## 10. Reading the log

Examples of what you'll see in **Experts** (live) or **Journal** (tester):

```
[M15 2025.03.12 10:15] NO TRADE: H1 trend unclear (H1 close=2915.40, EMA55=2921.10, EMA200=2908.35).
[M15 2025.03.12 10:30] NO TRADE: Price not near support (support=2911.20, recent low=2916.85, 56.5 pips away, tolerance 10.0 pips).
[M15 2025.03.12 10:45] NO TRADE: No bullish confirmation at support 2911.20 (no engulfing, rejection or strong bullish close).
[M15 2025.03.12 11:00] NO TRADE: BUY setup found but blocked - Spread too high (7.2 pips > max 5.0 pips).
[M15 2025.03.12 11:15] TRADE: BUY XAUUSD
   Reason: Bullish H1 trend + support at 2911.20 + bullish engulfing candle.
   Lots=0.10  Entry=2912.35  SL=2909.85 (25.0 pips)  TP=2924.85 (125.0 pips)  Risk~25.00 USD (0.25% of balance)  Deal #123456
TRADE CLOSED: XAUUSD position #123455 hit Stop Loss | Net result: -25.40 USD (LOSS)
DAILY TRADING STOPPED: Consecutive loss limit reached (3 losses in a row). No new trades until the next server day.
NEW TRADING DAY: counters reset for 2025.03.13. Day-start balance: 9924.60 USD
```

The dashboard shows the trend, setup state, today's trades, today's P/L, consecutive losses, whether daily trading is enabled or stopped, the current spread, SL/TP, and the last decision.

---

## 11. Interpreting backtest results

Look at more than net profit:

| Metric (tester report) | What to look for |
|------------------------|------------------|
| **Total trades** | Enough to mean anything. Fewer than ~100 trades is statistically weak. |
| **Profit trades %** (win rate) | With 1:5 R:R, break-even before costs is about **16.7%**. Spread and commission push that higher. |
| **Profit factor** | Gross profit ÷ gross loss. Values near 1.0 are fragile. |
| **Maximal drawdown** | Could you live with it on a real account? |
| **Max consecutive losses** | Long losing streaks are normal with a 1:5 design, so be ready for them. |
| **Expected payoff** | Average result per trade. Compare it with your average spread cost. |
| **Graph** | A steady curve is better than one big lucky trade. |

Good habits:
* Test **several separate periods** (for example 2022, 2023, 2024, 2025) and see whether behaviour is consistent.
* Test with a **higher spread** (use a fixed spread in the tester, for example 30–50 points on a 2-digit symbol) and see whether results survive.
* Compare `Use wider test SL` = false vs true.
* **Don't** tune parameters until one period looks great. That's overfitting, and it usually fails on new data.
* Remember that the tester can't fully model news spikes, requotes or slippage on your broker.

---

## 12. Demo forward test

1. Run the EA on a **demo** account for **at least 4–8 weeks** (longer is better), on a VPS or a computer that stays on.
2. Use the same settings as your backtest.
3. Every day, check the Experts log. Do the `TRADE:` reasons match what you see on the chart?
4. Every week, compare the demo results with a backtest over the same weeks. Large differences usually point to spread, slippage or execution issues.
5. Write down every trade that surprised you, and why.

---

## 13. Demo testing checklist

**Before starting**
- [ ] The EA compiles with 0 errors in MetaEditor
- [ ] Attached to a **demo** account, on the gold chart, with Algo Trading enabled (green)
- [ ] Startup log shows the correct symbol and `1 pip = 0.10 price` (or your chosen pip size)
- [ ] Startup log shows sensible SL/TP price distances and "Money at risk per 1.00 lot"
- [ ] The broker's server time zone is known, and trading hours are adjusted if needed
- [ ] `Max spread` suits your broker's normal gold spread
- [ ] Magic number is unique if you run other EAs

**Behaviour to verify on demo**
- [ ] The dashboard updates and shows the trend, spread and daily stats
- [ ] A `NO TRADE:` or `TRADE:` line appears once per M15 candle (verbose on), not on every tick
- [ ] No trade opens when the H1 trend is NEUTRAL
- [ ] BUYs only happen in a BULLISH trend, and SELLs only in a BEARISH one
- [ ] Never more than **one** gold position open at a time
- [ ] Every trade has an SL and a TP attached at entry
- [ ] Lot size matches the expected risk (check `Risk~` in the log)
- [ ] No trades outside trading hours, or inside the news blackout when enabled
- [ ] After 3 losses in a row, "DAILY TRADING STOPPED" appears and no new trades open that day
- [ ] The daily loss limit stops new trades when reached
- [ ] Counters reset on the new server day ("NEW TRADING DAY" in the log)
- [ ] Restarting the terminal mid-day keeps today's counters (they're rebuilt from history)
- [ ] Order errors, if any, are logged with a clear retcode

**Before considering anything beyond demo**
- [ ] At least 4–8 weeks and a meaningful number of trades on demo
- [ ] Demo results are in line with backtests over the same period
- [ ] You understand every losing streak and the worst drawdown
- [ ] You accept that past results don't guarantee future results

---

## 14. Known limitations (V1)

* **No real news filter.** Only a manual daily time window. It doesn't know when news is actually scheduled, and it repeats every day while enabled.
* **Fixed SL/TP.** They don't adapt to volatility. A 25-pip stop can be too tight in fast markets and too loose in quiet ones.
* **No trade management.** No trailing stop, break-even or partial close (by design for V1).
* **Simple S/R.** Swing points only: no volume, no multi-timeframe zones, no zone strength scoring. Some valid levels will be missed, and some weak ones used.
* **The SL is not tied to the zone.** It's a fixed distance from entry, so it can sit inside or outside the support/resistance level depending on the candle.
* **Server-time day.** Daily limits reset at 00:00 broker server time, which may not match your local time.
* **Positions carried over midnight:** their whole floating P/L (including yesterday's part) counts towards today's loss limit, and their close counts as today's realized result. This errs on the cautious side.
* **Daily stats count only this EA's trades** (by magic number and symbol). The position limit counts **all** positions on the symbol.
* **Weekend gaps and news spikes** can fill an SL at a worse price than planned, so real losses can exceed the planned risk.
* **Commission is not included in lot sizing**, and the floating P/L doesn't include the exit commission, so the real risk per trade is slightly higher on commission accounts.
* **Risk % uses balance**, not equity.
* **Evaluation happens on the first tick after an M15 candle closes.** On a quiet market that tick can arrive a little late.
* **Tester limitations:** the tester's spread and slippage model is simplified and can't reproduce your broker's real execution.
* **Not compiled in this repository's CI.** Compile it yourself in MetaEditor, and report any errors.

---

## 15. What V1 deliberately doesn't do

No AI or machine learning, no neural networks, no sentiment analysis, no complicated indicators, no news APIs, no martingale, no grid, no hedging, no averaging down, no recovery trading, and no lot increase after a loss.
