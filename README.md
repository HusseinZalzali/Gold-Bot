# GoldBot V4: XAUUSD Expert Advisor for MetaTrader 5 (Scalp M5 / Swing M15)

GoldBot is a rule-based gold (XAUUSD) Expert Advisor (EA) for MetaTrader 5. **V4** adds a **fast scalping profile on M5**. It also fixes the problem found in the V3 test, where no trade could be opened while gold traded around $4,000+.

> ⚠️ **Evidence status: no backtest results exist for V4 yet.**
>
> * V4 hasn't been compiled or tested in the environment it was built in.
> * Nothing here claims it is profitable.
> * **More trades is not more profit.** Scalping makes each trade's spread and commission a bigger share of the result. Judge it on the V3 testing method: average R after costs, enough trades, out-of-sample results, then a demo forward test.
> * The bot **never forces trades**. With no trend, outside the session, or on news spikes, it waits, even in scalp mode.

---

## 1. Why V4: what the V3 test showed

The MetaQuotes-Demo backtest of V3 (1–27 Sep 2026, defaults) found **152 potential setups and 0 trades**. The log shows why:

| Finding (from the tester log) | Numbers |
|-------------------------------|---------|
| Setups with a valid reaction candle **and** EMA 9 confirmation | 16 of 152 |
| Of those 16, entry distance from the zone | 78–230 pips (limit was **30**) |
| Of those 16, required stop loss | 85–250 pips (limit was **80**) |
| Typical M15 ATR in the period | median 77 pips (V3 max ATR was 120, and was exceeded on spikes) |

The pip limits in V3 were sized for gold at about $2,000–2,600. At about $4,200, gold's moves in pips roughly doubled. By the time a confirmation candle closed, price was already "too far" by the fixed-pip rules. **Every** good setup was blocked by the rule set's design, not by the market.

**The V4 fix:** every distance limit is now a **multiple of ATR**, so it scales with volatility automatically.

| Limit | V3 (fixed pips) | V4 (ATR multiple) |
|-------|-----------------|-------------------|
| Zone "near" distance | 20 pips | **0.3 × ATR** |
| Swing merge distance | 15 pips | **0.3 × ATR** |
| Max distance from zone (no chasing) | 30 pips | **1.5 × ATR** (room for one normal reaction candle) |
| SL buffer beyond the zone | 5 pips | **0.1 × ATR** |
| Max stop loss | 80 pips | **2.5 × ATR** |
| Min ATR (dead market) | 15 pips | **ATR ≥ 4 × current spread** (a cost-based rule) |
| Max ATR (chaos) | 120 pips | **ATR ≤ 2 × its 24 h average** (spike detection) |

---

## 2. Profiles

Choose one input: **`InpProfile`**. Each profile sets the values in the table below. The inputs marked **[custom]** are only used with the **Custom** profile.

| Setting | **Scalp M5** (default) | **Swing M15** (V3 rules, ATR-scaled limits) |
|---------|------------------------|--------------------------|
| Entry timeframe (evaluated once per closed candle) | **M5** | M15 |
| Trend timeframe and EMAs | **M15** EMA 50 / 200 | H1 EMA 55 / 200 |
| Where it enters | **Pullback to the M5 EMA 21** | Swing support/resistance zone |
| Target | **1.5R** | 4R |
| Min score (EMA-pullback zone scores 15 points) | 60 | 70 |
| Max trades per day | **20** | 3 |
| Stop after consecutive losses | 5 | 3 |
| Cooldown after a loss | 10 min | 30 min |

Shared by both profiles, and adjustable:
* EMA 9 timing and the reaction candle
* ATR-based limits
* break-even at +1R
* sessions and news blackout
* spread filter
* **0.25% risk per trade**
* daily loss limit of 2% and daily profit boundary of 3%
* account equity-drawdown halt at 10%
* **one position at a time**.

### Scalp M5: exact rules
Evaluated once per closed **M5** candle:
1. **Trend (M15):**
   * BUY: close > EMA 200 and EMA 50 > EMA 200.
   * SELL: the mirror image.
   * Otherwise WAIT.
