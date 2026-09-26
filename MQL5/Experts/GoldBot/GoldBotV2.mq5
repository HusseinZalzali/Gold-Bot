//+------------------------------------------------------------------+
//|                                                   GoldBotV2.mq5  |
//|             Simple rule-based XAUUSD Expert Advisor - Version 2  |
//|                                                                  |
//|  Core (unchanged from V1, all REQUIRED):                         |
//|    1. Trend        : H1 EMA 55 / EMA 200                         |
//|    2. Zone         : M15 swing support/resistance zone           |
//|    3. Reaction     : M15 candle rejects the zone, closes with    |
//|                      the trend                                   |
//|                                                                  |
//|  Added in V2:                                                    |
//|    - zones built from several nearby swing reactions             |
//|    - EMA 9 (M15) entry timing, ATR (M15) volatility filter       |
//|    - fixed or ATR stop loss, placed beyond the zone, capped      |
//|    - take profit as a risk:reward multiple                       |
//|    - break-even, optional ATR trailing stop                      |
//|    - sessions, daily profit boundary, cooldown after a loss      |
//|    - BUY/SELL switches, simple 0-100 quality score               |
//|    - "no chasing" distance rule, checklist logging               |
//|    - statistics (overall, BUY/SELL, per session) + CSV export    |
//|                                                                  |
//|  NO martingale, NO grid, NO averaging down, NO hedging,          |
//|  NO recovery logic, NO lot increase after losses.                |
//|                                                                  |
//|  FOR DEMO TESTING. No profitability is implied or guaranteed.    |
//+------------------------------------------------------------------+
#property copyright   "GoldBot V2"
#property version     "2.00"
#property description "Rule-based XAUUSD EA: H1 EMA trend + M15 S/R zone + candle reaction + EMA9 timing + ATR filter."
#property description "ATR/fixed SL beyond the zone, R-multiple TP, break-even, sessions, strict daily limits, statistics."
#property description "For demo testing only. No profitability is implied."

#include <Trade/Trade.mqh>

//+------------------------------------------------------------------+
//| Enumerations                                                     |
//+------------------------------------------------------------------+
enum ENUM_LOT_MODE
  {
   LOT_MODE_RISK  = 0,   // Risk-based (% of balance/equity, whichever is lower)
   LOT_MODE_FIXED = 1    // Fixed lot size
  };

enum ENUM_SL_MODE
  {
   SL_MODE_FIXED = 0,    // Fixed pips
   SL_MODE_ATR   = 1     // ATR x multiplier
  };

