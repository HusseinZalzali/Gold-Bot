//+------------------------------------------------------------------+
//|                                                     GoldBot.mq5  |
//|             Simple rule-based XAUUSD Expert Advisor - Version 1  |
//|                                                                  |
//|  Strategy (all three are REQUIRED before a trade can happen):    |
//|    1. Trend        : H1 EMA 55 / EMA 200 direction               |
//|    2. Zone         : M15 price touches a recent swing S/R level  |
//|    3. Confirmation : simple M15 price-action candle              |
//|                                                                  |
//|  Risk rules: fixed SL/TP, 1 position max, daily loss limit,      |
//|  consecutive-loss limit, max trades per day, spread filter,      |
//|  trading hours, optional manual news blackout.                   |
//|                                                                  |
//|  NO martingale, NO grid, NO averaging down, NO hedging,          |
//|  NO lot increase after losses.                                   |
//|                                                                  |
//|  FOR DEMO TESTING. No profitability is implied or guaranteed.    |
//+------------------------------------------------------------------+
#property copyright   "GoldBot V1"
#property version     "1.00"
#property description "Simple rule-based XAUUSD EA: H1 EMA trend + M15 swing support/resistance + candle confirmation."
#property description "Fixed SL/TP, one position at a time, strict daily risk limits. For demo testing only."

#include <Trade/Trade.mqh>

//+------------------------------------------------------------------+
//| Enumerations                                                     |
//+------------------------------------------------------------------+
enum ENUM_LOT_MODE
  {
   LOT_MODE_RISK  = 0,   // Risk-based (% of balance)
   LOT_MODE_FIXED = 1    // Fixed lot size
  };

enum ENUM_TREND_STATE
  {
   TREND_NEUTRAL = 0,
   TREND_BULLISH = 1,
   TREND_BEARISH = 2
  };

enum ENUM_SETUP_STATE
  {
   SETUP_WAITING = 0,
   SETUP_BUY     = 1,
   SETUP_SELL    = 2
  };

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
input group "=== Symbol ==="
input string          InpSymbol              = "";        // Symbol (empty = chart symbol / auto-detect XAUUSD)
input double          InpPipSize             = 0.0;       // Price value of 1 pip (0 = auto: 0.10 for gold)

input group "=== Trend filter (H1) ==="
input int             InpFastEMAPeriod       = 55;        // Fast EMA period (H1)
input int             InpSlowEMAPeriod       = 200;       // Slow EMA period (H1)

input group "=== Support / Resistance (M15) ==="
input int             InpSwingStrength       = 3;         // Swing strength (bars on each side of a swing point)
input int             InpSwingLookbackBars   = 100;       // How many M15 bars back to search for swings
input double          InpZoneTolerancePips   = 10.0;      // How close price must come to the level (pips)
input double          InpMinCandleRangePips  = 10.0;      // Minimum confirmation candle size high-low (pips)

input group "=== Stop Loss / Take Profit ==="
input double          InpStopLossPips        = 25.0;      // Stop Loss (pips)
input double          InpTakeProfitPips      = 125.0;     // Take Profit (pips)
input bool            InpUseWiderStopLoss    = false;     // Use the wider test Stop Loss below instead
input double          InpWiderStopLossPips   = 40.0;      // Wider Stop Loss for testing (pips)

input group "=== Position size ==="
input ENUM_LOT_MODE   InpLotMode             = LOT_MODE_RISK; // Lot size mode
input double          InpRiskPercent         = 0.25;      // Risk per trade (% of balance) - risk mode
input double          InpFixedLotSize        = 0.01;      // Fixed lot size - fixed mode
input double          InpMaxLotSize          = 1.00;      // Safety cap: never trade more than this lot size

input group "=== Daily protection ==="
input double          InpMaxDailyLossPercent = 2.0;       // Max daily loss, realized + floating (% of day-start balance)
input int             InpMaxConsecutiveLosses= 3;         // Stop for the day after this many losses in a row
input int             InpMaxTradesPerDay     = 3;         // Max new trades per day

input group "=== Execution ==="
input double          InpMaxSpreadPips       = 5.0;       // Max allowed spread (pips)
input double          InpMaxSlippagePips     = 3.0;       // Max allowed slippage (pips)
input ulong           InpMagicNumber         = 55200125;  // Magic number (identifies this EA's trades)
input string          InpTradeComment        = "GoldBot V1"; // Order comment

input group "=== Trading hours (broker/server time) ==="
input int             InpStartHour           = 8;         // Trading start hour
input int             InpStartMinute         = 0;         // Trading start minute
input int             InpEndHour             = 20;        // Trading end hour (end time is exclusive)
input int             InpEndMinute           = 0;         // Trading end minute

input group "=== Manual news blackout (server time) ==="
input bool            InpNewsFilterEnabled   = false;     // Enable manual news blackout
input int             InpNewsStartHour       = 14;        // Blackout start hour
input int             InpNewsStartMinute     = 15;        // Blackout start minute
input int             InpNewsEndHour         = 15;        // Blackout end hour
input int             InpNewsEndMinute       = 0;         // Blackout end minute

input group "=== Display / logging ==="
input bool            InpShowDashboard       = true;      // Show dashboard on chart
input bool            InpVerboseLog          = true;      // Log a NO TRADE reason on every closed M15 candle

//+------------------------------------------------------------------+
//| Constants (fixed by design in V1)                                |
//+------------------------------------------------------------------+
#define MAX_OPEN_POSITIONS   1     // Only one XAUUSD position at a time - never stack
#define MAX_SEND_ATTEMPTS    2     // One retry only, and only for requote/price-changed errors

// Confirmation candle shape thresholds (fractions of the candle's high-low range)
const double REJECTION_WICK_MIN      = 0.50;  // rejection wick must be >= 50% of the range
const double REJECTION_OPPOSITE_MAX  = 0.25;  // opposite wick must be <= 25% of the range
const double STRONG_BODY_MIN         = 0.60;  // strong candle body must be >= 60% of the range
const double STRONG_CLOSE_ZONE       = 0.20;  // strong candle must close within 20% of its extreme
const double MARGIN_USAGE_MAX        = 0.90;  // never use more than 90% of free margin for one trade

//+------------------------------------------------------------------+
//| Data structures                                                  |
//+------------------------------------------------------------------+
struct DailyStats
  {
   int               tradesToday;        // new positions opened today (this EA, this symbol)
   int               closedToday;        // positions closed today
   double            realizedPL;         // closed P/L today incl. swap/commission
   double            floatingPL;         // open P/L now
   int               consecutiveLosses;  // losing closes in a row today
  };

struct SetupInfo
  {
   bool              valid;
   double            zoneLevel;          // support (buy) or resistance (sell) price
   string            confirmation;       // name of the confirmation pattern
   string            failReason;         // why the setup is not valid
  };

//+------------------------------------------------------------------+
//| Global state                                                     |
//+------------------------------------------------------------------+
CTrade            g_trade;
string            g_symbol          = "";
double            g_point           = 0.0;
double            g_pipSize         = 0.0;
int               g_digits          = 0;
int               g_fastEmaHandle   = INVALID_HANDLE;
int               g_slowEmaHandle   = INVALID_HANDLE;
bool              g_isFastTester    = false;   // tester without visual mode: skip dashboard work

datetime          g_lastBarTime     = 0;       // open time of the current M15 bar already processed
string            g_candleLabel     = "";      // used as a log prefix