2. **Pullback:**
   * The last two M5 candles dipped to within 0.3 × ATR of the **M5 EMA 21**.
   * They didn't pierce it by more than 1 × ATR.
   * The last candle **closed back on the trend side** of EMA 21.
3. **Reaction candle:**
   * It closes in the trade direction and is at least half the ATR in size.
   * It's a rejection wick, an engulfing candle, or a strong candle.
4. **EMA 9:** the close is beyond the M5 EMA 9 in the trade direction.
5. **Checks:**
   * ATR ≥ 4 × spread, and no spike above 2 × the 24 h ATR average
   * entry within 1.5 × ATR of EMA 21
   * SL ≤ 2.5 × ATR
   * spread ≤ 5 pips
   * London or New York session
   * score ≥ 60
   * daily limits and cooldown OK
   * no open position.
6. **Entry:**
   * Market order at the next candle's open.
   * **SL** = the further of 1 × ATR and "beyond EMA 21 / the last two candles' extreme + 0.1 × ATR".
   * **TP** = 1.5 × the SL distance.
   * **Break-even** at +1R.

Every step is logged with `[OK]` / `[X]`, the same as in V3.

### Expected frequency (not verified)
In a trending London or New York session, M5 pullbacks to EMA 21 usually happen several times, so the scalp profile *should* take several trades on trending days.

It will take **none** when:
* the M15 trend is mixed
* price runs without pulling back
* spread is wide
* it's outside the session
* a daily limit or the cooldown is active.

The actual frequency is unknown until you run the tester (section 4).

---

## 3. Scalping and costs (read before judging results)

With a 1.5R target, the win rate needed just to break even is **40% before costs** (1 ÷ (1 + 1.5)). For example:
* the stop is about 40 pips (1 × M5 ATR) and the spread about 3.5 pips
* so the spread alone is about **9% of the risk on every trade**
* that pushes the real break-even win rate to about **44%**, and higher with commission and slippage.

Many scalping systems fail only because of costs. Always read the **"after estimated costs"** figures (`est`) in the report and the analyzer's **cost-sensitivity table**. Set `InpCommissionPerLot` to your broker's real commission.

---

## 4. How to test it (10 minutes)

**MetaQuotes-Demo only has real ticks from 2026-09-01**, so use 1-minute bars for longer tests.

1. Copy `MQL5/Experts/GoldBot/GoldBotV4.mq5` into `<Data Folder>/MQL5/Experts/GoldBot/`. Compile it with **F7** and check for 0 errors. If there are errors, send them to me.
2. Press **Ctrl+R** and set:
   * Expert `GoldBot\GoldBotV4`, Symbol XAUUSD, Timeframe M5
   * Modelling **1 minute OHLC**
   * Date **2025-01-01 → today**
   * Deposit **10000**
   * Inputs: `InpProfile = Scalp M5`, `InpReportTag = BT_scalp_2025`
3. Click **Start**.
   * **Backtest** tab: total trades, profit factor, drawdown.
   * **Journal** tab: the checklist for every setup.
   * The V4 statistics report at the end, plus `GoldBotV4_BT_scalp_2025_report.txt` and `_trades.csv` in `Common\Files`.
4. Run the same test with `InpProfile = Swing M15` (tag `BT_swing_2025`) to compare.
5. Analyze the results:
   ```
   python3 tools/analyze_trades.py GoldBotV4_BT_scalp_2025_trades.csv --split 2026-01-01
   python3 tools/analyze_trades.py GoldBotV4_BT_scalp_2025_trades.csv GoldBotV4_BT_swing_2025_trades.csv --compare
   ```
6. **If there are still 0 trades,** send me the tester Journal (the `.log` file), as before.

**Before trusting any result:**
* Use the out-of-sample split and cost sensitivity: `docs/README_V3.md` sections 11–15.
* Then run a demo forward test.
* Fill in `docs/TEST_REPORT_TEMPLATE.md`.

---

## 5. Running it on the demo account

It's the same process as V3:
1. Remove V3 from the chart first. Only one gold position is allowed on the account, so running both would make them block each other.
2. Open an **XAUUSD M5** chart. The EA reads its own timeframes, but M5 matches what it trades.
3. Attach **GoldBotV4**, tick **Allow Algo Trading**, and keep `InpProfile = Scalp M5`. Set `InpReportTag` (for example `DEMO_scalp`) and `InpCommissionPerLot`.