enum ENUM_SESSION_MODE
  {
   SESSION_LONDON    = 0, // London
   SESSION_NEWYORK   = 1, // New York
   SESSION_LONDON_NY = 2, // London + New York
   SESSION_CUSTOM    = 3  // Custom
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
input string            InpSymbol                 = "";          // Symbol (empty = chart symbol / auto-detect gold)
input double            InpPipSize                = 0.0;         // Price value of 1 pip (0 = auto: 0.10 for gold)

input group "=== Direction ==="
input bool              InpAllowBuy               = true;        // Allow BUY trades
input bool              InpAllowSell              = true;        // Allow SELL trades

input group "=== Trend (H1) ==="
input int               InpTrendFastEMA           = 55;          // Trend fast EMA (H1)
input int               InpTrendSlowEMA           = 200;         // Trend slow EMA (H1)

input group "=== Entry timing and volatility (M15) ==="
input int               InpEntryEMA               = 9;           // Entry timing EMA (M15)
input bool              InpRequireEMAConfirm      = true;        // Require close beyond entry EMA (else score only)
input int               InpATRPeriod              = 14;          // ATR period (M15)
input double            InpMinATRPips             = 15.0;        // Minimum ATR - skip dead markets (pips)
input double            InpMaxATRPips             = 120.0;       // Maximum ATR - skip chaotic markets (pips, 0 = off)

input group "=== Support / resistance zones (M15) ==="
input int               InpSwingStrength          = 3;           // Swing strength (bars on each side)
input int               InpSwingLookbackBars      = 150;         // Bars searched for swings (150 M15 = ~37 hours)
input double            InpZoneMergePips          = 15.0;        // Swings closer than this form one zone (pips)
input double            InpZoneDistancePips       = 20.0;        // Price must come this close to the zone (pips)
input double            InpMaxDistanceFromZonePips= 30.0;        // Don't chase: max entry distance from zone (pips)

input group "=== Trade quality score ==="
input int               InpMinScore               = 70;          // Minimum score to trade (0-100)

input group "=== Stop loss / take profit ==="
input ENUM_SL_MODE      InpSLMode                 = SL_MODE_ATR; // Stop loss mode
input double            InpFixedSLPips            = 25.0;        // Fixed SL (pips) - fixed mode
input double            InpATRSLMultiplier        = 1.0;         // SL = ATR x this - ATR mode
input bool              InpUseStructureSL         = true;        // Place SL beyond the zone / reaction candle if further
input double            InpSLBufferPips           = 5.0;         // Extra distance beyond the zone (pips)
input double            InpMaxStopLossPips        = 80.0;        // Max SL - larger means NO TRADE (pips)
input double            InpRiskReward             = 4.0;         // Take profit = SL distance x this (R multiple)

input group "=== Trade management ==="
input bool              InpBreakEvenEnabled       = true;        // Move SL to break-even
input double            InpBreakEvenAtR           = 1.0;         // ...when profit reaches this many R
input double            InpBreakEvenBufferPips    = 2.0;         // Break-even SL offset beyond entry (pips)
input bool              InpTrailingEnabled        = false;       // Enable ATR trailing stop
input double            InpTrailStartR            = 2.0;         // Start trailing when profit reaches this many R
input double            InpTrailATRMultiplier     = 2.0;         // Trailing distance = ATR x this

input group "=== Position size ==="
input ENUM_LOT_MODE     InpLotMode                = LOT_MODE_RISK; // Lot size mode
input double            InpRiskPercent            = 0.25;        // Risk per trade (%) - risk mode
input double            InpFixedLotSize           = 0.01;        // Fixed lot size - fixed mode
input double            InpMaxLotSize             = 1.00;        // Safety cap: never trade more than this

input group "=== Daily protection ==="
input double            InpMaxDailyLossPercent    = 2.0;         // Max daily loss, realized + floating (%)
input double            InpMaxDailyProfitPercent  = 3.0;         // Daily profit boundary (%, 0 = off)
input int               InpMaxConsecutiveLosses   = 3;           // Stop for the day after N losses in a row
input int               InpMaxTradesPerDay        = 3;           // Max new trades per day
input int               InpCooldownAfterLossMinutes = 30;        // Wait after a losing trade (minutes, 0 = off)

input group "=== Execution ==="
input double            InpMaxSpreadPips          = 5.0;         // Max allowed spread (pips)
input double            InpMaxSlippagePips        = 3.0;         // Max allowed slippage (pips)
input ulong             InpMagicNumber            = 55200226;    // Magic number (V2 default differs from V1)

input group "=== Sessions (broker/server time, HH:MM-HH:MM) ==="
input ENUM_SESSION_MODE InpSessionMode            = SESSION_LONDON_NY; // Trading session
input string            InpLondonSession          = "10:00-19:00"; // London session (server time)
input string            InpNewYorkSession         = "15:00-22:00"; // New York session (server time)
input string            InpCustomSession          = "09:00-21:00"; // Custom session (server time)

input group "=== Manual news blackout (server time) ==="
input bool              InpNewsFilterEnabled      = false;       // Enable manual news blackout
input string            InpNewsStartTime          = "15:25";     // Blackout start (HH:MM)
input string            InpNewsEndTime            = "16:00";     // Blackout end (HH:MM)

input group "=== Display / logging ==="
input bool              InpShowDashboard          = true;        // Show dashboard on chart
input bool              InpVerboseLog             = true;        // Log a WAIT reason on every closed M15 candle
input bool              InpWriteTradeCSV          = true;        // Write trade list CSV when the EA stops

//+------------------------------------------------------------------+
//| Constants (fixed by design in V2)                                |
//+------------------------------------------------------------------+
#define MAX_OPEN_POSITIONS    1     // Only one XAUUSD position at a time - never stack
#define MAX_SEND_ATTEMPTS     2     // One retry only, and only for requote/price-changed errors
#define STAT_SESSION_COUNT    4     // London / Overlap / New York / Other
#define STAT_LONDON           0
#define STAT_OVERLAP          1
#define STAT_NEWYORK          2
#define STAT_OTHER            3
#define TRADE_COMMENT_PREFIX  "GoldBotV2"

// Confirmation candle shape (fractions of the candle's high-low range)
const double REJECTION_WICK_MIN      = 0.50;  // rejection wick >= 50% of the range
const double REJECTION_OPPOSITE_MAX  = 0.30;  // opposite wick <= 30% of the range
const double STRONG_BODY_MIN         = 0.60;  // strong candle body >= 60% of the range
const double STRONG_CLOSE_ZONE       = 0.25;  // strong candle closes within 25% of its extreme
const double CONFIRM_MIN_RANGE_ATR   = 0.50;  // confirmation candle range >= 50% of ATR

const double MARGIN_USAGE_MAX        = 0.90;  // never use more than 90% of free margin
const double TRAIL_STEP_OF_RISK      = 0.10;  // trailing SL only moves in steps >= 10% of initial risk
const int    MODIFY_RETRY_SECONDS    = 30;    // wait after a failed SL modification

// Quality score (max 100). Trend, zone and candle are also REQUIRED; the score grades their quality.
const int    SCORE_TREND_STRONG      = 30;    // H1 close beyond BOTH EMAs
const int    SCORE_TREND_PULLBACK    = 15;    // H1 close between EMA55 and EMA200
const int    SCORE_ZONE_MULTI        = 25;    // zone built from 2+ swing reactions
const int    SCORE_ZONE_SINGLE       = 10;    // zone from a single swing
const int    SCORE_CANDLE_REACTION   = 20;    // rejection or engulfing candle
const int    SCORE_CANDLE_STRONG     = 10;    // strong directional candle
const int    SCORE_EMA_CONFIRM       = 15;    // close beyond EMA 9
const int    SCORE_ATR_OK            = 10;    // ATR within limits

//+------------------------------------------------------------------+
//| Data structures                                                  |
//+------------------------------------------------------------------+
struct Zone
  {
   double            bottom;
   double            top;
   int               touches;          // number of swing reactions merged into this zone
  };

// One EA trade, rebuilt from the account history (restart-safe)
struct TradeRecord
  {
   long              positionId;
   bool              isBuy;
   datetime          openTime;
   datetime          closeTime;
   double            openPrice;
   double            closePrice;
   double            initialSL;        // SL of the opening order (0 = unknown)
   double            volume;
   double            net;              // profit + swap + commission (entry + exit)
   double            rMultiple;        // net / initial money risk
   bool              hasR;
   double            spreadPips;       // spread at entry (-1 = unknown)
   int               session;          // STAT_* bucket of the entry time
   int               exitReason;       // ENUM_DEAL_REASON of the exit deal
   bool              closed;
  };

struct GroupStats
  {
   int               trades;
   int               wins;
   int               losses;
   double            grossProfit;
   double            grossLoss;        // positive number
   double            sumR;
   int               countR;
   double            sumSpread;
   int               countSpread;
  };

struct OverallStats
  {
   GroupStats        all;
   GroupStats        buy;
   GroupStats        sell;
   GroupStats        session[STAT_SESSION_COUNT];
   double            maxDrawdown;      // money, closed-trade equity of this EA
   double            maxDrawdownPct;
   int               maxConsecLosses;
   double            avgTradesPerDay;
   datetime          lastLossTime;
  };

struct DailyStats
  {
   int               tradesToday;
   int               winsToday;
   int               lossesToday;
   double            realizedPL;
   double            floatingPL;
   int               consecutiveLosses;
  };

// Everything checked for one potential trade, for the checklist log
struct SetupCheck
  {
   bool              isBuy;
   string            trendText;
   int               trendScore;
   bool              zoneOk;
   string            zoneText;
   int               zoneScore;
   bool              candleOk;
   string            candleText;
   int               candleScore;
   bool              emaOk;
   string            emaText;
   int               emaScore;
   bool              atrOk;
   string            atrText;
   int               atrScore;
   bool              chaseOk;
   string            chaseText;
   bool              slOk;
   string            slText;
   bool              spreadOk;
   string            spreadText;
   int               score;
   bool              scoreOk;
   bool              timeOk;
   string            timeText;
   bool              riskOk;
   string            riskText;
   bool              positionOk;
   string            positionText;
   double            slDistance;       // price distance entry -> SL
   double            spreadPips;
   string            failures;         // all failed checks, joined
  };

//+------------------------------------------------------------------+
//| Global state                                                     |
//+------------------------------------------------------------------+
CTrade            g_trade;
string            g_symbol          = "";
double            g_point           = 0.0;
double            g_pipSize         = 0.0;
int               g_digits          = 0;
int               g_trendFastHandle = INVALID_HANDLE;
int               g_trendSlowHandle = INVALID_HANDLE;
int               g_entryEmaHandle  = INVALID_HANDLE;
int               g_atrHandle       = INVALID_HANDLE;
bool              g_isFastTester    = false;
bool              g_initialized     = false;   // OnInit completed successfully

// Session / news windows in minutes after midnight (server time)
int               g_londonStart = 0, g_londonEnd = 0;
int               g_nyStart     = 0, g_nyEnd     = 0;
int               g_customStart = 0, g_customEnd = 0;
int               g_newsStart   = 0, g_newsEnd   = 0;

datetime          g_lastBarTime     = 0;
string            g_candleLabel     = "";
double            g_atr             = 0.0;     // ATR of the last closed M15 candle (price units)

datetime          g_currentDay      = 0;
double            g_dayStartBalance = 0.0;
bool              g_tradingStopped  = false;
string            g_stopReason      = "";
DailyStats        g_daily;

TradeRecord       g_trades[];
int               g_tradeCount      = 0;
OverallStats      g_stats;

ENUM_TREND_STATE  g_trend           = TREND_NEUTRAL;
bool              g_trendStrong     = false;
ENUM_SETUP_STATE  g_setupState      = SETUP_WAITING;
int               g_lastScore       = 0;
string            g_lastDecision    = "Waiting for the next closed M15 candle";
datetime          g_lastDashUpdate  = 0;

// Trade management cache
long              g_mgPositionId    = -1;
double            g_mgRisk          = 0.0;
datetime          g_lastModifyFail  = 0;

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
  {
   g_symbol = ResolveSymbol();
   if(g_symbol == "")
     {
      Print("INIT FAILED: could not find a gold symbol. Set the 'Symbol' input to your broker's gold symbol name.");
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
   g_pipSize = (InpPipSize > 0.0 ? InpPipSize : 0.10);
   if(g_pipSize < g_point)
     {
      Print("INIT FAILED: pip size ", DoubleToString(g_pipSize, 5), " is smaller than the symbol point ",
            DoubleToString(g_point, g_digits), ".");
      return(INIT_PARAMETERS_INCORRECT);
     }

   g_trendFastHandle = iMA(g_symbol, PERIOD_H1, InpTrendFastEMA, 0, MODE_EMA, PRICE_CLOSE);
   g_trendSlowHandle = iMA(g_symbol, PERIOD_H1, InpTrendSlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   g_entryEmaHandle  = iMA(g_symbol, PERIOD_M15, InpEntryEMA, 0, MODE_EMA, PRICE_CLOSE);
   g_atrHandle       = iATR(g_symbol, PERIOD_M15, InpATRPeriod);
   if(g_trendFastHandle == INVALID_HANDLE || g_trendSlowHandle == INVALID_HANDLE ||
      g_entryEmaHandle == INVALID_HANDLE || g_atrHandle == INVALID_HANDLE)
     {
      Print("INIT FAILED: could not create indicators. Error ", GetLastError());
      return(INIT_FAILED);
     }

   g_trade.SetExpertMagicNumber(InpMagicNumber);
   long deviationPoints = (long)MathRound(PipsToPrice(InpMaxSlippagePips) / g_point);
   if(deviationPoints < 1)
      deviationPoints = 1;
   g_trade.SetDeviationInPoints((ulong)deviationPoints);
   g_trade.SetTypeFillingBySymbol(g_symbol);
   g_trade.SetAsyncMode(false);
   g_trade.LogLevel(LOG_LEVEL_ERRORS);

   g_isFastTester = (MQLInfoInteger(MQL_TESTER) != 0 && MQLInfoInteger(MQL_VISUAL_MODE) == 0);

   double h1Close = 0.0, emaFast = 0.0, emaSlow = 0.0;
   g_trend = GetTrend(h1Close, emaFast, emaSlow, g_trendStrong);
   UpdateATR();

   // Do not act on a candle that closed before the EA was attached: wait for the next one.
   g_lastBarTime = iTime(g_symbol, PERIOD_M15, 0);

   RebuildStatistics();
   ManageDailyLimits();
   PrintSettings();

   if(MQLInfoInteger(MQL_TESTER) == 0)
      EventSetTimer(2);

   g_initialized = true;
   UpdateDashboard();
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization: print statistics, write CSV             |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   if(g_initialized)
     {
      RebuildStatistics();
      PrintStatisticsReport();
      if(InpWriteTradeCSV)
         WriteTradesCSV();
     }
   if(g_trendFastHandle != INVALID_HANDLE)
      IndicatorRelease(g_trendFastHandle);
   if(g_trendSlowHandle != INVALID_HANDLE)
      IndicatorRelease(g_trendSlowHandle);
   if(g_entryEmaHandle != INVALID_HANDLE)
      IndicatorRelease(g_entryEmaHandle);
   if(g_atrHandle != INVALID_HANDLE)
      IndicatorRelease(g_atrHandle);
   Comment("");
  }

//+------------------------------------------------------------------+
//| Tick handler                                                     |
//+------------------------------------------------------------------+
void OnTick()
  {
   if(!g_initialized)
      return;
   ManageOpenPosition();          // break-even / trailing for an existing trade

   if(IsNewM15Bar())
      EvaluateNewBar();           // new entries: once per closed M15 candle only

   if(InpShowDashboard && !g_isFastTester && TimeCurrent() - g_lastDashUpdate >= 5)
      UpdateDashboard();
  }

void OnTimer()
  {
   UpdateDashboard();
  }

//+------------------------------------------------------------------+
//| Trade events: rebuild statistics, log closed trades              |
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
   ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   long positionId       = HistoryDealGetInteger(trans.deal, DEAL_POSITION_ID);
   // Our deals, or a manual close (magic 0) of one of our positions
   if((ulong)HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != InpMagicNumber && FindTradeIndex(positionId) < 0)
      return;

   RebuildStatistics();

   if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY)
     {
      int idx = FindTradeIndex(positionId);
      if(idx >= 0 && g_trades[idx].closed)
        {
         string rText = (g_trades[idx].hasR ? StringFormat("%+.2fR", g_trades[idx].rMultiple) : "R n/a");
         Print("TRADE CLOSED: ", (g_trades[idx].isBuy ? "BUY" : "SELL"), " ", g_symbol,
               " position #", positionId, " ", ExitReasonText(g_trades[idx]),
               " | Net: ", DoubleToString(g_trades[idx].net, 2), " ", AccountInfoString(ACCOUNT_CURRENCY),
               " (", rText, ")", (g_trades[idx].net < 0.0 ? " LOSS" : (g_trades[idx].net > 0.0 ? " WIN" : " BREAKEVEN")));
        }
      if(positionId == g_mgPositionId)
        {
         g_mgPositionId = -1;
         g_mgRisk       = 0.0;
        }
     }

   ManageDailyLimits();
   UpdateDashboard();
  }

//+------------------------------------------------------------------+
//| Main decision pipeline - once per closed M15 candle              |
//+------------------------------------------------------------------+
void EvaluateNewBar()
  {
   RebuildStatistics();           // never rely only on trade events for limits/cooldown
   ManageDailyLimits();
   UpdateATR();
   g_setupState = SETUP_WAITING;
   g_lastScore  = 0;

   datetime closedCandle = iTime(g_symbol, PERIOD_M15, 1);
   g_candleLabel = "[M15 " + TimeToString(closedCandle, TIME_DATE | TIME_MINUTES) + "] ";

   //--- 1. H1 trend (required)
   double h1Close = 0.0, emaFast = 0.0, emaSlow = 0.0;
   g_trend = GetTrend(h1Close, emaFast, emaSlow, g_trendStrong);
   if(g_trend == TREND_NEUTRAL)
     {
      if(emaSlow <= 0.0)
         LogDecision("WAIT: H1 indicator data not ready yet.", false);
      else
         LogDecision(StringFormat("WAIT: H1 trend unclear (H1 close=%s, EMA%d=%s, EMA%d=%s).",
                                  FormatPrice(h1Close), InpTrendFastEMA, FormatPrice(emaFast),
                                  InpTrendSlowEMA, FormatPrice(emaSlow)), false);
      return;
     }

   bool isBuy = (g_trend == TREND_BULLISH);
   if((isBuy && !InpAllowBuy) || (!isBuy && !InpAllowSell))
     {
      LogDecision(StringFormat("WAIT: %s trend, but %s trades are disabled in the settings.",
                               (isBuy ? "bullish" : "bearish"), (isBuy ? "BUY" : "SELL")), false);
      return;
     }

   //--- 2. Price must have reached a support/resistance zone (required)
   MqlRates rates[];
   if(!LoadM15Rates(rates))
     {
      LogDecision("WAIT: not enough M15 history loaded yet.", false);
      return;
     }
   Zone zone;
   string zoneFail = "";
   if(!FindTouchedZone(isBuy, rates, zone, zoneFail))
     {
      LogDecision("WAIT: " + zoneFail, false);
      return;
     }

   //--- A potential trade exists: evaluate EVERY remaining check for a full checklist
   SetupCheck check;
   InitCheck(check, isBuy);

   check.trendScore = (g_trendStrong ? SCORE_TREND_STRONG : SCORE_TREND_PULLBACK);
   check.trendText  = StringFormat("%s, %s (H1 close %s, EMA%d %s, EMA%d %s)",
                                   (isBuy ? "BULLISH" : "BEARISH"),
                                   (g_trendStrong ? "strong" : "pullback between EMAs"),
                                   FormatPrice(h1Close), InpTrendFastEMA, FormatPrice(emaFast),
                                   InpTrendSlowEMA, FormatPrice(emaSlow));

   check.zoneOk    = true;
   check.zoneScore = (zone.touches >= 2 ? SCORE_ZONE_MULTI : SCORE_ZONE_SINGLE);
   check.zoneText  = StringFormat("%s zone %s-%s (%d reaction%s)", (isBuy ? "support" : "resistance"),
                                  FormatPrice(zone.bottom), FormatPrice(zone.top),
                                  zone.touches, (zone.touches == 1 ? "" : "s"));

   CheckConfirmation(check, rates, zone);
   CheckEntryEMA(check, rates);
   CheckATR(check);

   MqlTick tick;
   bool haveTick = (SymbolInfoTick(g_symbol, tick) && tick.ask > 0.0 && tick.bid > 0.0);
   if(haveTick)
     {
      CheckEntryDistance(check, zone, tick);
      CalculateStopLoss(check, zone, rates, tick);
      CheckSpread(check, tick);
     }
   else
     {
      AddFailure(check, "No valid price quote");
      check.chaseText  = "no price";
      check.slText     = "no price";
      check.spreadText = "no price";
     }

   check.score   = check.trendScore + check.zoneScore + check.candleScore + check.emaScore + check.atrScore;
   check.scoreOk = (check.score >= InpMinScore);
   if(!check.scoreOk)
      AddFailure(check, StringFormat("Score %d below minimum %d", check.score, InpMinScore));

   CheckTradingTime(check);
   CheckRiskLimits(check);
   CheckNoOpenPosition(check);

   g_lastScore = check.score;
   bool setupQuality = (check.candleOk && check.emaOk && check.atrOk && check.chaseOk && check.slOk && check.scoreOk);
   if(setupQuality)
      g_setupState = (isBuy ? SETUP_BUY : SETUP_SELL);

   bool accepted = (check.failures == "");
   PrintSetupCheck(check, accepted);

   if(!accepted)
     {
      g_lastDecision = "REJECTED: " + check.failures;
      return;
     }

   string blocked = "";
   if(!CheckTradingAllowed(isBuy, blocked))
     {
      LogDecision("NO TRADE: " + blocked, true);
      return;
     }

   //--- Everything passed: open exactly one trade
   string reason = StringFormat("%s + %s + %s + %s + %s; score %d/100",
                                check.trendText, check.zoneText, check.candleText, check.emaText,
                                check.atrText, check.score);
   if(isBuy)
      OpenBuy(check, reason);
   else
      OpenSell(check, reason);

   UpdateDashboard();
  }

//+------------------------------------------------------------------+
//| New M15 candle detection (one evaluation per candle)             |
//+------------------------------------------------------------------+
bool IsNewM15Bar()
  {
   datetime barTime = iTime(g_symbol, PERIOD_M15, 0);
   if(barTime == 0)
      return(false);
   if(g_lastBarTime == 0)
     {
      g_lastBarTime = barTime;
      return(false);
     }
   if(barTime == g_lastBarTime)
      return(false);
   g_lastBarTime = barTime;              // marked BEFORE evaluation: one attempt per candle
   return(true);
  }

//+------------------------------------------------------------------+
//| H1 trend from the last CLOSED H1 candle                          |
//| strong = H1 close is also beyond EMA 55 (not just EMA 200)       |
//+------------------------------------------------------------------+
ENUM_TREND_STATE GetTrend(double &h1Close, double &emaFast, double &emaSlow, bool &strong)
  {
   h1Close = 0.0;
   emaFast = 0.0;
   emaSlow = 0.0;
   strong  = false;

   double fastBuf[], slowBuf[], closeBuf[];
   if(CopyBuffer(g_trendFastHandle, 0, 1, 1, fastBuf) != 1 ||
      CopyBuffer(g_trendSlowHandle, 0, 1, 1, slowBuf) != 1 ||
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
     {
      strong = (h1Close > emaFast);
      return(TREND_BULLISH);
     }
   if(h1Close < emaSlow && emaFast < emaSlow)
     {
      strong = (h1Close < emaFast);
      return(TREND_BEARISH);
     }
   return(TREND_NEUTRAL);
  }

//+------------------------------------------------------------------+
//| ATR of the last closed M15 candle (price units)                  |
//+------------------------------------------------------------------+
void UpdateATR()
  {
   double buf[];
   if(CopyBuffer(g_atrHandle, 0, 1, 1, buf) == 1 && buf[0] > 0.0)
      g_atr = buf[0];
  }

//+------------------------------------------------------------------+
//| M15 candles in series order: 0 = forming, 1 = just closed        |
//+------------------------------------------------------------------+
bool LoadM15Rates(MqlRates &rates[])
  {
   int needed = InpSwingLookbackBars + InpSwingStrength + 5;
   ArraySetAsSeries(rates, true);
   int copied = CopyRates(g_symbol, PERIOD_M15, 0, needed, rates);
   return(copied == needed);
  }

//+------------------------------------------------------------------+
//| Swing points (simple fractal). Newer bars have lower indexes.    |
//+------------------------------------------------------------------+
bool IsSwingLow(const MqlRates &rates[], int i, int strength)
  {
   for(int k = 1; k <= strength; k++)
     {
      if(rates[i - k].low < rates[i].low)
         return(false);
      if(rates[i + k].low <= rates[i].low)
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

// A swing level is broken if any later candle (before the 2 test candles) CLOSED through it
bool IsLevelBroken(const MqlRates &rates[], int swingIndex, double level, bool support)
  {
   for(int j = swingIndex - 1; j >= 3; j--)
     {
      if(support && rates[j].close < level)
         return(true);
      if(!support && rates[j].close > level)
         return(true);
     }
   return(false);
  }

//+------------------------------------------------------------------+
//| Build zones: collect unbroken swing lows (support) or highs      |
//| (resistance), sort them, and merge swings that are within        |
//| InpZoneMergePips of each other. More merged swings = more        |
//| reactions = a more meaningful zone.                              |
//| Only swings fully formed before the last 2 candles are used.     |
//+------------------------------------------------------------------+
int BuildZones(const MqlRates &rates[], bool support, Zone &zones[])
  {
   ArrayResize(zones, 0);
   int strength = InpSwingStrength;
   int first    = strength + 3;
   int last     = MathMin(InpSwingLookbackBars, ArraySize(rates) - strength - 1);

   double levels[];
   int count = 0;
   for(int i = first; i <= last; i++)
     {
      bool isSwing = (support ? IsSwingLow(rates, i, strength) : IsSwingHigh(rates, i, strength));
      if(!isSwing)
         continue;
      double level = (support ? rates[i].low : rates[i].high);
      if(IsLevelBroken(rates, i, level, support))
         continue;
      ArrayResize(levels, count + 1);
      levels[count] = level;
      count++;
     }
   if(count == 0)
      return(0);

   ArraySort(levels);                         // ascending
   double mergeDistance = PipsToPrice(InpZoneMergePips);
   int zoneCount = 0;
   for(int k = 0; k < count; k++)
     {
      if(zoneCount > 0 && levels[k] - zones[zoneCount - 1].bottom <= mergeDistance)
        {
         zones[zoneCount - 1].top = levels[k];
         zones[zoneCount - 1].touches++;
        }
      else
        {
         ArrayResize(zones, zoneCount + 1);
         zones[zoneCount].bottom  = levels[k];
         zones[zoneCount].top     = levels[k];
         zones[zoneCount].touches = 1;
         zoneCount++;
        }
     }
   return(zoneCount);
  }

// Nearest support zone below refPrice (the zone with the highest top whose bottom is below price)
bool FindSupport(const MqlRates &rates[], double refPrice, Zone &zone)
  {
   Zone zones[];
   int n = BuildZones(rates, true, zones);
   int best = -1;
   for(int i = 0; i < n; i++)
     {
      if(zones[i].bottom >= refPrice)
         continue;
      if(best < 0 || zones[i].top > zones[best].top)
         best = i;
     }
   if(best < 0)
      return(false);
   zone = zones[best];
   return(true);
  }

// Nearest resistance zone above refPrice (the zone with the lowest bottom whose top is above price)
bool FindResistance(const MqlRates &rates[], double refPrice, Zone &zone)
  {
   Zone zones[];
   int n = BuildZones(rates, false, zones);
   int best = -1;
   for(int i = 0; i < n; i++)
     {
      if(zones[i].top <= refPrice)
         continue;
      if(best < 0 || zones[i].bottom < zones[best].bottom)
         best = i;
     }
   if(best < 0)
      return(false);
   zone = zones[best];
   return(true);
  }

//+------------------------------------------------------------------+
//| Did the last 2 closed candles reach the zone without breaking it?|
//+------------------------------------------------------------------+
bool FindTouchedZone(bool isBuy, const MqlRates &rates[], Zone &zone, string &failReason)
  {
   double distance = PipsToPrice(InpZoneDistancePips);
   double close1   = rates[1].close;

   if(isBuy)
     {
      if(!FindSupport(rates, close1, zone))
        {
         failReason = "No valid support zone below price.";
         return(false);
        }
      double touchLow = MathMin(rates[1].low, rates[2].low);
      if(touchLow > zone.top + distance)
        {
         failReason = StringFormat("Price not near support (zone %s-%s, recent low %.1f pips above it, max %.1f).",
                                   FormatPrice(zone.bottom), FormatPrice(zone.top),
                                   (touchLow - zone.top) / g_pipSize, InpZoneDistancePips);
         return(false);
        }
      if(touchLow < zone.bottom - distance)
        {
         failReason = StringFormat("Support zone %s-%s was broken (low %.1f pips below it).",
                                   FormatPrice(zone.bottom), FormatPrice(zone.top),
                                   (zone.bottom - touchLow) / g_pipSize);
         return(false);
        }
      return(true);
     }

   if(!FindResistance(rates, close1, zone))
     {
      failReason = "No valid resistance zone above price.";
      return(false);
     }
   double touchHigh = MathMax(rates[1].high, rates[2].high);
   if(touchHigh < zone.bottom - distance)
     {
      failReason = StringFormat("Price not near resistance (zone %s-%s, recent high %.1f pips below it, max %.1f).",
                                FormatPrice(zone.bottom), FormatPrice(zone.top),
                                (zone.bottom - touchHigh) / g_pipSize, InpZoneDistancePips);
      return(false);
     }
   if(touchHigh > zone.top + distance)
     {
      failReason = StringFormat("Resistance zone %s-%s was broken (high %.1f pips above it).",
                                FormatPrice(zone.bottom), FormatPrice(zone.top),
                                (touchHigh - zone.top) / g_pipSize);
      return(false);
     }
   return(true);
  }

//+------------------------------------------------------------------+
//| Candle reaction on the candle that just closed (rates[1]).       |
//| The candle MUST close in the trade direction. Then any one of:   |
//|   rejection (long wick into zone) / engulfing  -> 20 points      |
//|   strong directional candle                    -> 10 points      |
//+------------------------------------------------------------------+
void CheckConfirmation(SetupCheck &c, const MqlRates &rates[], const Zone &zone)
  {
   c.candleOk    = false;
   c.candleScore = 0;

   double open1  = rates[1].open;
   double high1  = rates[1].high;
   double low1   = rates[1].low;
   double close1 = rates[1].close;
   double open2  = rates[2].open;
   double close2 = rates[2].close;

   double range     = high1 - low1;
   double body      = MathAbs(close1 - open1);
   double upperWick = high1 - MathMax(open1, close1);
   double lowerWick = MathMin(open1, close1) - low1;
   double distance  = PipsToPrice(InpZoneDistancePips);
   double minRange  = g_atr * CONFIRM_MIN_RANGE_ATR;

   if(range <= 0.0 || range < minRange)
     {
      c.candleText = StringFormat("candle too small (%.1f pips < %.0f%% of ATR = %.1f pips)",
                                  range / g_pipSize, CONFIRM_MIN_RANGE_ATR * 100.0, minRange / g_pipSize);
      AddFailure(c, "Confirmation candle too small");
      return;
     }

   if(c.isBuy)
     {
      if(close1 <= open1)
        {
         c.candleText = "candle did not close bullish";
         AddFailure(c, "No bullish reaction candle");
         return;
        }
      if(lowerWick >= REJECTION_WICK_MIN * range && upperWick <= REJECTION_OPPOSITE_MAX * range &&
         low1 <= zone.top + distance)
        {
         c.candleOk = true;
         c.candleScore = SCORE_CANDLE_REACTION;
         c.candleText = "bullish rejection candle (long lower wick into support)";
         return;
        }
      if(close2 < open2 && close1 >= open2 && open1 <= close2)
        {
         c.candleOk = true;
         c.candleScore = SCORE_CANDLE_REACTION;
         c.candleText = "bullish engulfing candle";
         return;
        }
      if(body >= STRONG_BODY_MIN * range && (high1 - close1) <= STRONG_CLOSE_ZONE * range)
        {
         c.candleOk = true;
         c.candleScore = SCORE_CANDLE_STRONG;
         c.candleText = "strong bullish candle";
         return;
        }
      c.candleText = "bullish close, but no rejection, engulfing or strong candle";
      AddFailure(c, "No bullish reaction candle");
      return;
     }

   if(close1 >= open1)
     {
      c.candleText = "candle did not close bearish";
      AddFailure(c, "No bearish reaction candle");
      return;
     }
   if(upperWick >= REJECTION_WICK_MIN * range && lowerWick <= REJECTION_OPPOSITE_MAX * range &&
      high1 >= zone.bottom - distance)
     {
      c.candleOk = true;
      c.candleScore = SCORE_CANDLE_REACTION;
      c.candleText = "bearish rejection candle (long upper wick into resistance)";
      return;
     }
   if(close2 > open2 && close1 <= open2 && open1 >= close2)
     {
      c.candleOk = true;
      c.candleScore = SCORE_CANDLE_REACTION;
      c.candleText = "bearish engulfing candle";
      return;
     }
   if(body >= STRONG_BODY_MIN * range && (close1 - low1) <= STRONG_CLOSE_ZONE * range)
     {
      c.candleOk = true;
      c.candleScore = SCORE_CANDLE_STRONG;
      c.candleText = "strong bearish candle";
      return;
     }
   c.candleText = "bearish close, but no rejection, engulfing or strong candle";
   AddFailure(c, "No bearish reaction candle");
  }

//+------------------------------------------------------------------+
//| EMA 9 entry timing: close beyond the EMA in the trade direction  |
//+------------------------------------------------------------------+
void CheckEntryEMA(SetupCheck &c, const MqlRates &rates[])
  {
   c.emaScore = 0;
   double buf[];
   if(CopyBuffer(g_entryEmaHandle, 0, 1, 1, buf) != 1 || buf[0] <= 0.0)
     {
      c.emaOk   = !InpRequireEMAConfirm;
      c.emaText = StringFormat("EMA%d data not ready", InpEntryEMA);
      if(InpRequireEMAConfirm)
         AddFailure(c, StringFormat("EMA%d data not ready", InpEntryEMA));
      return;
     }
   double ema    = buf[0];
   double close1 = rates[1].close;
   bool confirmed = (c.isBuy ? close1 > ema : close1 < ema);

   c.emaText = StringFormat("close %s %s EMA%d %s", FormatPrice(close1),
                            (confirmed ? (c.isBuy ? ">" : "<") : (c.isBuy ? "<=" : ">=")),
                            InpEntryEMA, FormatPrice(ema));
   if(confirmed)
     {
      c.emaOk    = true;
      c.emaScore = SCORE_EMA_CONFIRM;
      return;
     }
   c.emaOk = !InpRequireEMAConfirm;          // optional mode: only costs score points
   if(InpRequireEMAConfirm)
      AddFailure(c, StringFormat("EMA%d confirmation missing", InpEntryEMA));
  }

//+------------------------------------------------------------------+
//| ATR volatility filter                                            |
//+------------------------------------------------------------------+
void CheckATR(SetupCheck &c)
  {
   c.atrScore = 0;
   c.atrOk    = false;
   if(g_atr <= 0.0)
     {
      c.atrText = "ATR not ready";
      AddFailure(c, "ATR data not ready");
      return;
     }
   double atrPips = g_atr / g_pipSize;
   string limits  = (InpMaxATRPips > 0.0 ? StringFormat("min %.0f / max %.0f", InpMinATRPips, InpMaxATRPips)
                                          : StringFormat("min %.0f / no max", InpMinATRPips));
   c.atrText = StringFormat("ATR %.1f pips (%s)", atrPips, limits);

   if(atrPips < InpMinATRPips)
     {
      AddFailure(c, "Volatility too low (ATR below minimum)");
      return;
     }
   if(InpMaxATRPips > 0.0 && atrPips > InpMaxATRPips)
     {
      AddFailure(c, "Volatility too high (ATR above maximum)");
      return;
     }
   c.atrOk    = true;
   c.atrScore = SCORE_ATR_OK;
  }

//+------------------------------------------------------------------+
//| Don't chase: entry must still be close to the zone               |
//+------------------------------------------------------------------+
void CheckEntryDistance(SetupCheck &c, const Zone &zone, const MqlTick &tick)
  {
   double distance = (c.isBuy ? tick.ask - zone.top : zone.bottom - tick.bid);
   if(distance < 0.0)
      distance = 0.0;                        // entry inside the zone
   double pips = distance / g_pipSize;
   c.chaseText = StringFormat("entry %.1f pips from zone (max %.1f)", pips, InpMaxDistanceFromZonePips);
   c.chaseOk   = (pips <= InpMaxDistanceFromZonePips);
   if(!c.chaseOk)
      AddFailure(c, "Price already too far from the zone (not chasing)");
  }

//+------------------------------------------------------------------+
//| Stop loss: fixed or ATR distance, pushed beyond the zone and the |
//| reaction candles if that is further. Never widened past the max. |
//+------------------------------------------------------------------+
void CalculateStopLoss(SetupCheck &c, const Zone &zone, const MqlRates &rates[], const MqlTick &tick)
  {
   c.slOk       = false;
   c.slDistance = 0.0;

   double modeDistance = (InpSLMode == SL_MODE_FIXED ? PipsToPrice(InpFixedSLPips) : g_atr * InpATRSLMultiplier);
   if(modeDistance <= 0.0)
     {
      c.slText = "SL distance unavailable (ATR not ready)";
      AddFailure(c, "Stop loss cannot be calculated");
      return;
     }

   double entry  = (c.isBuy ? tick.ask : tick.bid);
   double buffer = PipsToPrice(InpSLBufferPips);
   double sl     = (c.isBuy ? entry - modeDistance : entry + modeDistance);
   bool structural = false;

   if(InpUseStructureSL)
     {
      if(c.isBuy)
        {
         double structureSL = MathMin(zone.bottom, MathMin(rates[1].low, rates[2].low)) - buffer;
         if(structureSL < sl)
           {
            sl = structureSL;
            structural = true;
           }
        }
      else
        {
         double structureSL = MathMax(zone.top, MathMax(rates[1].high, rates[2].high)) + buffer;
         if(structureSL > sl)
           {
            sl = structureSL;
            structural = true;
           }
        }
     }

   sl = NormalizePrice(sl);
   double slDistance = (c.isBuy ? entry - sl : sl - entry);
   double slPips     = slDistance / g_pipSize;
   c.slText = StringFormat("SL %.1f pips (%s%s, max %.0f) -> TP %.1f pips (%.1fR)",
                           slPips, (InpSLMode == SL_MODE_FIXED ? "fixed" : "ATR"),
                           (structural ? " + beyond zone" : ""), InpMaxStopLossPips,
                           slPips * InpRiskReward, InpRiskReward);

   if(slDistance <= 0.0)
     {
      AddFailure(c, "Invalid stop loss distance");
      return;
     }
   if(slPips > InpMaxStopLossPips)
     {
      AddFailure(c, StringFormat("Required SL %.1f pips is larger than the maximum %.0f", slPips, InpMaxStopLossPips));
      return;
     }
   // Broker minimum stop distance. A BUY's SL is checked against Bid, so the spread counts.
   double minStop = (double)SymbolInfoInteger(g_symbol, SYMBOL_TRADE_STOPS_LEVEL) * g_point;
   double spread  = tick.ask - tick.bid;
   if(slDistance - spread <= minStop)
     {
      AddFailure(c, StringFormat("SL inside broker minimum stop level (%.1f pips)", minStop / g_pipSize));
      return;
     }
   c.slOk       = true;
   c.slDistance = slDistance;
  }

//+------------------------------------------------------------------+
//| Spread filter                                                    |
//+------------------------------------------------------------------+
void CheckSpread(SetupCheck &c, const MqlTick &tick)
  {
   c.spreadPips = (tick.ask - tick.bid) / g_pipSize;
   c.spreadText = StringFormat("%.1f pips (max %.1f)", c.spreadPips, InpMaxSpreadPips);
   c.spreadOk   = (c.spreadPips <= InpMaxSpreadPips);
   if(!c.spreadOk)
      AddFailure(c, "Spread too high");
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
//| Sessions + manual news blackout                                  |
//+------------------------------------------------------------------+
bool IsInTradingSession(int nowMin)
  {
   switch(InpSessionMode)
     {
      case SESSION_LONDON:
         return(IsTimeInWindow(nowMin, g_londonStart, g_londonEnd));
      case SESSION_NEWYORK:
         return(IsTimeInWindow(nowMin, g_nyStart, g_nyEnd));
      case SESSION_LONDON_NY:
         return(IsTimeInWindow(nowMin, g_londonStart, g_londonEnd) || IsTimeInWindow(nowMin, g_nyStart, g_nyEnd));
      case SESSION_CUSTOM:
         return(IsTimeInWindow(nowMin, g_customStart, g_customEnd));
     }
   return(false);
  }

string SessionModeText()
  {
   switch(InpSessionMode)
     {
      case SESSION_LONDON:
         return("London " + InpLondonSession);
      case SESSION_NEWYORK:
         return("New York " + InpNewYorkSession);
      case SESSION_LONDON_NY:
         return("London+NY " + InpLondonSession + " / " + InpNewYorkSession);
      case SESSION_CUSTOM:
         return("Custom " + InpCustomSession);
     }
   return("?");
  }

bool IsNewsBlackout(int nowMin)
  {
   return(InpNewsFilterEnabled && IsTimeInWindow(nowMin, g_newsStart, g_newsEnd));
  }

int MinutesOfDay(datetime t)
  {
   MqlDateTime dt;
   TimeToStruct(t, dt);
   return(dt.hour * 60 + dt.min);
  }

void CheckTradingTime(SetupCheck &c)
  {
   int nowMin = MinutesOfDay(TimeCurrent());
   c.timeOk   = true;
   c.timeText = "inside session (" + SessionModeText() + ")";
   if(!IsInTradingSession(nowMin))
     {
      c.timeOk   = false;
      c.timeText = "outside session (" + SessionModeText() + ")";
      AddFailure(c, "Outside trading session");
      return;
     }
   if(IsNewsBlackout(nowMin))
     {
      c.timeOk   = false;
      c.timeText = "news blackout " + InpNewsStartTime + "-" + InpNewsEndTime;
      AddFailure(c, "News blackout period");
     }
  }

// [start, end) in minutes, supports windows crossing midnight. Empty if start == end.
bool IsTimeInWindow(int nowMin, int startMin, int endMin)
  {
   if(startMin == endMin)
      return(false);
   if(startMin < endMin)
      return(nowMin >= startMin && nowMin < endMin);
   return(nowMin >= startMin || nowMin < endMin);
  }

// Statistics bucket for a trade's entry time
int ClassifySession(datetime t)
  {
   int m = MinutesOfDay(t);
   bool inLondon = IsTimeInWindow(m, g_londonStart, g_londonEnd);
   bool inNY     = IsTimeInWindow(m, g_nyStart, g_nyEnd);
   if(inLondon && inNY)
      return(STAT_OVERLAP);
   if(inLondon)
      return(STAT_LONDON);
   if(inNY)
      return(STAT_NEWYORK);
   return(STAT_OTHER);
  }

string SessionName(int s)
  {
   if(s == STAT_LONDON)
      return("London only");
   if(s == STAT_OVERLAP)
      return("London/NY overlap");
   if(s == STAT_NEWYORK)
      return("New York only");
   return("Other hours");
  }

//+------------------------------------------------------------------+
//| Daily limits: new-day reset, daily stats, latched stop           |
//+------------------------------------------------------------------+
void ManageDailyLimits()
  {
   datetime now   = TimeCurrent();
   datetime today = (datetime)(((long)now / 86400) * 86400);   // 00:00 server time

   if(today != g_currentDay)
     {
      bool firstRun    = (g_currentDay == 0);
      g_currentDay     = today;
      g_tradingStopped = false;
      g_stopReason     = "";
      CalculateDailyStats(g_daily);
      g_dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE) - g_daily.realizedPL;
      Print(firstRun ? "Daily tracking started for " : "NEW TRADING DAY: counters reset for ",
            TimeToString(today, TIME_DATE), ". Day-start balance: ",
            DoubleToString(g_dayStartBalance, 2), " ", AccountInfoString(ACCOUNT_CURRENCY));
     }
   else
      CalculateDailyStats(g_daily);

   if(g_tradingStopped)
      return;

   double dayPL      = g_daily.realizedPL + g_daily.floatingPL;
   double lossLimit  = g_dayStartBalance * InpMaxDailyLossPercent / 100.0;
   double profitStop = g_dayStartBalance * InpMaxDailyProfitPercent / 100.0;

   if(lossLimit > 0.0 && dayPL <= -lossLimit)
      StopTradingForToday(StringFormat("Daily loss limit reached (%.2f, limit -%.2f = %.2f%%).",
                                       dayPL, lossLimit, InpMaxDailyLossPercent));
   else
      if(InpMaxDailyProfitPercent > 0.0 && profitStop > 0.0 && dayPL >= profitStop)
         StopTradingForToday(StringFormat("Daily profit boundary reached (%.2f >= %.2f = %.2f%%).",
                                          dayPL, profitStop, InpMaxDailyProfitPercent));
      else
         if(g_daily.consecutiveLosses >= InpMaxConsecutiveLosses)
            StopTradingForToday(StringFormat("Consecutive loss limit reached (%d losses in a row).",
                                             g_daily.consecutiveLosses));
         else
            if(g_daily.tradesToday >= InpMaxTradesPerDay)
               StopTradingForToday(StringFormat("Max trades per day reached (%d of %d).",
                                                g_daily.tradesToday, InpMaxTradesPerDay));
  }

void StopTradingForToday(const string reason)
  {
   if(g_tradingStopped)
      return;
   g_tradingStopped = true;
   g_stopReason     = reason;
   Print("DAILY TRADING STOPPED: ", reason, " No new trades until the next server day.");
  }

// Today's numbers, from the trade records (rebuilt from history) + open positions
void CalculateDailyStats(DailyStats &d)
  {
   d.tradesToday       = 0;
   d.winsToday         = 0;
   d.lossesToday       = 0;
   d.realizedPL        = 0.0;
   d.floatingPL        = 0.0;
   d.consecutiveLosses = 0;

   for(int i = 0; i < g_tradeCount; i++)
     {
      if(g_trades[i].openTime >= g_currentDay)
         d.tradesToday++;
      if(g_trades[i].closed && g_trades[i].closeTime >= g_currentDay)
        {
         d.realizedPL += g_trades[i].net;
         if(g_trades[i].net > 0.0)
            d.winsToday++;
         if(g_trades[i].net < 0.0)
           {
            d.lossesToday++;
            d.consecutiveLosses++;
           }
         else
            d.consecutiveLosses = 0;
        }
      else
         if(!g_trades[i].closed && g_trades[i].openTime >= g_currentDay)
            d.realizedPL += g_trades[i].net;          // entry commission already paid
     }

   for(int p = PositionsTotal() - 1; p >= 0; p--)
     {
      ulong ticket = PositionGetTicket(p);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol)
         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;
      d.floatingPL += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
     }
  }

bool IsInCooldown(datetime &until)
  {
   until = 0;
   if(InpCooldownAfterLossMinutes <= 0 || g_stats.lastLossTime == 0)
      return(false);
   until = g_stats.lastLossTime + InpCooldownAfterLossMinutes * 60;
   return(TimeCurrent() < until);
  }

void CheckRiskLimits(SetupCheck &c)
  {
   ManageDailyLimits();
   c.riskOk   = true;
   c.riskText = "daily limits OK";
   if(g_tradingStopped)
     {
      c.riskOk   = false;
      c.riskText = "daily trading stopped: " + g_stopReason;
      AddFailure(c, "Daily trading stopped");
      return;
     }
   datetime until = 0;
   if(IsInCooldown(until))
     {
      c.riskOk   = false;
      c.riskText = "cooldown after loss until " + TimeToString(until, TIME_MINUTES);
      AddFailure(c, "Cooldown after losing trade");
      return;
     }
   if(AccountInfoDouble(ACCOUNT_BALANCE) <= 0.0)
     {
      c.riskOk   = false;
      c.riskText = "balance is zero or negative";
      AddFailure(c, "Account balance invalid");
     }
  }

//+------------------------------------------------------------------+
//| Position limit: max 1 position on the symbol (any magic)         |
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

void CheckNoOpenPosition(SetupCheck &c)
  {
   int own = 0;
   int total = CountOpenPositions(own);
   c.positionOk   = (total < MAX_OPEN_POSITIONS);
   c.positionText = (c.positionOk ? "no open position"
                     : StringFormat("%d position(s) already open (%d by this EA)", total, own));
   if(!c.positionOk)
      AddFailure(c, "A position is already open");
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
//| Risk mode uses the LOWER of balance and equity. Lots are always  |
//| rounded DOWN, never up to the broker minimum.                    |
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
      double base       = MathMin(AccountInfoDouble(ACCOUNT_BALANCE), AccountInfoDouble(ACCOUNT_EQUITY));
      double riskBudget = base * InpRiskPercent / 100.0;
      rawLots = riskBudget / lossPerLot;
     }

   double cap = MathMin(maxLot, InpMaxLotSize);
   if(rawLots > cap)
     {
      Print(g_candleLabel, "NOTE: lot size ", DoubleToString(rawLots, 2), " capped to ", DoubleToString(cap, 2),
            " (broker max / safety cap).");
      rawLots = cap;
     }
   if(rawLots < minLot)
     {
      reason = StringFormat("Calculated lot %.4f is below the broker minimum %.2f. "
                            "Risk is too small for this stop loss - trade skipped (lots are never rounded up).",
                            rawLots, minLot);
      return(0.0);
     }
   // Valid volumes are minLot + n x step: round DOWN on that grid
   double lots = minLot + FloorToStep(rawLots - minLot, lotStep);
   lots = NormalizeDouble(lots, StepDigits(lotStep));
   if(lots > rawLots + 1e-9 || lots < minLot)
     {
      reason = "Could not fit the lot size to the broker's volume step.";
      return(0.0);
     }
   riskMoney = lots * lossPerLot;
   return(lots);
  }

// Money lost by 1.0 lot from entry to sl. OrderCalcProfit handles tick size/value for any digits.
double LossPerLot(bool isBuy, double entry, double sl)
  {
   double profit = 0.0;
   ENUM_ORDER_TYPE type = (isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
   if(OrderCalcProfit(type, g_symbol, 1.0, entry, sl, profit) && profit < 0.0)
      return(-profit);

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
bool OpenBuy(const SetupCheck &c, const string reason)
  {
   return(OpenTrade(c, reason));
  }

bool OpenSell(const SetupCheck &c, const string reason)
  {
   return(OpenTrade(c, reason));
  }

bool OpenTrade(const SetupCheck &c, const string reason)
  {
   bool   isBuy     = c.isBuy;
   string direction = (isBuy ? "BUY" : "SELL");
   double slDist    = c.slDistance;
   double tpDist    = slDist * InpRiskReward;

   for(int attempt = 1; attempt <= MAX_SEND_ATTEMPTS; attempt++)
     {
      // Duplicate guard right before every send
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
      double spreadPips = (tick.ask - tick.bid) / g_pipSize;
      if(spreadPips > InpMaxSpreadPips)
        {
         LogDecision(StringFormat("NO TRADE: %s aborted - spread widened to %.1f pips.", direction, spreadPips), true);
         return(false);
        }

      double minStop = (double)SymbolInfoInteger(g_symbol, SYMBOL_TRADE_STOPS_LEVEL) * g_point;
      if(slDist - (tick.ask - tick.bid) <= minStop)
        {
         LogDecision("NO TRADE: " + direction + " aborted - SL inside the broker's minimum stop level.", true);
         return(false);
        }

      // Same risk distance as the checked setup, anchored to the current price
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

      // Spread at entry is stored in the order comment so statistics survive restarts
      string comment = StringFormat("%s sp%.1f", TRADE_COMMENT_PREFIX, spreadPips);

      bool sent = (isBuy ? g_trade.Buy(lots, g_symbol, entry, sl, tp, comment)
                         : g_trade.Sell(lots, g_symbol, entry, sl, tp, comment));
      uint retcode = g_trade.ResultRetcode();

      if(sent && (retcode == TRADE_RETCODE_DONE || retcode == TRADE_RETCODE_DONE_PARTIAL || retcode == TRADE_RETCODE_PLACED))
        {
         double fill    = g_trade.ResultPrice();
         double base    = MathMin(AccountInfoDouble(ACCOUNT_BALANCE), AccountInfoDouble(ACCOUNT_EQUITY));
         Print(g_candleLabel, "TRADE OPENED: ", direction, " ", g_symbol);
         Print("   Reason: ", reason);
         Print(StringFormat("   Lots=%.2f  Entry=%s  SL=%s (%.1f pips)  TP=%s (%.1f pips, %.1fR)  Spread=%.1f pips",
                            g_trade.ResultVolume(), FormatPrice(fill > 0.0 ? fill : entry),
                            FormatPrice(sl), slDist / g_pipSize, FormatPrice(tp), tpDist / g_pipSize,
                            InpRiskReward, spreadPips));
         Print(StringFormat("   Risk~%.2f %s (%.2f%%)  Deal #%s",
                            riskMoney, AccountInfoString(ACCOUNT_CURRENCY),
                            (base > 0.0 ? riskMoney / base * 100.0 : 0.0), (string)g_trade.ResultDeal()));
         g_lastDecision = StringFormat("TRADE: %s (score %d)", direction, c.score);
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

bool IsRetryableRetcode(uint retcode)
  {
   return(retcode == TRADE_RETCODE_REQUOTE ||
          retcode == TRADE_RETCODE_PRICE_CHANGED ||
          retcode == TRADE_RETCODE_PRICE_OFF);
  }

//+------------------------------------------------------------------+
//| Trade management: break-even, optional ATR trailing stop.        |
//| SL only ever moves in the trade's favour. TP is never changed.   |
//+------------------------------------------------------------------+
void ManageOpenPosition()
  {
   if(!InpBreakEvenEnabled && !InpTrailingEnabled)
      return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol)
         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;

      bool   isBuy = ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      long   posId = PositionGetInteger(POSITION_IDENTIFIER);
      double open  = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl    = PositionGetDouble(POSITION_SL);
      double tp    = PositionGetDouble(POSITION_TP);
      double price = (isBuy ? SymbolInfoDouble(g_symbol, SYMBOL_BID) : SymbolInfoDouble(g_symbol, SYMBOL_ASK));
      if(price <= 0.0 || sl <= 0.0)
         continue;                            // never manage a position without an SL

      double risk = GetInitialRisk(posId, open, tp);
      if(risk <= 0.0)
         continue;

      double profitDistance = (isBuy ? price - open : open - price);
      double newSL = sl;
      string action = "";

      // Break-even
      if(InpBreakEvenEnabled && profitDistance >= InpBreakEvenAtR * risk)
        {
         double beLevel = NormalizePrice(isBuy ? open + PipsToPrice(InpBreakEvenBufferPips)
                                               : open - PipsToPrice(InpBreakEvenBufferPips));
         if(isBuy ? (beLevel > newSL + g_point * 0.5) : (beLevel < newSL - g_point * 0.5))
           {
            newSL  = beLevel;
            action = StringFormat("Break-even at +%.1fR", profitDistance / risk);
           }
        }

      // Optional ATR trailing stop (only after InpTrailStartR, only in steps)
      if(InpTrailingEnabled && g_atr > 0.0 && profitDistance >= InpTrailStartR * risk)
        {
         double trail = NormalizePrice(isBuy ? price - g_atr * InpTrailATRMultiplier
                                             : price + g_atr * InpTrailATRMultiplier);
         double step  = risk * TRAIL_STEP_OF_RISK;
         if(isBuy ? (trail > newSL && trail - sl >= step) : (trail < newSL && sl - trail >= step))
           {
            newSL  = trail;
            action = StringFormat("Trailing stop at +%.1fR", profitDistance / risk);
           }
        }

      if(action == "")
         continue;
      if(g_lastModifyFail > 0 && TimeCurrent() - g_lastModifyFail < MODIFY_RETRY_SECONDS)
         continue;

      // Broker distance rules: skip quietly and try again on a later tick
      double stopsLevel  = (double)SymbolInfoInteger(g_symbol, SYMBOL_TRADE_STOPS_LEVEL) * g_point;
      double freezeLevel = (double)SymbolInfoInteger(g_symbol, SYMBOL_TRADE_FREEZE_LEVEL) * g_point;
      double gapToNewSL  = (isBuy ? price - newSL : newSL - price);
      double gapToOldSL  = (isBuy ? price - sl : sl - price);
      double gapToTP     = (tp > 0.0 ? MathAbs(tp - price) : DBL_MAX);
      if(gapToNewSL <= stopsLevel ||
         (freezeLevel > 0.0 && (gapToOldSL <= freezeLevel || gapToTP <= freezeLevel)))
         continue;

      if(g_trade.PositionModify(ticket, newSL, tp))
        {
         Print("MANAGE: ", action, " - ", (isBuy ? "BUY" : "SELL"), " #", ticket,
               " SL moved ", FormatPrice(sl), " -> ", FormatPrice(newSL), " (TP unchanged ", FormatPrice(tp), ")");
         g_lastModifyFail = 0;
        }
      else
        {
         Print("MANAGE ERROR: could not move SL for #", ticket, ". Retcode ", g_trade.ResultRetcode(),
               " (", g_trade.ResultRetcodeDescription(), "). Retrying in ", MODIFY_RETRY_SECONDS, "s.");
         g_lastModifyFail = TimeCurrent();
        }
     }
  }

// Initial risk (price distance) = |open - SL of the opening order|. Fallback: TP distance / R:R.
double GetInitialRisk(long posId, double open, double tp)
  {
   if(posId == g_mgPositionId && g_mgRisk > 0.0)
      return(g_mgRisk);

   int idx = FindTradeIndex(posId);
   if(idx >= 0 && g_trades[idx].initialSL > 0.0)
     {
      g_mgPositionId = posId;
      g_mgRisk       = MathAbs(open - g_trades[idx].initialSL);
      return(g_mgRisk);
     }
   // Not cached: the history may not be updated yet on the first tick after entry
   if(tp > 0.0 && InpRiskReward > 0.0)
      return(MathAbs(tp - open) / InpRiskReward);
   return(0.0);
  }

//+------------------------------------------------------------------+
//| Statistics: rebuild every EA trade from the account history      |
//+------------------------------------------------------------------+
void RebuildStatistics()
  {
   ArrayResize(g_trades, 0);
   g_tradeCount = 0;

   if(!HistorySelect(0, TimeCurrent() + 86400))
     {
      Print("WARNING: could not load trade history (error ", GetLastError(), ").");
      ComputeOverallStats();
      return;
     }

   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
     {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0)
         continue;
      if(HistoryDealGetString(ticket, DEAL_SYMBOL) != g_symbol)
         continue;
      ENUM_DEAL_TYPE type = (ENUM_DEAL_TYPE)HistoryDealGetInteger(ticket, DEAL_TYPE);
      if(type != DEAL_TYPE_BUY && type != DEAL_TYPE_SELL)
         continue;

      ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(ticket, DEAL_ENTRY);
      long   posId = HistoryDealGetInteger(ticket, DEAL_POSITION_ID);
      // Entries must carry our magic; exits are matched by position id (a manual close has magic 0)
      if(entry == DEAL_ENTRY_IN && (ulong)HistoryDealGetInteger(ticket, DEAL_MAGIC) != InpMagicNumber)
         continue;
      double net   = HistoryDealGetDouble(ticket, DEAL_PROFIT)
                     + HistoryDealGetDouble(ticket, DEAL_SWAP)
                     + HistoryDealGetDouble(ticket, DEAL_COMMISSION);
      int idx = FindTradeIndex(posId);

      if(entry == DEAL_ENTRY_IN)
        {
         if(idx >= 0)
           {
            // Additional fill of the same position
            g_trades[idx].volume += HistoryDealGetDouble(ticket, DEAL_VOLUME);
            g_trades[idx].net    += net;
            continue;
           }
         ArrayResize(g_trades, g_tradeCount + 1, 256);
         idx = g_tradeCount;
         g_tradeCount++;
         g_trades[idx].positionId = posId;
         g_trades[idx].isBuy      = (type == DEAL_TYPE_BUY);
         g_trades[idx].openTime   = (datetime)HistoryDealGetInteger(ticket, DEAL_TIME);
         g_trades[idx].closeTime  = 0;
         g_trades[idx].openPrice  = HistoryDealGetDouble(ticket, DEAL_PRICE);
         g_trades[idx].closePrice = 0.0;
         g_trades[idx].volume     = HistoryDealGetDouble(ticket, DEAL_VOLUME);
         g_trades[idx].net        = net;
         g_trades[idx].rMultiple  = 0.0;
         g_trades[idx].hasR       = false;
         g_trades[idx].session    = ClassifySession(g_trades[idx].openTime);
         g_trades[idx].exitReason = -1;
         g_trades[idx].closed     = false;

         ulong  orderTicket = (ulong)HistoryDealGetInteger(ticket, DEAL_ORDER);
         g_trades[idx].initialSL  = HistoryOrderGetDouble(orderTicket, ORDER_SL);
         string comment = HistoryOrderGetString(orderTicket, ORDER_COMMENT);
         if(comment == "")
            comment = HistoryDealGetString(ticket, DEAL_COMMENT);
         g_trades[idx].spreadPips = SpreadFromComment(comment);
         continue;
        }

      if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY || entry == DEAL_ENTRY_INOUT)
        {
         if(idx < 0)
            continue;                         // opened before the available history
         g_trades[idx].net       += net;
         g_trades[idx].closeTime  = (datetime)HistoryDealGetInteger(ticket, DEAL_TIME);
         g_trades[idx].closePrice = HistoryDealGetDouble(ticket, DEAL_PRICE);
         g_trades[idx].exitReason = (int)HistoryDealGetInteger(ticket, DEAL_REASON);
         g_trades[idx].closed     = true;
        }
     }

   // R multiple = net result / money that was at risk with the initial SL
   for(int k = 0; k < g_tradeCount; k++)
     {
      if(!g_trades[k].closed || g_trades[k].initialSL <= 0.0)
         continue;
      double profit = 0.0;
      ENUM_ORDER_TYPE type = (g_trades[k].isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
      if(OrderCalcProfit(type, g_symbol, g_trades[k].volume, g_trades[k].openPrice, g_trades[k].initialSL, profit) &&
         profit < 0.0)
        {
         g_trades[k].rMultiple = g_trades[k].net / (-profit);
         g_trades[k].hasR      = true;
        }
     }

   ComputeOverallStats();
  }

// Search from the end: with one position at a time the match is almost always the last record
int FindTradeIndex(long positionId)
  {
   for(int i = g_tradeCount - 1; i >= 0; i--)
      if(g_trades[i].positionId == positionId)
         return(i);
   return(-1);
  }

double SpreadFromComment(const string comment)
  {
   int pos = StringFind(comment, " sp");
   if(pos < 0)
      return(-1.0);
   return(StringToDouble(StringSubstr(comment, pos + 3)));
  }

void ResetGroup(GroupStats &g)
  {
   g.trades      = 0;
   g.wins        = 0;
   g.losses      = 0;
   g.grossProfit = 0.0;
   g.grossLoss   = 0.0;
   g.sumR        = 0.0;
   g.countR      = 0;
   g.sumSpread   = 0.0;
   g.countSpread = 0;
  }

void AddToGroup(GroupStats &g, const TradeRecord &t)
  {
   g.trades++;
   if(t.net > 0.0)
     {
      g.wins++;
      g.grossProfit += t.net;
     }
   else
      if(t.net < 0.0)
        {
         g.losses++;
         g.grossLoss += -t.net;
        }
   if(t.hasR)
     {
      g.sumR += t.rMultiple;
      g.countR++;
     }
   if(t.spreadPips >= 0.0)
     {
      g.sumSpread += t.spreadPips;
      g.countSpread++;
     }
  }

void ComputeOverallStats()
  {
   ResetGroup(g_stats.all);
   ResetGroup(g_stats.buy);
   ResetGroup(g_stats.sell);
   for(int s = 0; s < STAT_SESSION_COUNT; s++)
      ResetGroup(g_stats.session[s]);
   g_stats.maxDrawdown     = 0.0;
   g_stats.maxDrawdownPct  = 0.0;
   g_stats.maxConsecLosses = 0;
   g_stats.avgTradesPerDay = 0.0;
   g_stats.lastLossTime    = 0;

   double totalNet = 0.0;
   for(int i = 0; i < g_tradeCount; i++)
      if(g_trades[i].closed)
         totalNet += g_trades[i].net;
   // Balance before the first EA trade (approximate: ignores deposits and other trades)
   double startBalance = AccountInfoDouble(ACCOUNT_BALANCE) - totalNet;

   double cumulative = 0.0, peak = 0.0;
   int consecutive = 0;
   datetime firstOpen = 0;

   for(int i = 0; i < g_tradeCount; i++)
     {
      if(!g_trades[i].closed)
         continue;
      if(firstOpen == 0)
         firstOpen = g_trades[i].openTime;

      AddToGroup(g_stats.all, g_trades[i]);
      if(g_trades[i].isBuy)
         AddToGroup(g_stats.buy, g_trades[i]);
      else
         AddToGroup(g_stats.sell, g_trades[i]);
      AddToGroup(g_stats.session[g_trades[i].session], g_trades[i]);

      cumulative += g_trades[i].net;
      if(cumulative > peak)
         peak = cumulative;
      double drawdown = peak - cumulative;
      if(drawdown > g_stats.maxDrawdown)
         g_stats.maxDrawdown = drawdown;
      double peakEquity = startBalance + peak;
      if(peakEquity > 0.0 && drawdown / peakEquity * 100.0 > g_stats.maxDrawdownPct)
         g_stats.maxDrawdownPct = drawdown / peakEquity * 100.0;

      if(g_trades[i].net < 0.0)
        {
         consecutive++;
         if(consecutive > g_stats.maxConsecLosses)
            g_stats.maxConsecLosses = consecutive;
         g_stats.lastLossTime = g_trades[i].closeTime;
        }
      else
         consecutive = 0;
     }

   if(firstOpen > 0)
     {
      int weekdays = CountWeekdays(firstOpen, TimeCurrent());
      if(weekdays > 0)
         g_stats.avgTradesPerDay = (double)g_stats.all.trades / weekdays;
     }
  }

int CountWeekdays(datetime from, datetime to)
  {
   long firstDay = (long)from / 86400;
   long lastDay  = (long)to / 86400;
   if(lastDay < firstDay)
      return(0);
   long days  = lastDay - firstDay + 1;
   int  count = (int)(days / 7) * 5;               // full weeks
   MqlDateTime dt;
   TimeToStruct((datetime)(firstDay * 86400), dt);
   int dow = dt.day_of_week;                        // 0 = Sunday
   for(long r = 0; r < days % 7; r++)               // remaining days
     {
      int d = (int)((dow + r) % 7);
      if(d >= 1 && d <= 5)
         count++;
     }
   return(count);
  }

string GroupLine(const string name, const GroupStats &g)
  {
   if(g.trades == 0)
      return(StringFormat("%-18s: no trades", name));
   double winRate = 100.0 * g.wins / g.trades;
   double pf      = (g.grossLoss > 0.0 ? g.grossProfit / g.grossLoss : 0.0);
   string pfText  = (g.grossLoss > 0.0 ? StringFormat("%.2f", pf) : "n/a");
   double avgWin  = (g.wins > 0 ? g.grossProfit / g.wins : 0.0);
   double avgLoss = (g.losses > 0 ? -g.grossLoss / g.losses : 0.0);
   string avgR    = (g.countR > 0 ? StringFormat("%+.2f", g.sumR / g.countR) : "n/a");
   string avgSpr  = (g.countSpread > 0 ? StringFormat("%.1f", g.sumSpread / g.countSpread) : "n/a");
   return(StringFormat("%-18s: %d trades | W %d / L %d | win %.1f%% | net %.2f | PF %s | avg win %.2f | avg loss %.2f | avg R %s | avg spread %s",
                       name, g.trades, g.wins, g.losses, winRate, g.grossProfit - g.grossLoss, pfText,
                       avgWin, avgLoss, avgR, avgSpr));
  }

void PrintStatisticsReport()
  {
   Print("================ GoldBot V2 statistics (", g_symbol, ", magic ", InpMagicNumber, ") ================");
   Print(GroupLine("ALL", g_stats.all));
   Print(StringFormat("Max drawdown (closed trades): %.2f %s (%.2f%%) | Max consecutive losses: %d | Avg trades per weekday: %.2f",
                      g_stats.maxDrawdown, AccountInfoString(ACCOUNT_CURRENCY), g_stats.maxDrawdownPct,
                      g_stats.maxConsecLosses, g_stats.avgTradesPerDay));
   Print(GroupLine("BUY", g_stats.buy));
   Print(GroupLine("SELL", g_stats.sell));
   for(int s = 0; s < STAT_SESSION_COUNT; s++)
      Print(GroupLine(SessionName(s), g_stats.session[s]));
   Print("Sessions are classified by entry time using the London/New York windows (server time).");
   Print("These are historical results only. They do not predict future performance.");
   Print("=====================================================================================");
  }

string ExitReasonText(const TradeRecord &t)
  {
   if(t.exitReason == DEAL_REASON_TP)
      return("hit Take Profit");
   if(t.exitReason == DEAL_REASON_SL)
     {
      if(t.hasR && t.rMultiple > -0.5)
         return("hit moved SL (break-even/trailing)");
      return("hit Stop Loss");
     }
   if(t.exitReason == DEAL_REASON_SO)
      return("stopped out by broker (margin)");
   return("closed manually/other");
  }

void WriteTradesCSV()
  {
   string fileName = StringFormat("GoldBotV2_trades_%s_%s.csv", g_symbol, (string)InpMagicNumber);
   int handle = FileOpen(fileName, FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_COMMON, ',');
   if(handle == INVALID_HANDLE)
     {
      Print("WARNING: could not write ", fileName, " (error ", GetLastError(), ").");
      return;
     }
   FileWrite(handle, "position", "direction", "session", "open_time", "close_time", "open_price", "close_price",
             "initial_sl", "volume", "spread_pips", "net", "r_multiple", "exit");
   int written = 0;
   for(int i = 0; i < g_tradeCount; i++)
     {
      if(!g_trades[i].closed)
         continue;
      FileWrite(handle,
                (string)g_trades[i].positionId,
                (g_trades[i].isBuy ? "BUY" : "SELL"),
                SessionName(g_trades[i].session),
                TimeToString(g_trades[i].openTime, TIME_DATE | TIME_MINUTES),
                TimeToString(g_trades[i].closeTime, TIME_DATE | TIME_MINUTES),
                DoubleToString(g_trades[i].openPrice, g_digits),
                DoubleToString(g_trades[i].closePrice, g_digits),
                DoubleToString(g_trades[i].initialSL, g_digits),
                DoubleToString(g_trades[i].volume, 2),
                DoubleToString(g_trades[i].spreadPips, 1),
                DoubleToString(g_trades[i].net, 2),
                (g_trades[i].hasR ? DoubleToString(g_trades[i].rMultiple, 2) : ""),
                ExitReasonText(g_trades[i]));
      written++;
     }
   FileClose(handle);
   Print("Trade list written: ", written, " trades -> <Common Data Folder>\\Files\\", fileName);
  }

//+------------------------------------------------------------------+
//| Checklist log                                                    |
//+------------------------------------------------------------------+
void InitCheck(SetupCheck &c, bool isBuy)
  {
   c.isBuy        = isBuy;
   c.trendText    = "";
   c.trendScore   = 0;
   c.zoneOk       = false;
   c.zoneText     = "";
   c.zoneScore    = 0;
   c.candleOk     = false;
   c.candleText   = "";
   c.candleScore  = 0;
   c.emaOk        = false;
   c.emaText      = "";
   c.emaScore     = 0;
   c.atrOk        = false;
   c.atrText      = "";
   c.atrScore     = 0;
   c.chaseOk      = false;
   c.chaseText    = "";
   c.slOk         = false;
   c.slText       = "";
   c.spreadOk     = false;
   c.spreadText   = "";
   c.score        = 0;
   c.scoreOk      = false;
   c.timeOk       = false;
   c.timeText     = "";
   c.riskOk       = false;
   c.riskText     = "";
   c.positionOk   = false;
   c.positionText = "";
   c.slDistance   = 0.0;
   c.spreadPips   = 0.0;
   c.failures     = "";
  }

void AddFailure(SetupCheck &c, const string reason)
  {
   if(c.failures != "")
      c.failures += "; ";
   c.failures += reason;
  }

string Mark(bool ok)
  {
   return(ok ? "[OK]" : "[X] ");
  }

string Points(int points)
  {
   return(points > 0 ? StringFormat("  +%d", points) : "");
  }

void PrintSetupCheck(const SetupCheck &c, bool accepted)
  {
   string direction = (c.isBuy ? "BUY" : "SELL");
   // EMA line shows [--] when the EMA is optional and not confirmed
   string emaMark = (c.emaScore > 0 ? "[OK]" : (c.emaOk ? "[--]" : "[X] "));

   Print(g_candleLabel, (accepted ? "SETUP CHECK - " : "SETUP REJECTED - "), direction);
   Print("   Trend    ", Mark(true), " ", c.trendText, Points(c.trendScore));
   Print("   Zone     ", Mark(c.zoneOk), " ", c.zoneText, Points(c.zoneScore));
   Print("   Candle   ", Mark(c.candleOk), " ", c.candleText, Points(c.candleScore));
   Print("   EMA", InpEntryEMA, "     ", emaMark, " ", c.emaText, Points(c.emaScore));
   Print("   ATR      ", Mark(c.atrOk), " ", c.atrText, Points(c.atrScore));
   Print("   Entry    ", Mark(c.chaseOk), " ", c.chaseText);
   Print("   StopLoss ", Mark(c.slOk), " ", c.slText);
   Print("   Spread   ", Mark(c.spreadOk), " ", c.spreadText);
   Print("   Score    ", Mark(c.scoreOk), " ", StringFormat("%d/100 (minimum %d)", c.score, InpMinScore));
   Print("   Time     ", Mark(c.timeOk), " ", c.timeText);
   Print("   Risk     ", Mark(c.riskOk), " ", c.riskText);
   Print("   Position ", Mark(c.positionOk), " ", c.positionText);
   if(accepted)
      Print("   ACTION: ", direction);
   else
      Print("   ACTION: NO TRADE - Reason: ", c.failures, ".");
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
      trendText = (g_trendStrong ? "BULLISH (strong)" : "BULLISH (pullback)");
   else
      if(g_trend == TREND_BEARISH)
         trendText = (g_trendStrong ? "BEARISH (strong)" : "BEARISH (pullback)");

   string setupText = "WAITING";
   if(g_setupState == SETUP_BUY)
      setupText = "BUY";
   else
      if(g_setupState == SETUP_SELL)
         setupText = "SELL";

   string currency = AccountInfoString(ACCOUNT_CURRENCY);
   double dayPL    = g_daily.realizedPL + g_daily.floatingPL;
   double dayPct   = (g_dayStartBalance > 0.0 ? dayPL / g_dayStartBalance * 100.0 : 0.0);
   double spread   = CurrentSpreadPips();

   string status = "ACTIVE";
   datetime until = 0;
   if(g_tradingStopped)
      status = "STOPPED - " + g_stopReason;
   else
      if(IsInCooldown(until))
         status = "COOLDOWN until " + TimeToString(until, TIME_MINUTES);

   int nowMin = MinutesOfDay(TimeCurrent());
   string sessionState = (IsInTradingSession(nowMin) ? "IN" : "OUT");
   if(IsNewsBlackout(nowMin))
      sessionState = "NEWS BLACKOUT";

   string text = "XAUUSD V2  (" + g_symbol + ")\n";
   text += "------------------------------\n";
   text += "Trend: " + trendText + "\n";
   text += "Setup: " + setupText + "\n";
   text += StringFormat("Score: %d/100 (min %d)\n", g_lastScore, InpMinScore);
   text += StringFormat("ATR: %.1f pips (min %.0f / max %s)\n", g_atr / g_pipSize, InpMinATRPips,
                        (InpMaxATRPips > 0.0 ? DoubleToString(InpMaxATRPips, 0) : "off"));
   text += (spread >= 0.0 ? StringFormat("Spread: %.1f pips (max %.1f)\n", spread, InpMaxSpreadPips) : "Spread: n/a\n");
   text += "Session: " + SessionModeText() + " [" + sessionState + "]\n";
   text += "------------------------------\n";
   text += StringFormat("Today's Trades: %d / %d\n", g_daily.tradesToday, InpMaxTradesPerDay);
   text += StringFormat("Today's Wins: %d\n", g_daily.winsToday);
   text += StringFormat("Today's Losses: %d\n", g_daily.lossesToday);
   text += StringFormat("Today's P/L: %.2f %s (%.2f%%)\n", dayPL, currency, dayPct);
   text += StringFormat("Consecutive Losses: %d / %d\n", g_daily.consecutiveLosses, InpMaxConsecutiveLosses);
   text += "Daily Status: " + status + "\n";
   text += "Current Position: " + CurrentPositionText() + "\n";
   text += (InpLotMode == LOT_MODE_RISK ? StringFormat("Risk: %.2f%% per trade\n", InpRiskPercent)
                                        : StringFormat("Risk: fixed %.2f lots\n", InpFixedLotSize));
   text += "------------------------------\n";
   if(g_stats.all.trades > 0)
     {
      double pf = (g_stats.all.grossLoss > 0.0 ? g_stats.all.grossProfit / g_stats.all.grossLoss : 0.0);
      text += StringFormat("All trades: %d | Win %.1f%% | PF %s\n", g_stats.all.trades,
                           100.0 * g_stats.all.wins / g_stats.all.trades,
                           (g_stats.all.grossLoss > 0.0 ? DoubleToString(pf, 2) : "n/a"));
      text += StringFormat("Net: %.2f | Max DD: %.2f | Avg R: %s\n",
                           g_stats.all.grossProfit - g_stats.all.grossLoss, g_stats.maxDrawdown,
                           (g_stats.all.countR > 0 ? StringFormat("%+.2f", g_stats.all.sumR / g_stats.all.countR) : "n/a"));
      text += StringFormat("BUY: %d (net %.2f) | SELL: %d (net %.2f)\n",
                           g_stats.buy.trades, g_stats.buy.grossProfit - g_stats.buy.grossLoss,
                           g_stats.sell.trades, g_stats.sell.grossProfit - g_stats.sell.grossLoss);
     }
   else
      text += "All trades: none yet\n";
   text += "Last: " + g_lastDecision;

   Comment(text);
  }

string CurrentPositionText()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol)
         continue;
      bool own    = ((ulong)PositionGetInteger(POSITION_MAGIC) == InpMagicNumber);
      bool isBuy  = ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl   = PositionGetDouble(POSITION_SL);
      bool slInProfit = (sl > 0.0 && (isBuy ? sl >= open : sl <= open));
      return(StringFormat("%s %.2f @ %s%s%s", (isBuy ? "BUY" : "SELL"), PositionGetDouble(POSITION_VOLUME),
                          FormatPrice(open), (slInProfit ? " [SL protected]" : ""), (own ? "" : " (not this EA)")));
     }
   return("NONE");
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

double PipsToPrice(double pips)
  {
   return(pips * g_pipSize);
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
//| Time parsing: "HH:MM" and "HH:MM-HH:MM" (24:00 allowed as end)    |
//+------------------------------------------------------------------+
bool IsDigits(const string s)
  {
   int len = StringLen(s);
   if(len == 0 || len > 2)
      return(false);
   for(int i = 0; i < len; i++)
     {
      ushort ch = StringGetCharacter(s, i);
      if(ch < '0' || ch > '9')
         return(false);
     }
   return(true);
  }

bool ParseTime(const string text, int &minutes)
  {
   string t = text;
   StringTrimLeft(t);
   StringTrimRight(t);
   string parts[];
   if(StringSplit(t, ':', parts) != 2)
      return(false);
   if(!IsDigits(parts[0]) || !IsDigits(parts[1]))
      return(false);
   int h = (int)StringToInteger(parts[0]);
   int m = (int)StringToInteger(parts[1]);
   if(m < 0 || m > 59 || h < 0 || h > 24 || (h == 24 && m != 0))
      return(false);
   minutes = h * 60 + m;
   return(true);
  }

bool ParseRange(const string text, int &startMin, int &endMin)
  {
   string parts[];
   if(StringSplit(text, '-', parts) != 2)
      return(false);
   return(ParseTime(parts[0], startMin) && ParseTime(parts[1], endMin));
  }

//+------------------------------------------------------------------+
//| Input validation                                                 |
//+------------------------------------------------------------------+
bool ValidateInputs()
  {
   bool ok = true;
   if(!InpAllowBuy && !InpAllowSell)
     { Print("INPUT ERROR: both BUY and SELL are disabled."); ok = false; }
   if(InpTrendFastEMA <= 0 || InpTrendSlowEMA <= 0 || InpTrendFastEMA >= InpTrendSlowEMA)
     { Print("INPUT ERROR: trend EMA periods must be > 0 and fast < slow."); ok = false; }
   if(InpEntryEMA <= 0 || InpATRPeriod <= 0)
     { Print("INPUT ERROR: entry EMA and ATR periods must be > 0."); ok = false; }
   if(InpMinATRPips < 0.0 || InpMaxATRPips < 0.0 || (InpMaxATRPips > 0.0 && InpMaxATRPips <= InpMinATRPips))
     { Print("INPUT ERROR: ATR limits must be >= 0 and max ATR (if used) above min ATR."); ok = false; }
   if(InpSwingStrength < 1 || InpSwingStrength > 10)
     { Print("INPUT ERROR: swing strength must be between 1 and 10."); ok = false; }
   if(InpSwingLookbackBars < InpSwingStrength * 2 + 5 || InpSwingLookbackBars > 1000)
     { Print("INPUT ERROR: swing lookback must be between (2 x strength + 5) and 1000 bars."); ok = false; }
   if(InpZoneMergePips < 0.0 || InpZoneDistancePips <= 0.0 || InpMaxDistanceFromZonePips <= 0.0)
     { Print("INPUT ERROR: zone merge must be >= 0; zone distance and max distance from zone must be > 0."); ok = false; }
   if(InpMinScore < 0 || InpMinScore > 100)
     { Print("INPUT ERROR: minimum score must be 0-100."); ok = false; }
   if(InpFixedSLPips <= 0.0 || InpATRSLMultiplier <= 0.0 || InpSLBufferPips < 0.0 || InpMaxStopLossPips <= 0.0)
     { Print("INPUT ERROR: SL settings must be positive (buffer may be 0)."); ok = false; }
   if(InpSLMode == SL_MODE_FIXED && InpFixedSLPips > InpMaxStopLossPips)
     { Print("INPUT ERROR: fixed SL is larger than the maximum SL, so no trade could ever be taken."); ok = false; }
   if(InpRiskReward < 1.0 || InpRiskReward > 10.0)
     { Print("INPUT ERROR: risk:reward must be between 1.0 and 10.0."); ok = false; }
   if(InpBreakEvenAtR <= 0.0 || InpBreakEvenBufferPips < 0.0)
     { Print("INPUT ERROR: break-even trigger must be > 0 and buffer >= 0."); ok = false; }
   if(InpTrailStartR <= 0.0 || InpTrailATRMultiplier <= 0.0)
     { Print("INPUT ERROR: trailing start and ATR multiplier must be > 0."); ok = false; }
   if(InpRiskPercent <= 0.0 || InpRiskPercent > 5.0)
     { Print("INPUT ERROR: risk per trade must be > 0 and <= 5%."); ok = false; }
   if(InpMaxLotSize <= 0.0)
     { Print("INPUT ERROR: safety lot cap must be > 0."); ok = false; }
   if(InpFixedLotSize <= 0.0 || InpFixedLotSize > InpMaxLotSize)
     { Print("INPUT ERROR: fixed lot must be > 0 and not above the safety cap."); ok = false; }
   if(InpMaxDailyLossPercent <= 0.0 || InpMaxDailyLossPercent > 100.0 || InpMaxDailyProfitPercent < 0.0)
     { Print("INPUT ERROR: max daily loss must be 0-100% and daily profit boundary >= 0."); ok = false; }
   if(InpMaxConsecutiveLosses < 1 || InpMaxTradesPerDay < 1 || InpCooldownAfterLossMinutes < 0)
     { Print("INPUT ERROR: consecutive losses and trades per day must be >= 1; cooldown >= 0."); ok = false; }
   if(InpMaxSpreadPips <= 0.0 || InpMaxSlippagePips < 0.0)
     { Print("INPUT ERROR: max spread must be > 0 and slippage >= 0."); ok = false; }
   if(InpPipSize < 0.0)
     { Print("INPUT ERROR: pip size cannot be negative (0 = automatic)."); ok = false; }

   if(!ParseRange(InpLondonSession, g_londonStart, g_londonEnd))
     { Print("INPUT ERROR: London session must look like 10:00-19:00."); ok = false; }
   if(!ParseRange(InpNewYorkSession, g_nyStart, g_nyEnd))
     { Print("INPUT ERROR: New York session must look like 15:00-22:00."); ok = false; }
   if(!ParseRange(InpCustomSession, g_customStart, g_customEnd))
     { Print("INPUT ERROR: custom session must look like 09:00-21:00."); ok = false; }
   if(!ParseTime(InpNewsStartTime, g_newsStart) || !ParseTime(InpNewsEndTime, g_newsEnd))
     { Print("INPUT ERROR: news times must look like 15:25."); ok = false; }

   if(ok && InpTrailingEnabled && InpBreakEvenEnabled && InpTrailStartR < InpBreakEvenAtR)
      Print("NOTE: trailing starts before break-even. That is allowed but more aggressive.");
   return(ok);
  }

//+------------------------------------------------------------------+
//| Startup summary - verify the pip conversion here!                |
//+------------------------------------------------------------------+
void PrintSettings()
  {
   Print("================ GoldBot V2 started ================");
   Print("Symbol: ", g_symbol, " | Digits: ", g_digits, " | Point: ", DoubleToString(g_point, g_digits),
         " | Contract size: ", DoubleToString(SymbolInfoDouble(g_symbol, SYMBOL_TRADE_CONTRACT_SIZE), 2));
   Print(StringFormat("1 pip = %s price = %.1f points%s",
                      DoubleToString(g_pipSize, (g_digits > 2 ? g_digits : 2)), g_pipSize / g_point,
                      (InpPipSize > 0.0 ? " (manual)" : " (auto)")));
   Print(StringFormat("Trend: H1 EMA%d/%d | Entry timing: M15 EMA%d (%s) | ATR(%d) M15 limits %.0f-%s pips",
                      InpTrendFastEMA, InpTrendSlowEMA, InpEntryEMA,
                      (InpRequireEMAConfirm ? "required" : "score only"), InpATRPeriod, InpMinATRPips,
                      (InpMaxATRPips > 0.0 ? DoubleToString(InpMaxATRPips, 0) : "no max")));
   Print(StringFormat("Zones: swing strength %d, lookback %d bars, merge %.0f pips, reach %.0f pips, max chase %.0f pips",
                      InpSwingStrength, InpSwingLookbackBars, InpZoneMergePips, InpZoneDistancePips,
                      InpMaxDistanceFromZonePips));
   Print(StringFormat("SL: %s%s, buffer %.0f pips, max %.0f pips | TP: %.1fR | Min score %d",
                      (InpSLMode == SL_MODE_FIXED ? StringFormat("fixed %.1f pips", InpFixedSLPips)
                                                  : StringFormat("ATR x %.2f", InpATRSLMultiplier)),
                      (InpUseStructureSL ? " or beyond zone" : ""), InpSLBufferPips, InpMaxStopLossPips,
                      InpRiskReward, InpMinScore));
   Print(StringFormat("Management: break-even %s | trailing %s",
                      (InpBreakEvenEnabled ? StringFormat("at %.1fR (+%.1f pips)", InpBreakEvenAtR, InpBreakEvenBufferPips) : "off"),
                      (InpTrailingEnabled ? StringFormat("from %.1fR at ATR x %.1f", InpTrailStartR, InpTrailATRMultiplier) : "off")));
   Print("Lots: min ", DoubleToString(SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MIN), 2),
         " / max ", DoubleToString(SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MAX), 2),
         " / step ", DoubleToString(SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_STEP), 2),
         " | Mode: ", (InpLotMode == LOT_MODE_RISK ? StringFormat("RISK %.2f%%", InpRiskPercent)
                                                  : StringFormat("FIXED %.2f", InpFixedLotSize)),
         " | Safety cap: ", DoubleToString(InpMaxLotSize, 2));
   double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   if(bid > 0.0)
     {
      double lossPerLotPerPip = LossPerLot(false, bid, bid + g_pipSize);
      if(lossPerLotPerPip > 0.0)
         Print(StringFormat("Value of 1 pip: %.2f %s per 1.00 lot (%.2f per 0.01 lot)",
                            lossPerLotPerPip, AccountInfoString(ACCOUNT_CURRENCY), lossPerLotPerPip / 100.0));
     }
   Print(StringFormat("Daily: max loss %.2f%% | profit boundary %s | %d consecutive losses | %d trades/day | cooldown %d min",
                      InpMaxDailyLossPercent,
                      (InpMaxDailyProfitPercent > 0.0 ? StringFormat("%.2f%%", InpMaxDailyProfitPercent) : "off"),
                      InpMaxConsecutiveLosses, InpMaxTradesPerDay, InpCooldownAfterLossMinutes));
   Print("Direction: BUY ", (InpAllowBuy ? "on" : "off"), " / SELL ", (InpAllowSell ? "on" : "off"),
         " | Session: ", SessionModeText(), " | News blackout: ",
         (InpNewsFilterEnabled ? InpNewsStartTime + "-" + InpNewsEndTime : "off"),
         " | Max spread: ", DoubleToString(InpMaxSpreadPips, 1), " pips");
   Print("History: ", g_stats.all.trades, " closed trades found for this EA (magic ", InpMagicNumber, ").");
   Print("Setups are evaluated once per closed M15 candle. Max open positions: ", MAX_OPEN_POSITIONS);
   Print("====================================================");
  }
//+------------------------------------------------------------------+