datetime          g_currentDay      = 0;       // start (00:00 server time) of the tracked day
double            g_dayStartBalance = 0.0;
bool              g_tradingStopped  = false;   // latched for the rest of the day
string            g_stopReason      = "";
DailyStats        g_stats;

ENUM_TREND_STATE  g_trend           = TREND_NEUTRAL;
ENUM_SETUP_STATE  g_setupState      = SETUP_WAITING;
string            g_lastDecision    = "Waiting for the next closed M15 candle";
datetime          g_lastDashUpdate  = 0;

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
  {
   g_symbol = ResolveSymbol();
   if(g_symbol == "")
     {
      Print("INIT FAILED: could not find a gold (XAUUSD) symbol. Set the 'Symbol' input to your broker's gold symbol name.");
      return(INIT_FAILED);
     }
   if(g_symbol != _Symbol)
      Print("WARNING: EA is attached to ", _Symbol, " but trades ", g_symbol,
            ". Attach it to a ", g_symbol, " chart so it receives the correct ticks.");

   if(!ValidateInputs())
      return(INIT_PARAMETERS_INCORRECT);

   g_point  = SymbolInfoDouble(g_symbol, SYMBOL_POINT);
   g_digits = (int)SymbolInfoInteger(g_symbol, SYMBOL_DIGITS);
   if(g_point <= 0.0)
     {
      Print("INIT FAILED: invalid point size for ", g_symbol);
      return(INIT_FAILED);
     }
   if(InpPipSize <= 0.0 && !IsGoldSymbol(g_symbol))
     {
      Print("INIT FAILED: '", g_symbol, "' is not recognised as gold, so the pip size cannot be detected safely. ",
            "Set 'Price value of 1 pip' manually (0.10 is the usual gold pip).");
      return(INIT_PARAMETERS_INCORRECT);
     }
   g_pipSize = DeterminePipSize();
   if(g_pipSize < g_point)
     {
      Print("INIT FAILED: pip size ", DoubleToString(g_pipSize, 5), " is smaller than the symbol point ",
            DoubleToString(g_point, g_digits), ". Check the 'Price value of 1 pip' input.");
      return(INIT_PARAMETERS_INCORRECT);
     }

   g_fastEmaHandle = iMA(g_symbol, PERIOD_H1, InpFastEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_slowEmaHandle = iMA(g_symbol, PERIOD_H1, InpSlowEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   if(g_fastEmaHandle == INVALID_HANDLE || g_slowEmaHandle == INVALID_HANDLE)
     {
      Print("INIT FAILED: could not create EMA indicators. Error ", GetLastError());
      return(INIT_FAILED);
     }

   g_trade.SetExpertMagicNumber(InpMagicNumber);
   long deviationPoints = (long)MathRound(PipsToPrice(InpMaxSlippagePips) / g_point);
   if(deviationPoints < 1)
      deviationPoints = 1;
   g_trade.SetDeviationInPoints((ulong)deviationPoints);
   g_trade.SetTypeFillingBySymbol(g_symbol);
   g_trade.SetAsyncMode(false);          // synchronous: we know the result before continuing
   g_trade.LogLevel(LOG_LEVEL_ERRORS);

   g_isFastTester = (MQLInfoInteger(MQL_TESTER) != 0 && MQLInfoInteger(MQL_VISUAL_MODE) == 0);

   // Show the current trend right away (may stay NEUTRAL until H1 data has loaded)
   double h1Close = 0.0, emaFast = 0.0, emaSlow = 0.0;
   g_trend = GetTrend(h1Close, emaFast, emaSlow);

   // Do not act on a candle that closed before the EA was attached: wait for the next one.
   g_lastBarTime = iTime(g_symbol, PERIOD_M15, 0);

   ManageDailyLimits();
   PrintSettings();

   if(MQLInfoInteger(MQL_TESTER) == 0)
      EventSetTimer(2);                  // keeps the dashboard fresh when ticks are slow

   UpdateDashboard();
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   if(g_fastEmaHandle != INVALID_HANDLE)
      IndicatorRelease(g_fastEmaHandle);
   if(g_slowEmaHandle != INVALID_HANDLE)
      IndicatorRelease(g_slowEmaHandle);
   Comment("");
  }

//+------------------------------------------------------------------+
//| Tick handler - kept deliberately small                           |
//+------------------------------------------------------------------+
void OnTick()
  {
   if(IsNewM15Bar())
      EvaluateNewBar();

   if(InpShowDashboard && !g_isFastTester && TimeCurrent() - g_lastDashUpdate >= 5)
      UpdateDashboard();
  }

//+------------------------------------------------------------------+
//| Timer (live only): refresh dashboard                             |
//+------------------------------------------------------------------+
void OnTimer()
  {
   UpdateDashboard();
  }

//+------------------------------------------------------------------+
//| Log closed trades and refresh daily limits immediately           |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
  {
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
      return;
   if(!HistoryDealSelect(trans.deal))
      return;
   if(HistoryDealGetString(trans.deal, DEAL_SYMBOL) != g_symbol)
      return;
   if((ulong)HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != InpMagicNumber)
      return;

   ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY)
      return;

   double net = HistoryDealGetDouble(trans.deal, DEAL_PROFIT)
                + HistoryDealGetDouble(trans.deal, DEAL_SWAP)
                + HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);
   ENUM_DEAL_REASON dealReason = (ENUM_DEAL_REASON)HistoryDealGetInteger(trans.deal, DEAL_REASON);
   string how = "closed (manual/other)";
   if(dealReason == DEAL_REASON_SL)
      how = "hit Stop Loss";
   else
      if(dealReason == DEAL_REASON_TP)
         how = "hit Take Profit";
      else
         if(dealReason == DEAL_REASON_SO)
            how = "stopped out by broker (margin)";

   Print("TRADE CLOSED: ", g_symbol, " position #", HistoryDealGetInteger(trans.deal, DEAL_POSITION_ID),
         " ", how, " | Net result: ", DoubleToString(net, 2), " ", AccountInfoString(ACCOUNT_CURRENCY),
         (net < 0.0 ? " (LOSS)" : " (WIN/BREAKEVEN)"));

   ManageDailyLimits();   // may latch the daily stop and log why
   UpdateDashboard();
  }