**Check it's running:**
* The dashboard says `XAUUSD V4 [SCALP M5]`.
* The Experts log shows `GoldBot V4 started - profile SCALP M5`.
* A new `[M5 ...]` line appears **every 5 minutes**.

---

## 6. Changed and new inputs

| Input | Default | Meaning |
|-------|---------|---------|
| `InpProfile` | Scalp M5 | Scalp M5 / Swing M15 / Custom |
| `InpEntryTF`, `InpTrendTF` | M15, H1 | [custom] Entry and trend timeframes (the trend TF must be ≥ the entry TF) |
| `InpZoneSource` | Swing | [custom] Swing S/R zones or EMA pullback |
| `InpPullbackEMA` | 21 | [custom] EMA used for pullbacks (must be longer than the timing EMA) |
| `InpZoneMergeATR` | 0.3 | Swing merge distance, × ATR |
| `InpZoneDistanceATR` | 0.3 | How close price must come to the zone or EMA, × ATR |
| `InpMaxDistanceFromZoneATR` | 1.5 | Don't chase: max entry distance, × ATR (0 = off) |
| `InpSLBufferATR` | 0.1 | SL buffer beyond the zone, × ATR |
| `InpMaxStopLossATR` | 2.5 | Max SL, × ATR. A larger SL means no trade. |
| `InpMinATRToSpread` | 4.0 | Skip if ATR < spread × this (0 = off) |
| `InpMaxATRSpikeRatio` | 2.0 | Skip if ATR > 24 h average × this (0 = off) |
| `InpMagicNumber` | 55200428 | V4 trades and statistics are kept separate from V1–V3 |

Removed (replaced by the ATR versions above): `InpZoneMergePips`, `InpZoneDistancePips`, `InpMaxDistanceFromZonePips`, `InpSLBufferPips`, `InpMaxStopLossPips`, `InpMinATRPips`, `InpMaxATRPips`.

**Unchanged from V3 (see `docs/README_V3.md` section 19):**
* direction switches, trend mode, confirmation mode, EMA 9, ATR period and regime filter
* SL mode, break-even, trailing, lot mode, risk %, lot cap
* cost assumptions, daily and account limits, spread, sessions, news blackout, reporting.

---

## 7. Safety: unchanged from V3

* Maximum **1** open gold position.
* One evaluation per closed candle, and the last traded signal candle is never traded again (stored across restarts).
* Lots are rounded down and never rounded up to the minimum. Commission is included in sizing, and margin is checked.
* Daily loss limit, consecutive-loss stop, max trades per day, cooldown after a loss, account equity-drawdown halt, and an emergency switch.
* No martingale, grid, averaging down, hedging or recovery trades.

---

## 8. Project files

```
MQL5/Experts/GoldBot/GoldBotV4.mq5    ← V4 (use this)
MQL5/Experts/GoldBot/GoldBotV3.mq5    ← V3 (its fixed-pip defaults are too tight for gold above ~$4,000)
MQL5/Experts/GoldBot/GoldBotV2.mq5, GoldBot.mq5  ← V2, V1
tools/analyze_trades.py               ← analyzer (works with V3 and V4 trade CSVs)
docs/README_V3.md                     ← full testing method, metrics, parameters (applies to V4)
docs/TEST_REPORT_TEMPLATE.md          ← test report template
docs/README_V2.md, docs/README_V1.md  ← older documentation
```

## 9. Known limitations

* **Not compiled or backtested here.** The scalp frequency and results are unknown until you run the tester.
* **M5 scalping is more sensitive** to spread, slippage and execution delay than M15. Demo fills can be better than real ones.
* **1-minute OHLC modelling** approximates prices inside each minute. Confirm on real-tick data where available.
* **Profile values are reasonable defaults, not optimized values.** Test neighbours before changing them: RR 1.0 / 1.5 / 2.0, pullback EMA 20 / 21 / 30.
* All V3 limitations still apply (`docs/README_V3.md` section 20).