//+------------------------------------------------------------------+
//| Main decision pipeline - runs once per closed M15 candle         |
//+------------------------------------------------------------------+
void EvaluateNewBar()
  {
   ManageDailyLimits();   // handles the new-day reset first
   g_setupState = SETUP_WAITING;

   datetime closedCandle = iTime(g_symbol, PERIOD_M15, 1);
   g_candleLabel = "[M15 " + TimeToString(closedCandle, TIME_DATE | TIME_MINUTES) + "] ";

   //--- Step 2: H1 trend
   double h1Close = 0.0, emaFast = 0.0, emaSlow = 0.0;
   g_trend = GetTrend(h1Close, emaFast, emaSlow);
   if(g_trend == TREND_NEUTRAL)
     {
      if(emaSlow <= 0.0)
         LogDecision("NO TRADE: H1 indicator data not ready yet.", false);
      else
         LogDecision(StringFormat("NO TRADE: H1 trend unclear (H1 close=%s, EMA%d=%s, EMA%d=%s).",
                                  FormatPrice(h1Close), InpFastEMAPeriod, FormatPrice(emaFast),
                                  InpSlowEMAPeriod, FormatPrice(emaSlow)), false);
      return;
     }

   //--- Steps 3 + 4: support/resistance zone and confirmation candle
   MqlRates rates[];
   if(!LoadM15Rates(rates))
     {
      LogDecision("NO TRADE: not enough M15 history loaded yet.", false);
      return;
     }

   bool isBuy = (g_trend == TREND_BULLISH);
   SetupInfo setup;
   if(isBuy)
      CheckBuySetup(rates, setup);
   else
      CheckSellSetup(rates, setup);

   if(!setup.valid)
     {
      LogDecision("NO TRADE: " + setup.failReason, false);
      return;
     }

   g_setupState = (isBuy ? SETUP_BUY : SETUP_SELL);
   string direction = (isBuy ? "BUY" : "SELL");
   string reason = StringFormat("%s H1 trend + %s at %s + %s",
                                (isBuy ? "Bullish" : "Bearish"),
                                (isBuy ? "support" : "resistance"),
                                FormatPrice(setup.zoneLevel),
                                setup.confirmation);
   string blocked = "";

   //--- Step 5: spread
   if(!CheckSpread(blocked))
     {
      LogDecision("NO TRADE: " + direction + " setup found but blocked - " + blocked, true);
      return;
     }
   //--- Step 6: daily risk limits
   if(!CheckRiskLimits(blocked))
     {
      LogDecision("NO TRADE: " + direction + " setup found but blocked - " + blocked, true);
      return;
     }
   //--- Step 7: trading hours / news blackout
   if(!CheckTradingTime(blocked))
     {
      LogDecision("NO TRADE: " + direction + " setup found but blocked - " + blocked, true);
      return;
     }
   //--- Step 8: existing positions
   if(!CheckNoOpenPosition(blocked))
     {
      LogDecision("NO TRADE: " + direction + " setup found but blocked - " + blocked, true);
      return;
     }
   //--- Broker / terminal permissions
   if(!CheckTradingAllowed(isBuy, blocked))
     {
      LogDecision("NO TRADE: " + direction + " setup found but blocked - " + blocked, true);
      return;
     }

   //--- Step 9: everything passed - open exactly one trade
   if(isBuy)
      OpenBuy(reason);
   else
      OpenSell(reason);

   UpdateDashboard();
  }

//+------------------------------------------------------------------+
//| New M15 candle detection                                         |
//+------------------------------------------------------------------+
bool IsNewM15Bar()
  {
   datetime barTime = iTime(g_symbol, PERIOD_M15, 0);
   if(barTime == 0)
      return(false);                     // history not ready
   if(g_lastBarTime == 0)
     {
      g_lastBarTime = barTime;           // first tick: remember bar, act on the next one
      return(false);
     }
   if(barTime == g_lastBarTime)
      return(false);
   g_lastBarTime = barTime;              // mark as processed BEFORE evaluating (one attempt per candle)
   return(true);
  }

//+------------------------------------------------------------------+
//| H1 trend from the last CLOSED H1 candle                          |
//+------------------------------------------------------------------+
ENUM_TREND_STATE GetTrend(double &h1Close, double &emaFast, double &emaSlow)
  {
   h1Close = 0.0;
   emaFast = 0.0;
   emaSlow = 0.0;

   double fastBuf[], slowBuf[], closeBuf[];
   if(CopyBuffer(g_fastEmaHandle, 0, 1, 1, fastBuf) != 1 ||
      CopyBuffer(g_slowEmaHandle, 0, 1, 1, slowBuf) != 1 ||
      CopyClose(g_symbol, PERIOD_H1, 1, 1, closeBuf) != 1)
      return(TREND_NEUTRAL);

   h1Close = closeBuf[0];
   emaFast = fastBuf[0];
   emaSlow = slowBuf[0];
   if(emaSlow <= 0.0 || emaFast <= 0.0)
     {
      emaSlow = 0.0;
      return(TREND_NEUTRAL);
     }

   if(h1Close > emaSlow && emaFast > emaSlow)
      return(TREND_BULLISH);
   if(h1Close < emaSlow && emaFast < emaSlow)
      return(TREND_BEARISH);
   return(TREND_NEUTRAL);
  }

//+------------------------------------------------------------------+
//| Load recent M15 candles. Index 0 = forming candle,               |
//| 1 = candle that just closed (confirmation), 2 = the one before.  |
//+------------------------------------------------------------------+
bool LoadM15Rates(MqlRates &rates[])
  {
   int needed = InpSwingLookbackBars + InpSwingStrength + 5;
   ArraySetAsSeries(rates, true);
   int copied = CopyRates(g_symbol, PERIOD_M15, 0, needed, rates);
   return(copied == needed);
  }

//+------------------------------------------------------------------+
//| Swing point detection (simple fractal)                           |
//| Newer bars are at lower indexes (series order).                  |
//+------------------------------------------------------------------+
bool IsSwingLow(const MqlRates &rates[], int i, int strength)
  {
   for(int k = 1; k <= strength; k++)
     {
      if(rates[i - k].low < rates[i].low)   // newer bar went lower
         return(false);
      if(rates[i + k].low <= rates[i].low)  // older bar as low or lower
         return(false);
     }
   return(true);
  }

bool IsSwingHigh(const MqlRates &rates[], int i, int strength)
  {
   for(int k = 1; k <= strength; k++)
     {
      if(rates[i - k].high > rates[i].high)
         return(false);
      if(rates[i + k].high >= rates[i].high)
         return(false);
     }
   return(true);
  }

//+------------------------------------------------------------------+
//| Nearest valid swing-low support BELOW refPrice.                  |
//| A level is ignored if a candle CLOSED below it after it formed   |
//| (it is broken). Returns 0 if none found.                         |
//| Only swings fully formed before the last 2 candles are used, so  |
//| the candles being tested cannot create their own level.          |
//+------------------------------------------------------------------+
double FindSupport(const MqlRates &rates[], double refPrice)
  {
   int strength = InpSwingStrength;
   int first    = strength + 3;          // right-side bars of the swing are all older than bar 2
   int last     = MathMin(InpSwingLookbackBars, ArraySize(rates) - strength - 1);
   double best  = 0.0;

   for(int i = first; i <= last; i++)
     {
      if(!IsSwingLow(rates, i, strength))
         continue;
      double level = rates[i].low;
      if(level >= refPrice)
         continue;
      if(IsLevelBrokenBelow(rates, i, level))
         continue;
      if(best == 0.0 || level > best)     // highest support below price = nearest
         best = level;
     }
   return(best);
  }

//+------------------------------------------------------------------+
//| Nearest valid swing-high resistance ABOVE refPrice. 0 = none.    |
//+------------------------------------------------------------------+
double FindResistance(const MqlRates &rates[], double refPrice)
  {
   int strength = InpSwingStrength;
   int first    = strength + 3;
   int last     = MathMin(InpSwingLookbackBars, ArraySize(rates) - strength - 1);
   double best  = 0.0;

   for(int i = first; i <= last; i++)
     {
      if(!IsSwingHigh(rates, i, strength))
         continue;
      double level = rates[i].high;
      if(level <= refPrice)
         continue;
      if(IsLevelBrokenAbove(rates, i, level))
         continue;
      if(best == 0.0 || level < best)     // lowest resistance above price = nearest
         best = level;
     }
   return(best);
  }

// Did any candle between the swing and the test candles close below the support?
bool IsLevelBrokenBelow(const MqlRates &rates[], int swingIndex, double level)
  {
   for(int j = swingIndex - 1; j >= 3; j--)
      if(rates[j].close < level)
         return(true);
   return(false);
  }

// Did any candle between the swing and the test candles close above the resistance?
bool IsLevelBrokenAbove(const MqlRates &rates[], int swingIndex, double level)
  {
   for(int j = swingIndex - 1; j >= 3; j--)
      if(rates[j].close > level)
         return(true);
   return(false);
  }

//+------------------------------------------------------------------+
//| BUY setup: price touched support + bullish confirmation          |
//+------------------------------------------------------------------+
bool CheckBuySetup(const MqlRates &rates[], SetupInfo &setup)
  {
   ResetSetup(setup);
   double tolerance = PipsToPrice(InpZoneTolerancePips);
   double close1    = rates[1].close;

   double support = FindSupport(rates, close1);
   if(support <= 0.0)
     {
      setup.failReason = "No valid recent swing-low support below price.";
      return(false);
     }

   // The last two closed candles must have come down to the support zone...
   double touchLow = MathMin(rates[1].low, rates[2].low);
   if(touchLow > support + tolerance)
     {
      setup.failReason = StringFormat("Price not near support (support=%s, recent low=%s, %.1f pips away, tolerance %.1f pips).",
                                      FormatPrice(support), FormatPrice(touchLow),
                                      (touchLow - support) / g_pipSize, InpZoneTolerancePips);
      return(false);
     }
   // ...but not have pierced it too deeply (that is a breakdown, not a bounce).
   if(touchLow < support - tolerance)
     {
      setup.failReason = StringFormat("Support at %s was broken (low %s is %.1f pips below it).",
                                      FormatPrice(support), FormatPrice(touchLow),
                                      (support - touchLow) / g_pipSize);
      return(false);
     }

   string pattern = "", detail = "";
   if(!CheckConfirmation(true, rates, support, pattern, detail))
     {
      setup.failReason = "No bullish confirmation at support " + FormatPrice(support) + " (" + detail + ").";
      return(false);
     }

   setup.valid        = true;
   setup.zoneLevel    = support;
   setup.confirmation = pattern;
   return(true);
  }

//+------------------------------------------------------------------+
//| SELL setup: price touched resistance + bearish confirmation      |
//+------------------------------------------------------------------+
bool CheckSellSetup(const MqlRates &rates[], SetupInfo &setup)
  {
   ResetSetup(setup);
   double tolerance = PipsToPrice(InpZoneTolerancePips);
   double close1    = rates[1].close;

   double resistance = FindResistance(rates, close1);
   if(resistance <= 0.0)
     {
      setup.failReason = "No valid recent swing-high resistance above price.";
      return(false);
     }

   double touchHigh = MathMax(rates[1].high, rates[2].high);
   if(touchHigh < resistance - tolerance)
     {
      setup.failReason = StringFormat("Price not near resistance (resistance=%s, recent high=%s, %.1f pips away, tolerance %.1f pips).",
                                      FormatPrice(resistance), FormatPrice(touchHigh),
                                      (resistance - touchHigh) / g_pipSize, InpZoneTolerancePips);
      return(false);
     }
   if(touchHigh > resistance + tolerance)
     {
      setup.failReason = StringFormat("Resistance at %s was broken (high %s is %.1f pips above it).",
                                      FormatPrice(resistance), FormatPrice(touchHigh),
                                      (touchHigh - resistance) / g_pipSize);
      return(false);
     }

   string pattern = "", detail = "";
   if(!CheckConfirmation(false, rates, resistance, pattern, detail))
     {
      setup.failReason = "No bearish confirmation at resistance " + FormatPrice(resistance) + " (" + detail + ").";
      return(false);
     }

   setup.valid        = true;
   setup.zoneLevel    = resistance;
   setup.confirmation = pattern;
   return(true);
  }

//+------------------------------------------------------------------+
//| Simple price-action confirmation on the candle that just closed  |
//| (rates[1]). ANY ONE of these is enough:                          |
//|   - engulfing candle                                             |
//|   - rejection candle (long wick into the zone)                   |
//|   - strong close (big body, closes near its extreme)             |
//+------------------------------------------------------------------+
bool CheckConfirmation(bool bullish, const MqlRates &rates[], double zoneLevel,
                       string &pattern, string &detail)
  {
   pattern = "";
   detail  = "";

   double open1  = rates[1].open;
   double high1  = rates[1].high;
   double low1   = rates[1].low;
   double close1 = rates[1].close;
   double open2  = rates[2].open;
   double close2 = rates[2].close;

   double range = high1 - low1;
   if(range < PipsToPrice(InpMinCandleRangePips))
     {
      detail = StringFormat("candle too small: %.1f pips < %.1f pips", range / g_pipSize, InpMinCandleRangePips);
      return(false);
     }

   double body      = MathAbs(close1 - open1);
   double upperWick = high1 - MathMax(open1, close1);
   double lowerWick = MathMin(open1, close1) - low1;
   double tolerance = PipsToPrice(InpZoneTolerancePips);

   if(bullish)
     {
      // 1. Bullish engulfing: previous candle bearish, current bullish body covers it
      if(close2 < open2 && close1 > open1 && close1 >= open2 && open1 <= close2)
        {
         pattern = "bullish engulfing candle";
         return(true);
        }
      // 2. Bullish rejection: long lower wick that reached the support zone
      if(lowerWick >= REJECTION_WICK_MIN * range && upperWick <= REJECTION_OPPOSITE_MAX * range &&
         low1 <= zoneLevel + tolerance)
        {
         pattern = "bullish rejection candle (long lower wick)";
         return(true);
        }
      // 3. Strong bullish close
      if(close1 > open1 && body >= STRONG_BODY_MIN * range && (high1 - close1) <= STRONG_CLOSE_ZONE * range)
        {
         pattern = "strong bullish close";
         return(true);
        }
      detail = "no engulfing, rejection or strong bullish close";
      return(false);
     }

   // Bearish mirror
   if(close2 > open2 && close1 < open1 && close1 <= open2 && open1 >= close2)
     {
      pattern = "bearish engulfing candle";
      return(true);
     }
   if(upperWick >= REJECTION_WICK_MIN * range && lowerWick <= REJECTION_OPPOSITE_MAX * range &&
      high1 >= zoneLevel - tolerance)
     {
      pattern = "bearish rejection candle (long upper wick)";
      return(true);
     }
   if(close1 < open1 && body >= STRONG_BODY_MIN * range && (close1 - low1) <= STRONG_CLOSE_ZONE * range)
     {
      pattern = "strong bearish close";
      return(true);
     }
   detail = "no engulfing, rejection or strong bearish close";
   return(false);
  }

//+------------------------------------------------------------------+
//| Spread filter                                                    |
//+------------------------------------------------------------------+
bool CheckSpread(string &reason)
  {
   double spreadPips = CurrentSpreadPips();
   if(spreadPips < 0.0)
     {
      reason = "no valid price quote.";
      return(false);
     }
   if(spreadPips > InpMaxSpreadPips)
     {
      reason = StringFormat("Spread too high (%.1f pips > max %.1f pips).", spreadPips, InpMaxSpreadPips);
      return(false);
     }
   return(true);
  }

double CurrentSpreadPips()
  {
   double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   if(ask <= 0.0 || bid <= 0.0 || g_pipSize <= 0.0)
      return(-1.0);
   return((ask - bid) / g_pipSize);
  }

//+------------------------------------------------------------------+
//| Daily limits: new-day reset, statistics, latching the stop       |
//+------------------------------------------------------------------+
void ManageDailyLimits()
  {
   datetime now   = TimeCurrent();
   datetime today = (datetime)(((long)now / 86400) * 86400);   // 00:00 server time

   if(today != g_currentDay)
     {
      bool firstRun   = (g_currentDay == 0);
      g_currentDay    = today;
      g_tradingStopped = false;
      g_stopReason    = "";
      CalculateDailyStats(g_stats);
      // Day-start balance = current balance minus what this EA already realized today
      g_dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE) - g_stats.realizedPL;
      Print(firstRun ? "Daily tracking started for " : "NEW TRADING DAY: counters reset for ",
            TimeToString(today, TIME_DATE), ". Day-start balance: ",
            DoubleToString(g_dayStartBalance, 2), " ", AccountInfoString(ACCOUNT_CURRENCY));
     }
   else
      CalculateDailyStats(g_stats);

   if(g_tradingStopped)
      return;                                                  // latched until tomorrow

   double lossLimit = g_dayStartBalance * InpMaxDailyLossPercent / 100.0;
   double dayPL     = g_stats.realizedPL + g_stats.floatingPL;

   if(lossLimit > 0.0 && dayPL <= -lossLimit)
      StopTradingForToday(StringFormat("Daily loss limit reached (today %.2f, limit -%.2f = %.2f%% of %.2f).",
                                       dayPL, lossLimit, InpMaxDailyLossPercent, g_dayStartBalance));
   else
      if(g_stats.consecutiveLosses >= InpMaxConsecutiveLosses)
         StopTradingForToday(StringFormat("Consecutive loss limit reached (%d losses in a row).",
                                          g_stats.consecutiveLosses));
      else
         if(g_stats.tradesToday >= InpMaxTradesPerDay)
            StopTradingForToday(StringFormat("Max trades per day reached (%d of %d).",
                                             g_stats.tradesToday, InpMaxTradesPerDay));
  }

void StopTradingForToday(const string reason)
  {
   if(g_tradingStopped)
      return;
   g_tradingStopped = true;
   g_stopReason     = reason;
   Print("DAILY TRADING STOPPED: ", reason, " No new trades until the next server day.");
  }

//+------------------------------------------------------------------+
//| Rebuild today's statistics from the account history.             |
//| Using history (not memory) keeps it correct after a restart.     |
//+------------------------------------------------------------------+
void CalculateDailyStats(DailyStats &stats)
  {
   stats.tradesToday       = 0;
   stats.closedToday       = 0;
   stats.realizedPL        = 0.0;
   stats.floatingPL        = 0.0;
   stats.consecutiveLosses = 0;

   // Entry costs (commission) per position so a "win" that is negative after costs counts as a loss
   long   entryPositionIds[];
   double entryCosts[];
   int    entryCount = 0;

   if(HistorySelect(g_currentDay, TimeCurrent() + 60))
     {
      int total = HistoryDealsTotal();
      for(int i = 0; i < total; i++)
        {
         ulong ticket = HistoryDealGetTicket(i);
         if(ticket == 0)
            continue;
         if(HistoryDealGetString(ticket, DEAL_SYMBOL) != g_symbol)
            continue;
         if((ulong)HistoryDealGetInteger(ticket, DEAL_MAGIC) != InpMagicNumber)
            continue;
         ENUM_DEAL_TYPE type = (ENUM_DEAL_TYPE)HistoryDealGetInteger(ticket, DEAL_TYPE);
         if(type != DEAL_TYPE_BUY && type != DEAL_TYPE_SELL)
            continue;

         ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(ticket, DEAL_ENTRY);
         double net = HistoryDealGetDouble(ticket, DEAL_PROFIT)
                      + HistoryDealGetDouble(ticket, DEAL_SWAP)
                      + HistoryDealGetDouble(ticket, DEAL_COMMISSION);
         stats.realizedPL += net;
         long positionId = HistoryDealGetInteger(ticket, DEAL_POSITION_ID);

         if(entry == DEAL_ENTRY_IN)
           {
            bool known = false;
            for(int k = 0; k < entryCount; k++)
               if(entryPositionIds[k] == positionId)
                 {
                  entryCosts[k] += net;   // extra fill of the same position
                  known = true;
                  break;
                 }
            if(known)
               continue;
            stats.tradesToday++;
            ArrayResize(entryPositionIds, entryCount + 1);
            ArrayResize(entryCosts, entryCount + 1);
            entryPositionIds[entryCount] = positionId;
            entryCosts[entryCount]       = net;
            entryCount++;
            continue;
           }

         if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY || entry == DEAL_ENTRY_INOUT)
           {
            stats.closedToday++;
            double tradeNet = net;
            for(int k = 0; k < entryCount; k++)
               if(entryPositionIds[k] == positionId)
                 {
                  tradeNet += entryCosts[k];
                  break;
                 }
            if(tradeNet < 0.0)
               stats.consecutiveLosses++;
            else
               stats.consecutiveLosses = 0;
           }
        }
     }
   else
      Print("WARNING: could not load today's trade history (error ", GetLastError(), ").");

   for(int p = PositionsTotal() - 1; p >= 0; p--)
     {
      ulong ticket = PositionGetTicket(p);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol)
         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;
      stats.floatingPL += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
     }
  }

//+------------------------------------------------------------------+
//| Risk gate used right before opening a trade                      |
//+------------------------------------------------------------------+
bool CheckRiskLimits(string &reason)
  {
   ManageDailyLimits();
   if(g_tradingStopped)
     {
      reason = "Daily trading stopped: " + g_stopReason;
      return(false);
     }
   if(AccountInfoDouble(ACCOUNT_BALANCE) <= 0.0)
     {
      reason = "Account balance is zero or negative.";
      return(false);
     }
   return(true);
  }

//+------------------------------------------------------------------+
//| Trading hours + manual news blackout (server time)               |
//+------------------------------------------------------------------+
bool CheckTradingTime(string &reason)
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int nowMin   = dt.hour * 60 + dt.min;
   int startMin = InpStartHour * 60 + InpStartMinute;
   int endMin   = InpEndHour * 60 + InpEndMinute;

   // start == end means "trade all day"
   if(startMin != endMin && !IsTimeInWindow(nowMin, startMin, endMin))
     {
      reason = StringFormat("Outside trading hours (now %02d:%02d, allowed %02d:%02d-%02d:%02d server time).",
                            dt.hour, dt.min, InpStartHour, InpStartMinute, InpEndHour, InpEndMinute);
      return(false);
     }

   if(InpNewsFilterEnabled)
     {
      int newsStart = InpNewsStartHour * 60 + InpNewsStartMinute;
      int newsEnd   = InpNewsEndHour * 60 + InpNewsEndMinute;
      if(IsTimeInWindow(nowMin, newsStart, newsEnd))
        {
         reason = StringFormat("News blackout period (%02d:%02d-%02d:%02d server time).",
                               InpNewsStartHour, InpNewsStartMinute, InpNewsEndHour, InpNewsEndMinute);
         return(false);
        }
     }
   return(true);
  }

// [start, end) window in minutes; supports windows that cross midnight. Empty if start == end.
bool IsTimeInWindow(int nowMin, int startMin, int endMin)
  {
   if(startMin == endMin)
      return(false);
   if(startMin < endMin)
      return(nowMin >= startMin && nowMin < endMin);
   return(nowMin >= startMin || nowMin < endMin);
  }

//+------------------------------------------------------------------+
//| Position limit: max 1 open position on the symbol (any magic,    |
//| so the EA never stacks on top of a manual gold trade either)     |
//+------------------------------------------------------------------+
int CountOpenPositions(int &ownCount)
  {
   int total = 0;
   ownCount  = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol)
         continue;
      total++;
      if((ulong)PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
         ownCount++;
     }
   return(total);
  }

bool CheckNoOpenPosition(string &reason)
  {
   int own = 0;
   int total = CountOpenPositions(own);
   if(total >= MAX_OPEN_POSITIONS)
     {
      reason = StringFormat("A %s position is already open (%d by this EA, %d other). Max %d at a time.",
                            g_symbol, own, total - own, MAX_OPEN_POSITIONS);
      return(false);
     }
   return(true);
  }

//+------------------------------------------------------------------+
//| Terminal / account / symbol permissions                          |
//+------------------------------------------------------------------+
bool CheckTradingAllowed(bool isBuy, string &reason)
  {
   if(MQLInfoInteger(MQL_TESTER) == 0)
     {
      if(TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) == 0)
        {
         reason = "Algo Trading is disabled in the terminal (toolbar button).";
         return(false);
        }
      if(MQLInfoInteger(MQL_TRADE_ALLOWED) == 0)
        {
         reason = "Live trading is not allowed for this EA (check 'Allow Algo Trading' in EA properties).";
         return(false);
        }
     }
   if(AccountInfoInteger(ACCOUNT_TRADE_ALLOWED) == 0 || AccountInfoInteger(ACCOUNT_TRADE_EXPERT) == 0)
     {
      reason = "Trading by Expert Advisors is not allowed on this account.";
      return(false);
     }
   ENUM_SYMBOL_TRADE_MODE mode = (ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(g_symbol, SYMBOL_TRADE_MODE);
   if(mode == SYMBOL_TRADE_MODE_DISABLED || mode == SYMBOL_TRADE_MODE_CLOSEONLY)
     {
      reason = "Symbol is not open for new trades (disabled / close-only).";
      return(false);
     }
   if((isBuy && mode == SYMBOL_TRADE_MODE_SHORTONLY) || (!isBuy && mode == SYMBOL_TRADE_MODE_LONGONLY))
     {
      reason = "Broker does not allow this trade direction on the symbol.";
      return(false);
     }
   return(true);
  }

//+------------------------------------------------------------------+
//| Lot size. Returns 0 (and a reason) if no valid lot exists.       |
//| The lot is always rounded DOWN, never up to the minimum.         |
//+------------------------------------------------------------------+
double CalculateLotSize(bool isBuy, double entry, double sl, double &riskMoney, string &reason)
  {
   riskMoney = 0.0;
   double minLot  = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_STEP);
   if(minLot <= 0.0 || maxLot <= 0.0 || lotStep <= 0.0)
     {
      reason = "Broker lot limits are unavailable.";
      return(0.0);
     }

   double lossPerLot = LossPerLot(isBuy, entry, sl);
   if(lossPerLot <= 0.0)
     {
      reason = "Could not calculate the money value of the stop loss (tick value unavailable).";
      return(0.0);
     }

   double rawLots;
   if(InpLotMode == LOT_MODE_FIXED)
      rawLots = InpFixedLotSize;
   else
     {
      double balance    = AccountInfoDouble(ACCOUNT_BALANCE);
      double riskBudget = balance * InpRiskPercent / 100.0;
      rawLots = riskBudget / lossPerLot;
     }

   double lots = FloorToStep(rawLots, lotStep);

   double cap = MathMin(maxLot, InpMaxLotSize);
   if(lots > cap)
     {
      Print(g_candleLabel, "NOTE: lot size ", DoubleToString(lots, 2), " capped to ", DoubleToString(cap, 2),
            " (broker max / 'Safety cap' input).");
      lots = FloorToStep(cap, lotStep);
     }

   if(lots < minLot)
     {
      reason = StringFormat("Calculated lot %.4f is below the broker minimum %.2f. "
                            "Risk is too small for this stop loss - trade skipped (lots are never rounded up).",
                            rawLots, minLot);
      return(0.0);
     }

   riskMoney = lots * lossPerLot;
   return(lots);
  }

// Money lost by 1.0 lot if price moves from entry to sl
double LossPerLot(bool isBuy, double entry, double sl)
  {
   double profit = 0.0;
   ENUM_ORDER_TYPE type = (isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
   if(OrderCalcProfit(type, g_symbol, 1.0, entry, sl, profit) && profit < 0.0)
      return(-profit);

   // Fallback: tick value maths
   double tickSize  = SymbolInfoDouble(g_symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(g_symbol, SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tickValue <= 0.0)
      tickValue = SymbolInfoDouble(g_symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tickSize <= 0.0 || tickValue <= 0.0)
      return(0.0);
   return(MathAbs(entry - sl) / tickSize * tickValue);
  }

double FloorToStep(double value, double step)
  {
   double floored = MathFloor(value / step + 1e-9) * step;
   return(NormalizeDouble(floored, StepDigits(step)));
  }

int StepDigits(double step)
  {
   int digits = 0;
   double s = step;
   while(digits < 8 && MathAbs(s - MathRound(s)) > 1e-8)
     {
      s *= 10.0;
      digits++;
     }
   return(digits);
  }

//+------------------------------------------------------------------+
//| Margin check                                                     |
//+------------------------------------------------------------------+
bool CheckMargin(bool isBuy, double lots, double price, string &reason)
  {
   double margin = 0.0;
   ENUM_ORDER_TYPE type = (isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
   if(!OrderCalcMargin(type, g_symbol, lots, price, margin))
     {
      reason = StringFormat("Could not calculate required margin (error %d).", GetLastError());
      return(false);
     }
   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(margin > freeMargin * MARGIN_USAGE_MAX)
     {
      reason = StringFormat("Not enough free margin (need %.2f, free %.2f).", margin, freeMargin);
      return(false);
     }
   return(true);
  }

//+------------------------------------------------------------------+
//| Order execution                                                  |
//+------------------------------------------------------------------+
bool OpenBuy(const string reason)
  {
   return(OpenTrade(true, reason));
  }

bool OpenSell(const string reason)
  {
   return(OpenTrade(false, reason));
  }

bool OpenTrade(bool isBuy, const string reason)
  {
   string direction = (isBuy ? "BUY" : "SELL");
   double slPips    = EffectiveStopLossPips();
   double slDist    = PipsToPrice(slPips);
   double tpDist    = PipsToPrice(InpTakeProfitPips);

   double minStopDist = (double)SymbolInfoInteger(g_symbol, SYMBOL_TRADE_STOPS_LEVEL) * g_point;

   for(int attempt = 1; attempt <= MAX_SEND_ATTEMPTS; attempt++)
     {
      // Duplicate guard: re-check right before every send attempt
      int own = 0;
      if(CountOpenPositions(own) >= MAX_OPEN_POSITIONS)
        {
         LogDecision("NO TRADE: " + direction + " aborted - a position is already open (duplicate protection).", true);
         return(false);
        }

      MqlTick tick;
      if(!SymbolInfoTick(g_symbol, tick) || tick.ask <= 0.0 || tick.bid <= 0.0)
        {
         LogDecision("NO TRADE: " + direction + " aborted - no valid price quote.", true);
         return(false);
        }

      // Broker minimum stop distance. The broker measures a BUY's SL from Bid (SELL's from Ask),
      // so the spread eats into it. We never silently change the SL - we skip instead.
      double spread = tick.ask - tick.bid;
      if(slDist - spread <= minStopDist || tpDist <= minStopDist)
        {
         LogDecision(StringFormat("NO TRADE: %s blocked - SL/TP distance is inside the broker's minimum stop level (%.1f pips + %.1f pips spread).",
                                  direction, minStopDist / g_pipSize, spread / g_pipSize), true);
         return(false);
        }

      double entry = (isBuy ? tick.ask : tick.bid);
      double sl    = NormalizePrice(isBuy ? entry - slDist : entry + slDist);
      double tp    = NormalizePrice(isBuy ? entry + tpDist : entry - tpDist);

      double riskMoney = 0.0;
      string lotReason = "";
      double lots = CalculateLotSize(isBuy, entry, sl, riskMoney, lotReason);
      if(lots <= 0.0)
        {
         LogDecision("NO TRADE: " + direction + " blocked - " + lotReason, true);
         return(false);
        }

      string marginReason = "";
      if(!CheckMargin(isBuy, lots, entry, marginReason))
        {
         LogDecision("NO TRADE: " + direction + " blocked - " + marginReason, true);
         return(false);
        }

      bool sent = (isBuy ? g_trade.Buy(lots, g_symbol, entry, sl, tp, InpTradeComment)
                         : g_trade.Sell(lots, g_symbol, entry, sl, tp, InpTradeComment));
      uint retcode = g_trade.ResultRetcode();

      if(sent && (retcode == TRADE_RETCODE_DONE || retcode == TRADE_RETCODE_DONE_PARTIAL || retcode == TRADE_RETCODE_PLACED))
        {
         double fill    = g_trade.ResultPrice();
         double balance = AccountInfoDouble(ACCOUNT_BALANCE);
         Print(g_candleLabel, "TRADE: ", direction, " ", g_symbol);
         Print("   Reason: ", reason, ".");
         Print(StringFormat("   Lots=%.2f  Entry=%s  SL=%s (%.1f pips)  TP=%s (%.1f pips)  Risk~%.2f %s (%.2f%% of balance)  Deal #%s",
                            g_trade.ResultVolume(), FormatPrice(fill > 0.0 ? fill : entry),
                            FormatPrice(sl), slPips, FormatPrice(tp), InpTakeProfitPips,
                            riskMoney, AccountInfoString(ACCOUNT_CURRENCY),
                            (balance > 0.0 ? riskMoney / balance * 100.0 : 0.0), (string)g_trade.ResultDeal()));
         g_lastDecision = "TRADE: " + direction + " - " + reason;
         return(true);
        }

      Print(g_candleLabel, "ORDER ERROR: ", direction, " attempt ", attempt, "/", MAX_SEND_ATTEMPTS,
            " failed. Retcode ", retcode, " (", g_trade.ResultRetcodeDescription(), "), last error ", GetLastError(),
            ". Lots=", DoubleToString(lots, 2), " Price=", FormatPrice(entry),
            " SL=", FormatPrice(sl), " TP=", FormatPrice(tp));

      if(!IsRetryableRetcode(retcode))
         break;
     }

   g_lastDecision = "ORDER FAILED: " + direction + " (see Experts log)";
   return(false);
  }

// Only price-movement errors are retried; everything else is reported and skipped.
bool IsRetryableRetcode(uint retcode)
  {
   return(retcode == TRADE_RETCODE_REQUOTE ||
          retcode == TRADE_RETCODE_PRICE_CHANGED ||
          retcode == TRADE_RETCODE_PRICE_OFF);
  }

//+------------------------------------------------------------------+
//| Dashboard                                                        |
//+------------------------------------------------------------------+
void UpdateDashboard()
  {
   if(!InpShowDashboard || g_isFastTester)
      return;
   g_lastDashUpdate = TimeCurrent();
   ManageDailyLimits();

   string trendText = "NEUTRAL";
   if(g_trend == TREND_BULLISH)
      trendText = "BULLISH";
   else
      if(g_trend == TREND_BEARISH)
         trendText = "BEARISH";

   string setupText = "WAITING";
   if(g_setupState == SETUP_BUY)
      setupText = "BUY SETUP";
   else
      if(g_setupState == SETUP_SELL)
         setupText = "SELL SETUP";

   double dayPL    = g_stats.realizedPL + g_stats.floatingPL;
   double dayPLPct = (g_dayStartBalance > 0.0 ? dayPL / g_dayStartBalance * 100.0 : 0.0);
   double spread   = CurrentSpreadPips();
   string currency = AccountInfoString(ACCOUNT_CURRENCY);

   string lotText = (InpLotMode == LOT_MODE_RISK)
                    ? StringFormat("Risk %.2f%% per trade", InpRiskPercent)
                    : StringFormat("Fixed %.2f lots", InpFixedLotSize);

   string text = "XAUUSD BOT  (" + g_symbol + ")\n";
   text += "------------------------------\n";
   text += "Trend (H1): " + trendText + "\n";
   text += "Current Setup: " + setupText + "\n";
   text += StringFormat("Today's Trades: %d / %d\n", g_stats.tradesToday, InpMaxTradesPerDay);
   text += StringFormat("Today's P/L: %.2f %s (%.2f%%)\n", dayPL, currency, dayPLPct);
   text += StringFormat("Consecutive Losses: %d / %d\n", g_stats.consecutiveLosses, InpMaxConsecutiveLosses);
   text += "Daily Trading: " + (g_tradingStopped ? "STOPPED" : "ENABLED") + "\n";
   if(g_tradingStopped)
      text += "  Reason: " + g_stopReason + "\n";
   text += (spread >= 0.0 ? StringFormat("Current Spread: %.1f pips (max %.1f)\n", spread, InpMaxSpreadPips)
                          : "Current Spread: n/a\n");
   text += StringFormat("SL: %.1f pips | TP: %.1f pips\n", EffectiveStopLossPips(), InpTakeProfitPips);
   text += "Lots: " + lotText + "\n";
   text += "------------------------------\n";
   text += "Last: " + g_lastDecision;

   Comment(text);
  }

//+------------------------------------------------------------------+
//| Helpers                                                          |
//+------------------------------------------------------------------+
void LogDecision(const string text, bool important)
  {
   g_lastDecision = text;
   if(important || InpVerboseLog)
      Print(g_candleLabel, text);
  }

void ResetSetup(SetupInfo &setup)
  {
   setup.valid        = false;
   setup.zoneLevel    = 0.0;
   setup.confirmation = "";
   setup.failReason   = "";
  }

double PipsToPrice(double pips)
  {
   return(pips * g_pipSize);
  }

double EffectiveStopLossPips()
  {
   return(InpUseWiderStopLoss ? InpWiderStopLossPips : InpStopLossPips);
  }

double NormalizePrice(double price)
  {
   double tickSize = SymbolInfoDouble(g_symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize > 0.0)
      price = MathRound(price / tickSize) * tickSize;
   return(NormalizeDouble(price, g_digits));
  }

string FormatPrice(double price)
  {
   return(DoubleToString(price, g_digits));
  }

bool IsGoldSymbol(const string name)
  {
   string upper = name;
   StringToUpper(upper);
   return(StringFind(upper, "XAUUSD") >= 0 || StringFind(upper, "GOLD") == 0);
  }

//+------------------------------------------------------------------+
//| Symbol resolution: input -> chart symbol -> search for gold      |
//+------------------------------------------------------------------+
string ResolveSymbol()
  {
   if(StringLen(InpSymbol) > 0)
     {
      if(SymbolSelect(InpSymbol, true))
         return(InpSymbol);
      Print("Symbol '", InpSymbol, "' not found at this broker.");
      return("");
     }

   if(IsGoldSymbol(_Symbol))
      return(_Symbol);

   // Search Market Watch first, then all broker symbols
   for(int pass = 0; pass < 2; pass++)
     {
      bool onlySelected = (pass == 0);
      int total = SymbolsTotal(onlySelected);
      for(int i = 0; i < total; i++)
        {
         string name = SymbolName(i, onlySelected);
         if(IsGoldSymbol(name) && SymbolSelect(name, true))
            return(name);
        }
     }
   return("");
  }

//+------------------------------------------------------------------+
//| Pip size. Gold convention: 1 pip = 0.10 in price (e.g. 2350.00   |
//| -> 2350.10), independent of how many digits the broker quotes.   |
//+------------------------------------------------------------------+
double DeterminePipSize()
  {
   if(InpPipSize > 0.0)
      return(InpPipSize);
   return(0.10);   // OnInit only reaches here for recognised gold symbols
  }

//+------------------------------------------------------------------+
//| Input validation                                                 |
//+------------------------------------------------------------------+
bool ValidateInputs()
  {
   bool ok = true;
   if(InpFastEMAPeriod <= 0 || InpSlowEMAPeriod <= 0 || InpFastEMAPeriod >= InpSlowEMAPeriod)
     { Print("INPUT ERROR: EMA periods must be > 0 and fast < slow."); ok = false; }
   if(InpSwingStrength < 1 || InpSwingStrength > 10)
     { Print("INPUT ERROR: Swing strength must be between 1 and 10."); ok = false; }
   if(InpSwingLookbackBars < InpSwingStrength * 2 + 5 || InpSwingLookbackBars > 1000)
     { Print("INPUT ERROR: Swing lookback must be between (2 x strength + 5) and 1000 bars."); ok = false; }
   if(InpZoneTolerancePips < 0.0 || InpMinCandleRangePips < 0.0)
     { Print("INPUT ERROR: Zone tolerance and minimum candle range cannot be negative."); ok = false; }
   if(InpStopLossPips <= 0.0 || InpTakeProfitPips <= 0.0 || InpWiderStopLossPips <= 0.0)
     { Print("INPUT ERROR: Stop Loss and Take Profit must be greater than 0."); ok = false; }
   if(InpRiskPercent <= 0.0 || InpRiskPercent > 5.0)
     { Print("INPUT ERROR: Risk per trade must be > 0 and <= 5%."); ok = false; }
   if(InpMaxLotSize <= 0.0)
     { Print("INPUT ERROR: Safety lot cap must be greater than 0."); ok = false; }
   if(InpFixedLotSize <= 0.0 || InpFixedLotSize > InpMaxLotSize)
     { Print("INPUT ERROR: Fixed lot must be > 0 and not above the safety lot cap (", DoubleToString(InpMaxLotSize, 2), ")."); ok = false; }
   if(InpMaxDailyLossPercent <= 0.0 || InpMaxDailyLossPercent > 100.0)
     { Print("INPUT ERROR: Max daily loss must be between 0 and 100%."); ok = false; }
   if(InpMaxConsecutiveLosses < 1 || InpMaxTradesPerDay < 1)
     { Print("INPUT ERROR: Max consecutive losses and max trades per day must be at least 1."); ok = false; }
   if(InpMaxSpreadPips <= 0.0 || InpMaxSlippagePips < 0.0)
     { Print("INPUT ERROR: Max spread must be > 0 and slippage cannot be negative."); ok = false; }
   if(!IsValidTime(InpStartHour, InpStartMinute) || !IsValidTime(InpEndHour, InpEndMinute) ||
      !IsValidTime(InpNewsStartHour, InpNewsStartMinute) || !IsValidTime(InpNewsEndHour, InpNewsEndMinute))
     { Print("INPUT ERROR: Hours must be 0-23 and minutes 0-59."); ok = false; }
   if(InpPipSize < 0.0)
     { Print("INPUT ERROR: Pip size cannot be negative (use 0 for automatic)."); ok = false; }

   if(ok && InpTakeProfitPips <= EffectiveStopLossPips())
      Print("WARNING: Take Profit is not larger than Stop Loss. This is not the intended V1 design.");
   return(ok);
  }

bool IsValidTime(int hour, int minute)
  {
   return(hour >= 0 && hour <= 23 && minute >= 0 && minute <= 59);
  }

//+------------------------------------------------------------------+
//| Startup summary - verify the pip conversion here!                |
//+------------------------------------------------------------------+
void PrintSettings()
  {
   double slPips = EffectiveStopLossPips();
   Print("================ GoldBot V1 started ================");
   Print("Symbol: ", g_symbol, " | Digits: ", g_digits, " | Point: ", DoubleToString(g_point, g_digits),
         " | Contract size: ", DoubleToString(SymbolInfoDouble(g_symbol, SYMBOL_TRADE_CONTRACT_SIZE), 2));
   Print(StringFormat("1 pip = %s price = %.1f points%s",
                      DoubleToString(g_pipSize, (g_digits > 2 ? g_digits : 2)), g_pipSize / g_point,
                      (InpPipSize > 0.0 ? " (manual)" : " (auto)")));
   Print(StringFormat("SL: %.1f pips = %s price%s | TP: %.1f pips = %s price | R:R = 1:%.1f",
                      slPips, DoubleToString(PipsToPrice(slPips), g_digits),
                      (InpUseWiderStopLoss ? " (WIDER test SL)" : ""),
                      InpTakeProfitPips, DoubleToString(PipsToPrice(InpTakeProfitPips), g_digits),
                      InpTakeProfitPips / slPips));
   Print("Lots: min ", DoubleToString(SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MIN), 2),
         " / max ", DoubleToString(SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MAX), 2),
         " / step ", DoubleToString(SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_STEP), 2),
         " | Mode: ", (InpLotMode == LOT_MODE_RISK ? StringFormat("RISK %.2f%%", InpRiskPercent)
                                                  : StringFormat("FIXED %.2f", InpFixedLotSize)),
         " | Safety cap: ", DoubleToString(InpMaxLotSize, 2));

   double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   if(bid > 0.0)
     {
      double lossPerLot = LossPerLot(false, bid, bid + PipsToPrice(slPips));
      if(lossPerLot > 0.0)
         Print(StringFormat("Money at risk per 1.00 lot with this SL: %.2f %s (0.01 lot: %.2f)",
                            lossPerLot, AccountInfoString(ACCOUNT_CURRENCY), lossPerLot / 100.0));
     }
   Print(StringFormat("Daily limits: max loss %.2f%% | max %d consecutive losses | max %d trades/day | max spread %.1f pips",
                      InpMaxDailyLossPercent, InpMaxConsecutiveLosses, InpMaxTradesPerDay, InpMaxSpreadPips));
   Print(StringFormat("Trading hours: %02d:%02d-%02d:%02d server time | News blackout: %s",
                      InpStartHour, InpStartMinute, InpEndHour, InpEndMinute,
                      (InpNewsFilterEnabled ? StringFormat("%02d:%02d-%02d:%02d", InpNewsStartHour, InpNewsStartMinute,
                                                           InpNewsEndHour, InpNewsEndMinute) : "off")));
   Print("Setups are evaluated once per closed M15 candle. Max open positions: ", MAX_OPEN_POSITIONS);
   Print("====================================================");
  }
//+------------------------------------------------------------------+
