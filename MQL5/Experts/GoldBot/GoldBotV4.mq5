//+------------------------------------------------------------------+
//|                                                   GoldBotV4.mq5  |
//|     Rule-based XAUUSD Expert Advisor - Version 4                 |
//|                                                                  |
//|  Two profiles, same engine and the same risk protections:        |
//|    SCALP M5  : M15 trend + pullback to the M5 EMA 21 + M5        |
//|                reaction candle + EMA 9 timing, 1.5R targets      |
//|    SWING M15 : H1 trend + M15 swing S/R zone + reaction candle   |
//|                + EMA 9 timing, 4R (V3 rules, ATR-scaled limits)  |
//|                                                                  |
//|  V4 fixes the V3 problem found in testing: distance limits in    |
//|  fixed pips blocked every setup once gold volatility doubled.    |
//|  All distance limits are now multiples of ATR.                   |
//|                                                                  |
//|  NO martingale, NO grid, NO averaging down, NO hedging,          |
//|  NO recovery logic, NO lot increase after losses, NO AI.         |
//|  More trades is NOT more profit: costs matter more when scalping.|
//|                                                                  |
//|  FOR DEMO TESTING. No profitability is implied or guaranteed.    |
//+------------------------------------------------------------------+
#property copyright   "GoldBot V4"
#property version     "4.00"
#property description "Rule-based XAUUSD EA. Profiles: Scalp M5 (EMA pullback, 1.5R) or Swing M15 (S/R zones, 4R)."
#property description "Distance limits scale with ATR. One position max, daily limits, cost-aware statistics."
#property description "For demo testing only. No profitability is implied."

#include <Trade/Trade.mqh>

//+------------------------------------------------------------------+
//| Enumerations                                                     |
//+------------------------------------------------------------------+
enum ENUM_LOT_MODE
  {
   LOT_MODE_RISK  = 0,   // Risk-based (% of the lower of balance/equity)
   LOT_MODE_FIXED = 1    // Fixed lot size
  };

enum ENUM_SL_MODE
  {
   SL_MODE_FIXED = 0,    // Fixed pips
   SL_MODE_ATR   = 1     // ATR x multiplier
  };

enum ENUM_TREND_MODE
  {
   TREND_MODE_EMA_BOTH = 0, // EMA55 + EMA200 (default)
   TREND_MODE_EMA200   = 1, // EMA200 only (test)
   TREND_MODE_OFF      = 2  // OFF - no trend filter (test only)
  };

enum ENUM_CONFIRM_MODE
  {
   CONFIRM_ALL       = 0, // Rejection, engulfing or strong candle
   CONFIRM_REACTION  = 1, // Rejection or engulfing only
   CONFIRM_REJECTION = 2  // Rejection only
  };

enum ENUM_REGIME_FILTER
  {
   REGIME_FILTER_ALL         = 0, // Trade all ATR regimes
   REGIME_FILTER_NOT_LOW     = 1, // Skip LOW ATR regime
   REGIME_FILTER_NOT_HIGH    = 2, // Skip HIGH ATR regime
   REGIME_FILTER_NORMAL_ONLY = 3  // NORMAL ATR regime only
  };

enum ENUM_TRAIL_MODE
  {
   TRAIL_OFF   = 0,      // Off
   TRAIL_ATR   = 1,      // ATR x multiplier
   TRAIL_FIXED = 2       // Fixed pips
  };

enum ENUM_SESSION_MODE
  {
   SESSION_LONDON    = 0, // London
   SESSION_NEWYORK   = 1, // New York
   SESSION_LONDON_NY = 2, // London + New York
   SESSION_CUSTOM    = 3, // Custom
   SESSION_ALL_DAY   = 4  // All day (test only)
  };

enum ENUM_PROFILE
  {
   PROFILE_SCALP_M5  = 0, // Scalp M5 (fast, more trades, 1.5R)
   PROFILE_SWING_M15 = 1, // Swing M15 (V3 rules, ATR-scaled distances, 4R)
   PROFILE_CUSTOM    = 2  // Custom (use the inputs marked [custom])
  };

enum ENUM_ZONE_SOURCE
  {
   ZONE_SWING        = 0, // Swing support/resistance zones
   ZONE_EMA_PULLBACK = 1  // Pullback to the entry-timeframe EMA
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
input group "=== Profile ==="
input ENUM_PROFILE       InpProfile                 = PROFILE_SCALP_M5; // Strategy profile

input group "=== Symbol / master switch ==="
input string             InpSymbol                  = "";          // Symbol (empty = chart symbol / auto-detect gold)
input double             InpPipSize                 = 0.0;         // Price value of 1 pip (0 = auto: 0.10 for gold)
input bool               InpTradingEnabled          = true;        // Emergency switch: false = no new trades

input group "=== Direction ==="
input bool               InpAllowBuy                = true;        // Allow BUY trades
input bool               InpAllowSell               = true;        // Allow SELL trades

input group "=== [custom] Timeframes and setup ==="
input ENUM_TIMEFRAMES    InpEntryTF                 = PERIOD_M15;  // [custom] Entry timeframe
input ENUM_TIMEFRAMES    InpTrendTF                 = PERIOD_H1;   // [custom] Trend timeframe
input ENUM_ZONE_SOURCE   InpZoneSource              = ZONE_SWING;  // [custom] Zone source
input int                InpPullbackEMA             = 21;          // [custom] Pullback EMA period (EMA pullback zones)

input group "=== Trend ==="
input ENUM_TREND_MODE    InpTrendMode               = TREND_MODE_EMA_BOTH; // Trend filter
input int                InpTrendFastEMA            = 55;          // [custom] Trend fast EMA
input int                InpTrendSlowEMA            = 200;         // [custom] Trend slow EMA

input group "=== Zones (distances are multiples of ATR) ==="
input int                InpSwingStrength           = 3;           // Swing strength (bars on each side)
input int                InpSwingLookbackBars       = 150;         // Bars searched for swings
input double             InpZoneMergeATR            = 0.3;         // Swings closer than ATR x this form one zone
input double             InpZoneDistanceATR         = 0.3;         // Price must come within ATR x this of the zone
input bool               InpRequireMultiTouchZone   = false;       // Require a swing zone with 2+ reactions
input double             InpMaxDistanceFromZoneATR  = 1.5;         // Don't chase: max entry distance, ATR x this (0 = off)

input group "=== Confirmation and timing ==="
input ENUM_CONFIRM_MODE  InpConfirmMode             = CONFIRM_ALL; // Accepted confirmation candles
input int                InpEntryEMA                = 9;           // Entry timing EMA
input bool               InpRequireEMAConfirm       = true;        // Require close beyond entry EMA (else score only)

input group "=== Volatility (entry-timeframe ATR) ==="
input int                InpATRPeriod               = 14;          // ATR period
input double             InpMinATRToSpread          = 4.0;         // Skip if ATR < spread x this (dead market, 0 = off)
input double             InpMaxATRSpikeRatio        = 2.0;         // Skip if ATR > 24h average x this (spike, 0 = off)
input ENUM_REGIME_FILTER InpATRRegimeFilter         = REGIME_FILTER_ALL; // ATR regime filter (relative to 24h average)

input group "=== Quality score ==="
input int                InpMinScore                = 70;          // [custom] Minimum score to trade (0 = off)

input group "=== Stop loss / take profit ==="
input ENUM_SL_MODE       InpSLMode                  = SL_MODE_ATR; // Stop loss mode
input double             InpFixedSLPips             = 25.0;        // Fixed SL (pips) - fixed mode
input double             InpATRSLMultiplier         = 1.0;         // SL = ATR x this - ATR mode
input bool               InpUseStructureSL          = true;        // Place SL beyond the zone / reaction candles if further
input double             InpSLBufferATR             = 0.1;         // Extra distance beyond the zone, ATR x this
input double             InpMaxStopLossATR          = 2.5;         // Max SL, ATR x this - larger means NO TRADE
input double             InpRiskReward              = 4.0;         // [custom] Take profit = SL distance x this (R)

input group "=== Trade management ==="
input bool               InpBreakEvenEnabled        = true;        // Move SL to break-even
input double             InpBreakEvenAtR            = 1.0;         // ...when profit reaches this many R
input double             InpBreakEvenBufferPips     = 2.0;         // Break-even SL offset beyond entry (pips)
input ENUM_TRAIL_MODE    InpTrailMode               = TRAIL_OFF;   // Trailing stop
input double             InpTrailStartR             = 2.0;         // Start trailing at this many R
input double             InpTrailATRMultiplier      = 2.0;         // ATR trailing distance = ATR x this
input double             InpTrailFixedPips          = 50.0;        // Fixed trailing distance (pips)

input group "=== Position size ==="
input ENUM_LOT_MODE      InpLotMode                 = LOT_MODE_RISK; // Lot size mode
input double             InpRiskPercent             = 0.25;        // Risk per trade (%) - risk mode
input double             InpFixedLotSize            = 0.01;        // Fixed lot size - fixed mode
input double             InpMaxLotSize              = 1.00;        // Safety cap: never trade more than this

input group "=== Cost assumptions (sizing + statistics) ==="
input double             InpCommissionPerLot        = 0.0;         // Round-turn commission per 1.00 lot (account currency)
input double             InpSlippageAssumptionPips  = 1.0;         // Extra slippage per trade for cost-adjusted stats (pips)

input group "=== Daily protection (0 = off, for testing only) ==="
input double             InpMaxDailyLossPercent     = 2.0;         // Max daily loss, realized + floating (%)
input double             InpMaxDailyProfitPercent   = 3.0;         // Daily profit boundary (%)
input int                InpMaxConsecutiveLosses    = 3;           // [custom] Stop for the day after N losses in a row
input int                InpMaxTradesPerDay         = 3;           // [custom] Max new trades per day
input int                InpCooldownAfterLossMinutes= 30;          // [custom] Wait after a losing trade (minutes)

input group "=== Account protection ==="
input double             InpMaxAccountDrawdownPercent = 10.0;      // Halt new trades at this equity drawdown from peak (%, 0 = off)
input bool               InpResetAccountProtection  = false;       // Reset the stored equity peak / halt on start

input group "=== Execution ==="
input double             InpMaxSpreadPips           = 5.0;         // Max allowed spread (pips)
input double             InpMaxSlippagePips         = 3.0;         // Max allowed slippage on entry (pips)
input ulong              InpMagicNumber             = 55200428;    // Magic number (V4 default differs from V1-V3)

input group "=== Sessions (broker/server time, HH:MM-HH:MM) ==="
input ENUM_SESSION_MODE  InpSessionMode             = SESSION_LONDON_NY; // Trading session
input string             InpLondonSession           = "10:00-19:00"; // London session (server time)
input string             InpNewYorkSession          = "15:00-22:00"; // New York session (server time)
input string             InpCustomSession           = "09:00-21:00"; // Custom session (server time)

input group "=== Manual news blackout (server time) ==="
input bool               InpNewsFilterEnabled       = false;       // Enable manual news blackout
input string             InpNewsStartTime           = "15:25";     // Blackout start (HH:MM)
input string             InpNewsEndTime             = "16:00";     // Blackout end (HH:MM)

input group "=== Display / reporting ==="
input bool               InpShowDashboard           = true;        // Show dashboard on chart
input bool               InpVerboseLog              = true;        // Log a WAIT reason on every closed candle
input bool               InpWriteReports            = true;        // Write report + trade CSV (Common\Files)
input string             InpReportTag               = "";          // Report file name tag (e.g. IS_2025_scalp)

//+------------------------------------------------------------------+
//| Constants (fixed by design)                                      |
//+------------------------------------------------------------------+
#define MAX_OPEN_POSITIONS    1
#define MAX_SEND_ATTEMPTS     2

#define STAT_LONDON           0
#define STAT_OVERLAP          1
#define STAT_NEWYORK          2
#define STAT_OTHER            3
#define STAT_SESSION_COUNT    4

#define CONF_REJECTION        0
#define CONF_ENGULFING        1
#define CONF_STRONG           2
#define CONF_COUNT            3

#define REGIME_LOW            0
#define REGIME_NORMAL         1
#define REGIME_HIGH           2
#define REGIME_COUNT          3

#define TRENDCLASS_PULLBACK   0
#define TRENDCLASS_STRONG     1
#define TRENDCLASS_NONE       2     // trend filter OFF and trade not aligned with the H1 trend
#define TRENDCLASS_COUNT      3

#define SCORE_BUCKET_COUNT    5     // <60, 60-69, 70-79, 80-89, 90-100

#define OUTCOME_LOSS         -1
#define OUTCOME_BE            0
#define OUTCOME_WIN           1

#define TRADE_COMMENT_PREFIX  "GoldBotV4"

// Candle shape (fractions of the candle's high-low range)
const double REJECTION_WICK_MIN      = 0.50;
const double REJECTION_OPPOSITE_MAX  = 0.30;
const double STRONG_BODY_MIN         = 0.60;
const double STRONG_CLOSE_ZONE       = 0.25;
const double CONFIRM_MIN_RANGE_ATR   = 0.50;

// ATR regime = ATR / average ATR of the last 24 hours of entry-timeframe bars
const double ATR_LOW_RATIO           = 0.80;
const double ATR_HIGH_RATIO          = 1.25;

const double MARGIN_USAGE_MAX        = 0.90;
const double TRAIL_STEP_OF_RISK      = 0.10;
const int    MODIFY_RETRY_SECONDS    = 30;
const double BREAKEVEN_BAND_R        = 0.10;  // |R| <= 0.10 counts as break-even, not win/loss

// Sample-size guidance thresholds
const int    SAMPLE_VERY_WEAK        = 30;
const int    SAMPLE_PRELIMINARY      = 50;
const int    SAMPLE_LIMITED          = 100;

// Quality score weights (max 100)
const int    SCORE_TREND_STRONG      = 30;
const int    SCORE_TREND_PULLBACK    = 15;
const int    SCORE_ZONE_MULTI        = 25;
const int    SCORE_ZONE_SINGLE       = 10;
const int    SCORE_ZONE_EMA          = 15;    // pullback to the entry-timeframe EMA (scalp)
const int    SCORE_CANDLE_REACTION   = 20;
const int    SCORE_CANDLE_STRONG     = 10;
const int    SCORE_EMA_CONFIRM       = 15;
const int    SCORE_ATR_OK            = 10;

//+------------------------------------------------------------------+
//| Data structures                                                  |
//+------------------------------------------------------------------+
struct Zone
  {
   double            bottom;
   double            top;
   int               touches;
  };

// Entry metadata that the account history cannot provide
struct TradeMeta
  {
   long              positionId;
   datetime          signalBar;
   int               score;
   double            atrPips;
   int               atrRegime;
   int               confirmType;
   int               trendClass;
   int               zoneTouches;
   double            distancePips;
   double            spreadPips;
   double            ask;
   double            bid;
   double            slPips;
   double            tpPips;
   double            estCommission;
   int               slMode;
   double            riskReward;
   double            riskMoney;
   bool              beMoved;
   bool              trailMoved;
  };

// One EA trade, rebuilt from the account history + metadata
struct TradeRecord
  {
   long              positionId;
   bool              isBuy;
   datetime          openTime;
   datetime          closeTime;
   double            openPrice;
   double            closePrice;
   double            initialSL;
   double            volume;
   double            gross;
   double            commission;
   double            swap;
   double            net;              // actual: gross + commission + swap
   double            netAdj;           // net after ESTIMATED extra costs
   double            riskMoney;        // money at risk at the initial SL (price move only)
   double            r;
   double            rAdj;
   bool              hasR;
   int               outcome;
   int               session;
   int               exitReason;
   bool              closed;
   bool              hasMeta;
   TradeMeta         meta;
  };

struct GroupStats
  {
   int               trades;
   int               wins;
   int               losses;
   int               breakevens;
   double            grossProfit;
   double            grossLoss;
   double            grossProfitAdj;
   double            grossLossAdj;
   double            netAdj;
   double            sumR;
   double            sumRAdj;
   int               countR;
   double            sumWinR;
   double            sumLossR;
   double            largestWin;
   double            largestLoss;
   double            sumSpread;
   int               countSpread;
   double            cumNet;
   double            peakNet;
   double            maxDD;           // drawdown of this group's own closed-trade curve
  };

struct DailyStats
  {
   int               tradesToday;
   int               winsToday;
   int               lossesToday;
   double            realizedPL;
   double            floatingPL;
   double            rToday;
   int               consecutiveLosses;
  };

struct SetupCheck
  {
   bool              isBuy;
   string            trendText;
   int               trendScore;
   int               trendClass;
   bool              zoneOk;
   string            zoneText;
   int               zoneScore;
   int               zoneTouches;
   bool              candleOk;
   string            candleText;
   int               candleScore;
   int               confirmType;
   bool              emaOk;
   string            emaText;
   int               emaScore;
   bool              atrOk;
   string            atrText;
   int               atrScore;
   bool              chaseOk;
   string            chaseText;
   double            distancePips;
   bool              slOk;
   string            slText;
   double            slDistance;
   bool              spreadOk;
   string            spreadText;
   double            spreadPips;
   int               score;
   bool              scoreOk;
   bool              timeOk;
   string            timeText;
   bool              riskOk;
   string            riskText;
   bool              accountOk;
   string            accountText;
   bool              positionOk;
   string            positionText;
   string            failures;
  };

//+------------------------------------------------------------------+
//| Global state                                                     |
//+------------------------------------------------------------------+
CTrade            g_trade;

// Effective settings: set by ApplyProfile() from the profile (or from the [custom] inputs)
ENUM_TIMEFRAMES   g_entryTF         = PERIOD_M15;
ENUM_TIMEFRAMES   g_trendTF         = PERIOD_H1;
ENUM_ZONE_SOURCE  g_zoneSource      = ZONE_SWING;
int               g_pullbackEMA     = 21;
int               g_trendFast       = 55;
int               g_trendSlow       = 200;
double            g_riskReward      = 4.0;
int               g_minScore        = 70;
int               g_maxConsecLosses = 3;
int               g_maxTradesPerDay = 3;
int               g_cooldownMin     = 30;
int               g_pullbackHandle  = INVALID_HANDLE;
int               g_atrRegimeBars   = 96;      // bars in 24 hours of the entry timeframe

string            g_symbol          = "";
double            g_point           = 0.0;
double            g_pipSize         = 0.0;
int               g_digits          = 0;
int               g_trendFastHandle = INVALID_HANDLE;
int               g_trendSlowHandle = INVALID_HANDLE;
int               g_entryEmaHandle  = INVALID_HANDLE;
int               g_atrHandle       = INVALID_HANDLE;
bool              g_isTester        = false;
bool              g_isFastTester    = false;
bool              g_initialized     = false;

int               g_londonStart = 0, g_londonEnd = 0;
int               g_nyStart     = 0, g_nyEnd     = 0;
int               g_customStart = 0, g_customEnd = 0;
int               g_newsStart   = 0, g_newsEnd   = 0;

datetime          g_lastBarTime         = 0;
datetime          g_lastTradedSignalBar = 0;   // signal candle of the last opened trade
string            g_candleLabel         = "";
double            g_atr                 = 0.0;
double            g_atrAverage          = 0.0;
int               g_atrRegime           = REGIME_NORMAL;

datetime          g_currentDay      = 0;
double            g_dayStartBalance = 0.0;
bool              g_tradingStopped  = false;
string            g_stopReason      = "";
DailyStats        g_daily;

double            g_peakEquity      = 0.0;
bool              g_peakDirty       = false;
bool              g_accountHalted   = false;
string            g_gvPeak          = "";
string            g_gvHalt          = "";
string            g_gvSignal        = "";

TradeMeta         g_meta[];
int               g_metaCount       = 0;
TradeRecord       g_trades[];
int               g_tradeCount      = 0;
bool              g_statsDirty      = true;
int               g_lastOwnPositions= -1;

// Summary (cheap, refreshed with the records)
GroupStats        g_summary;
datetime          g_lastLossTime    = 0;

// Full statistics (computed for reports)
GroupStats        g_statBuy;
GroupStats        g_statSell;
GroupStats        g_statSession[STAT_SESSION_COUNT];
GroupStats        g_statHour[24];
GroupStats        g_statDow[7];
GroupStats        g_statRegime[REGIME_COUNT];
GroupStats        g_statScore[SCORE_BUCKET_COUNT];
GroupStats        g_statConfirm[CONF_COUNT];
GroupStats        g_statTrend[TRENDCLASS_COUNT];
GroupStats        g_statZone[2];
GroupStats        g_statUnknownMeta;
int               g_yearKeys[];
GroupStats        g_statYear[];
int               g_monthKeys[];
GroupStats        g_statMonth[];
int               g_statMaxConsecLosses   = 0;
double            g_longestDDDays     = 0.0;
double            g_maxDDPct          = 0.0;
double            g_avgTradesPerDay   = 0.0;

ENUM_TREND_STATE  g_trend           = TREND_NEUTRAL;
bool              g_trendStrong     = false;
ENUM_SETUP_STATE  g_setupState      = SETUP_WAITING;
int               g_lastScore       = 0;
string            g_lastDecision    = "Waiting for the next closed candle";
datetime          g_lastDashUpdate  = 0;

long              g_mgPositionId    = -1;
double            g_mgRisk          = 0.0;
datetime          g_lastModifyFail  = 0;

//+------------------------------------------------------------------+
//| Profiles: fixed, documented values. CUSTOM uses the inputs.      |
//+------------------------------------------------------------------+
void ApplyProfile()
  {
   if(InpProfile == PROFILE_SCALP_M5)
     {
      g_entryTF         = PERIOD_M5;
      g_trendTF         = PERIOD_M15;
      g_zoneSource      = ZONE_EMA_PULLBACK;
      g_pullbackEMA     = 21;
      g_trendFast       = 50;
      g_trendSlow       = 200;
      g_riskReward      = 1.5;
      g_minScore        = 60;
      g_maxConsecLosses = 5;
      g_maxTradesPerDay = 20;
      g_cooldownMin     = 10;
     }
   else
      if(InpProfile == PROFILE_SWING_M15)
        {
         g_entryTF         = PERIOD_M15;
         g_trendTF         = PERIOD_H1;
         g_zoneSource      = ZONE_SWING;
         g_pullbackEMA     = 21;
         g_trendFast       = 55;
         g_trendSlow       = 200;
         g_riskReward      = 4.0;
         g_minScore        = 70;
         g_maxConsecLosses = 3;
         g_maxTradesPerDay = 3;
         g_cooldownMin     = 30;
        }
      else
        {
         g_entryTF         = InpEntryTF;
         g_trendTF         = InpTrendTF;
         g_zoneSource      = InpZoneSource;
         g_pullbackEMA     = InpPullbackEMA;
         g_trendFast       = InpTrendFastEMA;
         g_trendSlow       = InpTrendSlowEMA;
         g_riskReward      = InpRiskReward;
         g_minScore        = InpMinScore;
         g_maxConsecLosses = InpMaxConsecutiveLosses;
         g_maxTradesPerDay = InpMaxTradesPerDay;
         g_cooldownMin     = InpCooldownAfterLossMinutes;
        }
   int tfMinutes   = PeriodSeconds(g_entryTF) / 60;
   g_atrRegimeBars = (tfMinutes > 0 ? MathMax(20, 1440 / tfMinutes) : 96);
  }

string ProfileName()
  {
   if(InpProfile == PROFILE_SCALP_M5)
      return("SCALP M5");
   if(InpProfile == PROFILE_SWING_M15)
      return("SWING M15");
   return("CUSTOM");
  }

string TFName(ENUM_TIMEFRAMES tf)
  {
   string name = EnumToString(tf);          // e.g. "PERIOD_M5"
   StringReplace(name, "PERIOD_", "");
   return(name);
  }

// ATR-based distance expressed in price, with a pips text for logs
double AtrDistance(double multiple)
  {
   return(g_atr * multiple);
  }

//+------------------------------------------------------------------+
//| Initialization                                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   ApplyProfile();
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
      Print("INIT FAILED: pip size is smaller than the symbol point.");
      return(INIT_PARAMETERS_INCORRECT);
     }

   g_trendFastHandle = iMA(g_symbol, g_trendTF, g_trendFast, 0, MODE_EMA, PRICE_CLOSE);
   g_trendSlowHandle = iMA(g_symbol, g_trendTF, g_trendSlow, 0, MODE_EMA, PRICE_CLOSE);
   g_entryEmaHandle  = iMA(g_symbol, g_entryTF, InpEntryEMA, 0, MODE_EMA, PRICE_CLOSE);
   g_atrHandle       = iATR(g_symbol, g_entryTF, InpATRPeriod);
   g_pullbackHandle  = iMA(g_symbol, g_entryTF, g_pullbackEMA, 0, MODE_EMA, PRICE_CLOSE);
   if(g_trendFastHandle == INVALID_HANDLE || g_trendSlowHandle == INVALID_HANDLE ||
      g_entryEmaHandle == INVALID_HANDLE || g_atrHandle == INVALID_HANDLE || g_pullbackHandle == INVALID_HANDLE)
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

   g_isTester     = (MQLInfoInteger(MQL_TESTER) != 0);
   g_isFastTester = (g_isTester && MQLInfoInteger(MQL_VISUAL_MODE) == 0);

   InitPersistentState();
   LoadMetaFile();

   double h1Close = 0.0, emaFast = 0.0, emaSlow = 0.0;
   g_trend = GetTrend(h1Close, emaFast, emaSlow, g_trendStrong);
   UpdateATR();

   // Never act on a candle that closed before this start (restart / re-init safe)
   g_lastBarTime = iTime(g_symbol, g_entryTF, 0);

   RebuildRecords();
   ManageDailyLimits();
   PrintSettings();

   if(!g_isTester)
      EventSetTimer(2);

   g_initialized = true;
   UpdateDashboard();
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   if(g_initialized)
     {
      SavePersistentState();
      RebuildRecords();
      ComputeFullStatistics();
      string lines[];
      BuildReport(lines);
      for(int i = 0; i < ArraySize(lines); i++)
         Print(lines[i]);
      if(InpWriteReports)
        {
         WriteReportFile(lines);
         WriteTradesCSV();
        }
     }
   if(g_trendFastHandle != INVALID_HANDLE)
      IndicatorRelease(g_trendFastHandle);
   if(g_trendSlowHandle != INVALID_HANDLE)
      IndicatorRelease(g_trendSlowHandle);
   if(g_entryEmaHandle != INVALID_HANDLE)
      IndicatorRelease(g_entryEmaHandle);
   if(g_atrHandle != INVALID_HANDLE)
      IndicatorRelease(g_atrHandle);
   if(g_pullbackHandle != INVALID_HANDLE)
      IndicatorRelease(g_pullbackHandle);
   Comment("");
  }

//+------------------------------------------------------------------+
//| Tester criterion: cost-adjusted average R per trade.             |
//| Returns 0 when there are fewer than 30 trades (too little        |
//| evidence to rank). Only used if you run the optimizer.           |
//+------------------------------------------------------------------+
double OnTester()
  {
   RebuildRecords();
   ComputeFullStatistics();
   if(g_summary.trades < SAMPLE_VERY_WEAK || g_summary.countR == 0)
      return(0.0);
   return(g_summary.sumRAdj / g_summary.countR);
  }

//+------------------------------------------------------------------+
//| Tick                                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   if(!g_initialized)
      return;
   CheckAccountProtection();
   ManageOpenPosition();

   if(IsNewEntryBar())
      EvaluateNewBar();

   if(InpShowDashboard && !g_isFastTester && TimeCurrent() - g_lastDashUpdate >= 5)
      UpdateDashboard();
  }

void OnTimer()
  {
   UpdateDashboard();
  }

//+------------------------------------------------------------------+
//| Trade events                                                     |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
  {
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD || trans.symbol != g_symbol)
      return;
   g_statsDirty = true;                       // rebuild even if the deal cannot be selected below
   RebuildRecords();

   if(!HistoryDealSelect(trans.deal))
      return;
   ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   long positionId       = HistoryDealGetInteger(trans.deal, DEAL_POSITION_ID);
   if(FindTradeIndex(positionId) < 0)
      return;                                 // not one of this EA's positions

   if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY)
     {
      int idx = FindTradeIndex(positionId);
      if(idx >= 0 && g_trades[idx].closed)
         LogClosedTrade(g_trades[idx]);
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
   RefreshStatisticsIfNeeded();
   SavePersistentState();
   ManageDailyLimits();
   UpdateATR();
   g_setupState = SETUP_WAITING;
   g_lastScore  = 0;

   datetime signalBar = iTime(g_symbol, g_entryTF, 1);
   g_candleLabel = "[" + TFName(g_entryTF) + " " + TimeToString(signalBar, TIME_DATE | TIME_MINUTES) + "] ";

   double h1Close = 0.0, emaFast = 0.0, emaSlow = 0.0;
   g_trend = GetTrend(h1Close, emaFast, emaSlow, g_trendStrong);
   if(emaSlow <= 0.0)
     {
      LogDecision("WAIT: trend indicator data not ready yet.", false);
      return;
     }

   MqlRates rates[];
   if(!LoadEntryRates(rates))
     {
      LogDecision("WAIT: not enough entry-timeframe history loaded yet.", false);
      return;
     }

   bool isBuy = false;
   Zone zone;
   zone.bottom = 0.0;
   zone.top = 0.0;
   zone.touches = 0;
   string trendText = "";
   int trendScore = 0;
   int trendClass = TRENDCLASS_NONE;

   if(InpTrendMode != TREND_MODE_OFF)
     {
      //--- 1. H1 trend (required)
      if(g_trend == TREND_NEUTRAL)
        {
         LogDecision(StringFormat("WAIT: %s trend unclear (close=%s, EMA%d=%s, EMA%d=%s).",
                                  TFName(g_trendTF), FormatPrice(h1Close), g_trendFast, FormatPrice(emaFast),
                                  g_trendSlow, FormatPrice(emaSlow)), false);
         return;
        }
      isBuy = (g_trend == TREND_BULLISH);
      if((isBuy && !InpAllowBuy) || (!isBuy && !InpAllowSell))
        {
         LogDecision(StringFormat("WAIT: %s trend, but %s trades are disabled in the settings.",
                                  (isBuy ? "bullish" : "bearish"), (isBuy ? "BUY" : "SELL")), false);
         return;
        }
      //--- 2. Zone reached (required)
      string zoneFail = "";
      if(!FindTouchedZone(isBuy, rates, zone, zoneFail))
        {
         LogDecision("WAIT: " + zoneFail, false);
         return;
        }
      trendClass = (g_trendStrong ? TRENDCLASS_STRONG : TRENDCLASS_PULLBACK);
      trendScore = (g_trendStrong ? SCORE_TREND_STRONG : SCORE_TREND_PULLBACK);
      trendText  = StringFormat("%s %s, %s (close %s, EMA%d %s, EMA%d %s%s)",
                                TFName(g_trendTF), (isBuy ? "BULLISH" : "BEARISH"),
                                (g_trendStrong ? "strong" : "pullback"),
                                FormatPrice(h1Close), g_trendFast, FormatPrice(emaFast),
                                g_trendSlow, FormatPrice(emaSlow),
                                (InpTrendMode == TREND_MODE_EMA200 ? ", EMA200-only mode" : ""));
     }
   else
     {
      //--- TEST MODE: no trend filter. Direction comes from which zone was reached.
      Zone supportZone, resistanceZone;
      string supportFail = "", resistanceFail = "";
      bool buyTouched  = (InpAllowBuy && FindTouchedZone(true, rates, supportZone, supportFail));
      bool sellTouched = (InpAllowSell && FindTouchedZone(false, rates, resistanceZone, resistanceFail));
      if(buyTouched && sellTouched)
        {
         LogDecision("WAIT: trend filter OFF and both support and resistance were reached (ambiguous).", false);
         return;
        }
      if(!buyTouched && !sellTouched)
        {
         LogDecision("WAIT: trend filter OFF - no zone reached (" + supportFail + " / " + resistanceFail + ")", false);
         return;
        }
      isBuy = buyTouched;
      if(isBuy)
         zone = supportZone;
      else
         zone = resistanceZone;
      bool aligned = ((isBuy && g_trend == TREND_BULLISH) || (!isBuy && g_trend == TREND_BEARISH));
      trendClass = (aligned ? (g_trendStrong ? TRENDCLASS_STRONG : TRENDCLASS_PULLBACK) : TRENDCLASS_NONE);
      trendScore = 0;
      trendText  = StringFormat("trend filter OFF (test mode); trend TF is %s", TrendStateText());
     }

   //--- Potential trade: evaluate EVERY remaining check
   SetupCheck check;
   InitCheck(check, isBuy);
   check.trendText   = trendText;
   check.trendScore  = trendScore;
   check.trendClass  = trendClass;
   check.zoneTouches = zone.touches;
   if(g_zoneSource == ZONE_EMA_PULLBACK)
      check.zoneScore = SCORE_ZONE_EMA;
   else
      check.zoneScore = (zone.touches >= 2 ? SCORE_ZONE_MULTI : SCORE_ZONE_SINGLE);
   if(g_zoneSource == ZONE_EMA_PULLBACK)
      check.zoneText = StringFormat("pullback to %s EMA%d %s and close back %s it", TFName(g_entryTF), g_pullbackEMA,
                                    FormatPrice(zone.bottom), (isBuy ? "above" : "below"));
   else
      check.zoneText = StringFormat("%s zone %s-%s (%d reaction%s)", (isBuy ? "support" : "resistance"),
                                    FormatPrice(zone.bottom), FormatPrice(zone.top),
                                    zone.touches, (zone.touches == 1 ? "" : "s"));
   check.zoneOk = true;
   if(g_zoneSource == ZONE_SWING && InpRequireMultiTouchZone && zone.touches < 2)
     {
      check.zoneOk = false;
      AddFailure(check, "Zone has only 1 reaction (multi-reaction zone required)");
     }

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
   check.scoreOk = (g_minScore <= 0 || check.score >= g_minScore);
   if(!check.scoreOk)
      AddFailure(check, StringFormat("Score %d below minimum %d", check.score, g_minScore));

   CheckTradingTime(check);
   CheckRiskLimits(check);
   CheckAccountStatus(check);
   CheckNoOpenPosition(check, signalBar);

   g_lastScore = check.score;
   if(check.zoneOk && check.candleOk && check.emaOk && check.atrOk && check.chaseOk && check.slOk && check.scoreOk)
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

   string reason = StringFormat("%s + %s + %s + %s + %s; score %d/100",
                                check.trendText, check.zoneText, check.candleText, check.emaText,
                                check.atrText, check.score);
   if(isBuy)
      OpenBuy(check, reason, signalBar);
   else
      OpenSell(check, reason, signalBar);

   UpdateDashboard();
  }

//+------------------------------------------------------------------+
//| New M15 candle detection                                         |
//+------------------------------------------------------------------+
bool IsNewEntryBar()
  {
   datetime barTime = iTime(g_symbol, g_entryTF, 0);
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
      CopyClose(g_symbol, g_trendTF, 1, 1, closeBuf) != 1)
      return(TREND_NEUTRAL);

   h1Close = closeBuf[0];
   emaFast = fastBuf[0];
   emaSlow = slowBuf[0];
   if(emaSlow <= 0.0 || emaFast <= 0.0)
     {
      emaSlow = 0.0;
      return(TREND_NEUTRAL);
     }

   bool bullAligned = (h1Close > emaSlow && emaFast > emaSlow);
   bool bearAligned = (h1Close < emaSlow && emaFast < emaSlow);

   if(InpTrendMode == TREND_MODE_EMA200)
     {
      if(h1Close > emaSlow)
        {
         strong = (bullAligned && h1Close > emaFast);
         return(TREND_BULLISH);
        }
      if(h1Close < emaSlow)
        {
         strong = (bearAligned && h1Close < emaFast);
         return(TREND_BEARISH);
        }
      return(TREND_NEUTRAL);
     }

   if(bullAligned)
     {
      strong = (h1Close > emaFast);
      return(TREND_BULLISH);
     }
   if(bearAligned)
     {
      strong = (h1Close < emaFast);
      return(TREND_BEARISH);
     }
   return(TREND_NEUTRAL);
  }

string TrendStateText()
  {
   if(g_trend == TREND_BULLISH)
      return(g_trendStrong ? "BULLISH (strong)" : "BULLISH (pullback)");
   if(g_trend == TREND_BEARISH)
      return(g_trendStrong ? "BEARISH (strong)" : "BEARISH (pullback)");
   return("NEUTRAL");
  }

//+------------------------------------------------------------------+
//| ATR and ATR regime (ATR vs its 24h average)                      |
//+------------------------------------------------------------------+
void UpdateATR()
  {
   double buf[];
   int copied = CopyBuffer(g_atrHandle, 0, 1, g_atrRegimeBars, buf);
   if(copied <= 0)
      return;
   // buf is oldest -> newest (not series); the last value is the just-closed candle
   double latest = buf[copied - 1];
   if(latest <= 0.0)
      return;
   double sum = 0.0;
   int n = 0;
   for(int i = 0; i < copied; i++)
      if(buf[i] > 0.0)
        {
         sum += buf[i];
         n++;
        }
   g_atr        = latest;
   g_atrAverage = (n > 0 ? sum / n : latest);
   double ratio = (g_atrAverage > 0.0 ? g_atr / g_atrAverage : 1.0);
   if(ratio < ATR_LOW_RATIO)
      g_atrRegime = REGIME_LOW;
   else
      if(ratio > ATR_HIGH_RATIO)
         g_atrRegime = REGIME_HIGH;
      else
         g_atrRegime = REGIME_NORMAL;
  }

string RegimeName(int regime)
  {
   if(regime == REGIME_LOW)
      return("LOW");
   if(regime == REGIME_HIGH)
      return("HIGH");
   return("NORMAL");
  }

//+------------------------------------------------------------------+
//| M15 candles in series order: 0 = forming, 1 = just closed        |
//+------------------------------------------------------------------+
bool LoadEntryRates(MqlRates &rates[])
  {
   int needed = InpSwingLookbackBars + InpSwingStrength + 5;
   ArraySetAsSeries(rates, true);
   int copied = CopyRates(g_symbol, g_entryTF, 0, needed, rates);
   return(copied == needed);
  }

//+------------------------------------------------------------------+
//| Swing points and zones                                           |
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

// Unbroken swings formed before the last 2 candles, merged when within ATR x InpZoneMergeATR
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

   ArraySort(levels);
   double mergeDistance = AtrDistance(InpZoneMergeATR);
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

bool FindTouchedZone(bool isBuy, const MqlRates &rates[], Zone &zone, string &failReason)
  {
   if(g_zoneSource == ZONE_EMA_PULLBACK)
      return(FindEmaPullbackZone(isBuy, rates, zone, failReason));

   double distance = AtrDistance(InpZoneDistanceATR);
   double close1   = rates[1].close;
   double maxPips  = distance / g_pipSize;

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
                                   (touchLow - zone.top) / g_pipSize, maxPips);
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
                                (zone.bottom - touchHigh) / g_pipSize, maxPips);
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
//| EMA pullback "zone" (scalp): in an uptrend the last 2 candles     |
//| dipped to the entry-timeframe EMA (21) and the last candle       |
//| closed back above it. Mirror image for a downtrend.              |
//| A dip deeper than 1 x ATR through the EMA counts as a breakdown. |
//+------------------------------------------------------------------+
const double EMA_PIERCE_MAX_ATR = 1.0;

bool FindEmaPullbackZone(bool isBuy, const MqlRates &rates[], Zone &zone, string &failReason)
  {
   double buf[];
   if(CopyBuffer(g_pullbackHandle, 0, 1, 1, buf) != 1 || buf[0] <= 0.0 || g_atr <= 0.0)
     {
      failReason = StringFormat("EMA%d / ATR data not ready.", g_pullbackEMA);
      return(false);
     }
   double ema      = buf[0];
   double distance = AtrDistance(InpZoneDistanceATR);
   double pierce   = AtrDistance(EMA_PIERCE_MAX_ATR);
   zone.bottom  = ema;
   zone.top     = ema;
   zone.touches = 1;

   if(isBuy)
     {
      double touchLow = MathMin(rates[1].low, rates[2].low);
      if(touchLow > ema + distance)
        {
         failReason = StringFormat("No pullback to EMA%d %s yet (recent low %.1f pips above it, needs within %.1f).",
                                   g_pullbackEMA, FormatPrice(ema), (touchLow - ema) / g_pipSize, distance / g_pipSize);
         return(false);
        }
      if(touchLow < ema - pierce)
        {
         failReason = StringFormat("Pullback too deep (low %.1f pips below EMA%d %s, max %.1f).",
                                   (ema - touchLow) / g_pipSize, g_pullbackEMA, FormatPrice(ema), pierce / g_pipSize);
         return(false);
        }
      if(rates[1].close <= ema)
        {
         failReason = StringFormat("Price has not closed back above EMA%d %s.", g_pullbackEMA, FormatPrice(ema));
         return(false);
        }
      return(true);
     }

   double touchHigh = MathMax(rates[1].high, rates[2].high);
   if(touchHigh < ema - distance)
     {
      failReason = StringFormat("No pullback to EMA%d %s yet (recent high %.1f pips below it, needs within %.1f).",
                                g_pullbackEMA, FormatPrice(ema), (ema - touchHigh) / g_pipSize, distance / g_pipSize);
      return(false);
     }
   if(touchHigh > ema + pierce)
     {
      failReason = StringFormat("Pullback too deep (high %.1f pips above EMA%d %s, max %.1f).",
                                (touchHigh - ema) / g_pipSize, g_pullbackEMA, FormatPrice(ema), pierce / g_pipSize);
      return(false);
     }
   if(rates[1].close >= ema)
     {
      failReason = StringFormat("Price has not closed back below EMA%d %s.", g_pullbackEMA, FormatPrice(ema));
      return(false);
     }
   return(true);
  }

//+------------------------------------------------------------------+
//| Confirmation candle (rates[1]) - must close in trade direction   |
//+------------------------------------------------------------------+
void CheckConfirmation(SetupCheck &c, const MqlRates &rates[], const Zone &zone)
  {
   c.candleOk    = false;
   c.candleScore = 0;
   c.confirmType = -1;

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
   double distance  = AtrDistance(InpZoneDistanceATR);
   double minRange  = g_atr * CONFIRM_MIN_RANGE_ATR;

   if(range <= 0.0 || range < minRange)
     {
      c.candleText = StringFormat("candle too small (%.1f pips < %.0f%% of ATR = %.1f pips)",
                                  range / g_pipSize, CONFIRM_MIN_RANGE_ATR * 100.0, minRange / g_pipSize);
      AddFailure(c, "Confirmation candle too small");
      return;
     }

   bool directional = (c.isBuy ? close1 > open1 : close1 < open1);
   if(!directional)
     {
      c.candleText = (c.isBuy ? "candle did not close bullish" : "candle did not close bearish");
      AddFailure(c, "No reaction candle in the trade direction");
      return;
     }

   bool rejection, engulfing, strong;
   if(c.isBuy)
     {
      rejection = (lowerWick >= REJECTION_WICK_MIN * range && upperWick <= REJECTION_OPPOSITE_MAX * range &&
                   low1 <= zone.top + distance);
      engulfing = (close2 < open2 && close1 >= open2 && open1 <= close2);
      strong    = (body >= STRONG_BODY_MIN * range && (high1 - close1) <= STRONG_CLOSE_ZONE * range);
     }
   else
     {
      rejection = (upperWick >= REJECTION_WICK_MIN * range && lowerWick <= REJECTION_OPPOSITE_MAX * range &&
                   high1 >= zone.bottom - distance);
      engulfing = (close2 > open2 && close1 <= open2 && open1 >= close2);
      strong    = (body >= STRONG_BODY_MIN * range && (close1 - low1) <= STRONG_CLOSE_ZONE * range);
     }

   string side = (c.isBuy ? "bullish" : "bearish");
   if(rejection)
     {
      c.candleOk = true;
      c.confirmType = CONF_REJECTION;
      c.candleScore = SCORE_CANDLE_REACTION;
      c.candleText = side + " rejection candle (long wick into the zone)";
      return;
     }
   if(engulfing && InpConfirmMode != CONFIRM_REJECTION)
     {
      c.candleOk = true;
      c.confirmType = CONF_ENGULFING;
      c.candleScore = SCORE_CANDLE_REACTION;
      c.candleText = side + " engulfing candle";
      return;
     }
   if(strong && InpConfirmMode == CONFIRM_ALL)
     {
      c.candleOk = true;
      c.confirmType = CONF_STRONG;
      c.candleScore = SCORE_CANDLE_STRONG;
      c.candleText = "strong " + side + " candle";
      return;
     }
   if(engulfing || strong)
      c.candleText = StringFormat("%s %s candle, not accepted by confirmation mode '%s'",
                                  side, (engulfing ? "engulfing" : "strong"), ConfirmModeText());
   else
      c.candleText = side + " close, but no rejection, engulfing or strong candle";
   AddFailure(c, "No accepted reaction candle");
  }

string ConfirmName(int type)
  {
   if(type == CONF_REJECTION)
      return("rejection");
   if(type == CONF_ENGULFING)
      return("engulfing");
   if(type == CONF_STRONG)
      return("strong candle");
   return("unknown");
  }

string ConfirmModeText()
  {
   if(InpConfirmMode == CONFIRM_REACTION)
      return("rejection+engulfing");
   if(InpConfirmMode == CONFIRM_REJECTION)
      return("rejection only");
   return("all");
  }

//+------------------------------------------------------------------+
//| EMA 9 entry timing                                               |
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
   c.emaText = StringFormat("close %s %s EMA%d %s%s", FormatPrice(close1),
                            (confirmed ? (c.isBuy ? ">" : "<") : (c.isBuy ? "<=" : ">=")),
                            InpEntryEMA, FormatPrice(ema), (InpRequireEMAConfirm ? "" : " (optional)"));
   if(confirmed)
     {
      c.emaOk    = true;
      c.emaScore = SCORE_EMA_CONFIRM;
      return;
     }
   c.emaOk = !InpRequireEMAConfirm;
   if(InpRequireEMAConfirm)
      AddFailure(c, StringFormat("EMA%d confirmation missing", InpEntryEMA));
  }

//+------------------------------------------------------------------+
//| ATR filter: absolute limits + optional relative regime filter    |
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
   double atrPips    = g_atr / g_pipSize;
   double spreadPips = CurrentSpreadPips();
   double ratio      = (g_atrAverage > 0.0 ? g_atr / g_atrAverage : 1.0);
   c.atrText = StringFormat("ATR %.1f pips, regime %s (x%.2f of 24h avg); min %s, spike limit %s",
                            atrPips, RegimeName(g_atrRegime), ratio,
                            (InpMinATRToSpread <= 0.0 ? "off" : (spreadPips <= 0.0 ? "n/a (no spread)" :
                             StringFormat("%.1f pips (spread x%.1f)", spreadPips * InpMinATRToSpread, InpMinATRToSpread))),
                            (InpMaxATRSpikeRatio > 0.0 ? StringFormat("x%.1f", InpMaxATRSpikeRatio) : "off"));

   if(InpMinATRToSpread > 0.0 && spreadPips > 0.0 && atrPips < spreadPips * InpMinATRToSpread)
     {
      AddFailure(c, "Volatility too low for the spread (ATR below spread x minimum ratio)");
      return;
     }
   if(InpMaxATRSpikeRatio > 0.0 && ratio > InpMaxATRSpikeRatio)
     {
      AddFailure(c, "Volatility spike (ATR far above its 24h average)");
      return;
     }
   bool regimeBlocked =
      (InpATRRegimeFilter == REGIME_FILTER_NOT_LOW && g_atrRegime == REGIME_LOW) ||
      (InpATRRegimeFilter == REGIME_FILTER_NOT_HIGH && g_atrRegime == REGIME_HIGH) ||
      (InpATRRegimeFilter == REGIME_FILTER_NORMAL_ONLY && g_atrRegime != REGIME_NORMAL);
   if(regimeBlocked)
     {
      AddFailure(c, "ATR regime " + RegimeName(g_atrRegime) + " excluded by the regime filter");
      return;
     }
   c.atrOk    = true;
   c.atrScore = SCORE_ATR_OK;
  }

//+------------------------------------------------------------------+
//| Don't chase                                                      |
//+------------------------------------------------------------------+
void CheckEntryDistance(SetupCheck &c, const Zone &zone, const MqlTick &tick)
  {
   double distance = (c.isBuy ? tick.ask - zone.top : zone.bottom - tick.bid);
   if(distance < 0.0)
      distance = 0.0;
   c.distancePips = distance / g_pipSize;
   double maxPips = AtrDistance(InpMaxDistanceFromZoneATR) / g_pipSize;
   if(InpMaxDistanceFromZoneATR <= 0.0)
     {
      c.chaseOk   = true;
      c.chaseText = StringFormat("entry %.1f pips from zone (filter off)", c.distancePips);
      return;
     }
   c.chaseText = StringFormat("entry %.1f pips from zone (max %.1f = ATR x%.2f)", c.distancePips, maxPips, InpMaxDistanceFromZoneATR);
   c.chaseOk   = (c.distancePips <= maxPips);
   if(!c.chaseOk)
      AddFailure(c, "Price already too far from the zone (not chasing)");
  }

//+------------------------------------------------------------------+
//| Stop loss                                                        |
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
   double buffer = AtrDistance(InpSLBufferATR);
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
   double maxSLPips  = AtrDistance(InpMaxStopLossATR) / g_pipSize;
   c.slText = StringFormat("SL %.1f pips (%s%s, max %.0f) -> TP %.1f pips (%.1fR)",
                           slPips, (InpSLMode == SL_MODE_FIXED ? "fixed" : "ATR"),
                           (structural ? " + beyond zone" : ""), maxSLPips,
                           slPips * g_riskReward, g_riskReward);

   if(slDistance <= 0.0)
     {
      AddFailure(c, "Invalid stop loss distance");
      return;
     }
   if(slPips > maxSLPips)
     {
      AddFailure(c, StringFormat("Required SL %.1f pips is larger than the maximum %.0f (ATR x%.1f)", slPips, maxSLPips, InpMaxStopLossATR));
      return;
     }
   double minStop = (double)SymbolInfoInteger(g_symbol, SYMBOL_TRADE_STOPS_LEVEL) * g_point;
   if(slDistance - (tick.ask - tick.bid) <= minStop)
     {
      AddFailure(c, StringFormat("SL inside broker minimum stop level (%.1f pips)", minStop / g_pipSize));
      return;
     }
   c.slOk       = true;
   c.slDistance = slDistance;
  }

//+------------------------------------------------------------------+
//| Spread                                                           |
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
//| Sessions and news                                                |
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
      case SESSION_ALL_DAY:
         return(true);
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
      case SESSION_ALL_DAY:
         return("All day (test)");
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

bool IsTimeInWindow(int nowMin, int startMin, int endMin)
  {
   if(startMin == endMin)
      return(false);
   if(startMin < endMin)
      return(nowMin >= startMin && nowMin < endMin);
   return(nowMin >= startMin || nowMin < endMin);
  }

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

string CurrentSessionLabel()
  {
   int s = ClassifySession(TimeCurrent());
   if(s == STAT_LONDON)
      return("LONDON");
   if(s == STAT_OVERLAP)
      return("LONDON+NEW YORK");
   if(s == STAT_NEWYORK)
      return("NEW YORK");
   return("CLOSED");
  }

//+------------------------------------------------------------------+
//| Daily limits (0 = off)                                           |
//+------------------------------------------------------------------+
void ManageDailyLimits()
  {
   datetime now   = TimeCurrent();
   datetime today = (datetime)(((long)now / 86400) * 86400);

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
      // Live/demo: refresh the report files once per day so progress can be followed
      if(!firstRun && !g_isTester && InpWriteReports && g_initialized)
        {
         ComputeFullStatistics();
         string lines[];
         BuildReport(lines);
         WriteReportFile(lines);
         WriteTradesCSV();
        }
     }
   else
      CalculateDailyStats(g_daily);

   if(g_tradingStopped)
      return;

   double dayPL      = g_daily.realizedPL + g_daily.floatingPL;
   double lossLimit  = g_dayStartBalance * InpMaxDailyLossPercent / 100.0;
   double profitStop = g_dayStartBalance * InpMaxDailyProfitPercent / 100.0;

   if(InpMaxDailyLossPercent > 0.0 && lossLimit > 0.0 && dayPL <= -lossLimit)
      StopTradingForToday(StringFormat("Daily loss limit reached (%.2f, limit -%.2f = %.2f%%).",
                                       dayPL, lossLimit, InpMaxDailyLossPercent));
   else
      if(InpMaxDailyProfitPercent > 0.0 && profitStop > 0.0 && dayPL >= profitStop)
         StopTradingForToday(StringFormat("Daily profit boundary reached (%.2f >= %.2f = %.2f%%).",
                                          dayPL, profitStop, InpMaxDailyProfitPercent));
      else
         if(g_maxConsecLosses > 0 && g_daily.consecutiveLosses >= g_maxConsecLosses)
            StopTradingForToday(StringFormat("Consecutive loss limit reached (%d losses in a row).",
                                             g_daily.consecutiveLosses));
         else
            if(g_maxTradesPerDay > 0 && g_daily.tradesToday >= g_maxTradesPerDay)
               StopTradingForToday(StringFormat("Max trades per day reached (%d of %d).",
                                                g_daily.tradesToday, g_maxTradesPerDay));
  }

void StopTradingForToday(const string reason)
  {
   if(g_tradingStopped)
      return;
   g_tradingStopped = true;
   g_stopReason     = reason;
   Print("DAILY TRADING STOPPED: ", reason, " No new trades until the next server day.");
  }

// Today's numbers from the trade records (outcome uses the break-even band) + open positions
void CalculateDailyStats(DailyStats &d)
  {
   d.tradesToday       = 0;
   d.winsToday         = 0;
   d.lossesToday       = 0;
   d.realizedPL        = 0.0;
   d.floatingPL        = 0.0;
   d.rToday            = 0.0;
   d.consecutiveLosses = 0;

   // Records are in entry order; only recent ones can matter for today
   datetime horizon = g_currentDay - 30 * 86400;
   int start = g_tradeCount;
   while(start > 0 && g_trades[start - 1].openTime >= horizon)
      start--;

   for(int i = start; i < g_tradeCount; i++)
     {
      if(g_trades[i].openTime >= g_currentDay)
         d.tradesToday++;
      if(g_trades[i].closed && g_trades[i].closeTime >= g_currentDay)
        {
         d.realizedPL += g_trades[i].net;
         if(g_trades[i].hasR)
            d.rToday += g_trades[i].r;
         if(g_trades[i].outcome == OUTCOME_WIN)
            d.winsToday++;
         if(g_trades[i].outcome == OUTCOME_LOSS)
           {
            d.lossesToday++;
            d.consecutiveLosses++;
           }
         else
            d.consecutiveLosses = 0;
        }
      else
         if(!g_trades[i].closed && g_trades[i].openTime >= g_currentDay)
            d.realizedPL += g_trades[i].net;
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
   if(g_cooldownMin <= 0 || g_lastLossTime == 0)
      return(false);
   until = g_lastLossTime + g_cooldownMin * 60;
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
//| Account protection: emergency switch + equity drawdown halt      |
//+------------------------------------------------------------------+
void InitPersistentState()
  {
   string base = "GBV4_" + (string)AccountInfoInteger(ACCOUNT_LOGIN) + "_" + (string)InpMagicNumber + "_" + g_symbol;
   g_gvPeak   = base + "_peak";
   g_gvHalt   = base + "_halt";
   g_gvSignal = base + "_sig";

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   g_peakEquity          = equity;
   g_accountHalted       = false;
   g_lastTradedSignalBar = 0;

   // The tester always starts clean; live/demo state survives restarts
   if(g_isTester)
      return;
   if(InpResetAccountProtection)
     {
      GlobalVariableDel(g_gvPeak);
      GlobalVariableDel(g_gvHalt);
      Print("Account protection reset: equity peak set to current equity ", DoubleToString(equity, 2), ". ",
            "Set 'Reset account protection' back to false, otherwise it resets on every restart.");
     }
   if(GlobalVariableCheck(g_gvPeak))
      g_peakEquity = MathMax(equity, GlobalVariableGet(g_gvPeak));
   if(InpMaxAccountDrawdownPercent > 0.0 && GlobalVariableCheck(g_gvHalt) && GlobalVariableGet(g_gvHalt) > 0.5)
      g_accountHalted = true;
   if(GlobalVariableCheck(g_gvSignal))
      g_lastTradedSignalBar = (datetime)(long)GlobalVariableGet(g_gvSignal);
   if(g_accountHalted)
      Print("WARNING: account protection HALT is active (stored). No new trades until reset with 'Reset account protection'.");
  }

void SavePersistentState()
  {
   if(g_isTester)
      return;
   if(g_peakDirty)
     {
      GlobalVariableSet(g_gvPeak, g_peakEquity);
      g_peakDirty = false;
     }
   GlobalVariableSet(g_gvHalt, g_accountHalted ? 1.0 : 0.0);
   if(g_lastTradedSignalBar > 0)
      GlobalVariableSet(g_gvSignal, (double)(long)g_lastTradedSignalBar);
   GlobalVariablesFlush();
  }

void CheckAccountProtection()
  {
   if(InpMaxAccountDrawdownPercent <= 0.0 || g_accountHalted)
      return;
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity > g_peakEquity)
     {
      g_peakEquity = equity;
      g_peakDirty  = true;
     }
   if(g_peakEquity <= 0.0)
      return;
   double ddPct = (g_peakEquity - equity) / g_peakEquity * 100.0;
   if(ddPct >= InpMaxAccountDrawdownPercent)
     {
      g_accountHalted = true;
      Print("ACCOUNT PROTECTION HALT: equity ", DoubleToString(equity, 2), " is ", DoubleToString(ddPct, 2),
            "% below the peak ", DoubleToString(g_peakEquity, 2), " (limit ", DoubleToString(InpMaxAccountDrawdownPercent, 2),
            "%). No new trades until reset. Open trades keep their SL/TP.");
      SavePersistentState();
     }
  }

void CheckAccountStatus(SetupCheck &c)
  {
   c.accountOk   = true;
   c.accountText = "trading enabled";
   if(!InpTradingEnabled)
     {
      c.accountOk   = false;
      c.accountText = "emergency switch: trading disabled";
      AddFailure(c, "Trading disabled by the emergency switch");
      return;
     }
   if(g_accountHalted)
     {
      c.accountOk   = false;
      c.accountText = StringFormat("account drawdown halt (limit %.1f%%)", InpMaxAccountDrawdownPercent);
      AddFailure(c, "Account drawdown protection halt");
      return;
     }
   if(InpMaxAccountDrawdownPercent > 0.0 && g_peakEquity > 0.0)
      c.accountText = StringFormat("equity drawdown %.2f%% (halt at %.1f%%)",
                                   (g_peakEquity - AccountInfoDouble(ACCOUNT_EQUITY)) / g_peakEquity * 100.0,
                                   InpMaxAccountDrawdownPercent);
  }

//+------------------------------------------------------------------+
//| One position + duplicate-signal protection                       |
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

void CheckNoOpenPosition(SetupCheck &c, datetime signalBar)
  {
   int own = 0;
   int total = CountOpenPositions(own);
   c.positionOk   = true;
   c.positionText = "no open position";
   if(total >= MAX_OPEN_POSITIONS)
     {
      c.positionOk   = false;
      c.positionText = StringFormat("%d position(s) already open (%d by this EA)", total, own);
      AddFailure(c, "A position is already open");
      return;
     }
   if(signalBar > 0 && signalBar == g_lastTradedSignalBar)
     {
      c.positionOk   = false;
      c.positionText = "this signal candle was already traded";
      AddFailure(c, "Signal candle already traded (duplicate protection)");
     }
  }

bool CheckTradingAllowed(bool isBuy, string &reason)
  {
   if(!g_isTester)
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
//| Lot size (cost-aware). Returns 0 and a reason if invalid.        |
//| Risk = price loss at SL + assumed round-turn commission.         |
//| Lots are rounded DOWN on the broker grid, never up.              |
//+------------------------------------------------------------------+
double CalculateLotSize(bool isBuy, double entry, double sl, double &riskMoney, string &reason, string &details)
  {
   riskMoney = 0.0;
   details   = "";
   double minLot  = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_STEP);
   if(minLot <= 0.0 || maxLot <= 0.0 || lotStep <= 0.0)
     {
      reason = "Broker lot limits are unavailable.";
      return(0.0);
     }
   double priceLossPerLot = LossPerLot(isBuy, entry, sl);
   if(priceLossPerLot <= 0.0)
     {
      reason = "Could not calculate the money value of the stop loss (tick value unavailable).";
      return(0.0);
     }
   double lossPerLot = priceLossPerLot + InpCommissionPerLot;

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   double base    = MathMin(balance, equity);
   double budget  = base * InpRiskPercent / 100.0;
   double rawLots = (InpLotMode == LOT_MODE_FIXED ? InpFixedLotSize : budget / lossPerLot);

   double cap = MathMin(maxLot, InpMaxLotSize);
   if(rawLots > cap)
      rawLots = cap;
   if(rawLots < minLot && (InpLotMode == LOT_MODE_FIXED || InpMaxLotSize < minLot))
     {
      reason = StringFormat("Lot %.4f (fixed lot or safety cap) is below the broker minimum %.2f.", rawLots, minLot);
      return(0.0);
     }
   if(rawLots < minLot)
     {
      reason = StringFormat("Calculated lot %.4f is below the broker minimum %.2f: the minimum lot would risk %.2f "
                            "(%.2f%%), more than the configured %.2f%%. Trade skipped (lots are never rounded up).",
                            rawLots, minLot, minLot * lossPerLot,
                            (base > 0.0 ? minLot * lossPerLot / base * 100.0 : 0.0), InpRiskPercent);
      return(0.0);
     }
   double lots = minLot + FloorToStep(rawLots - minLot, lotStep);
   lots = NormalizeDouble(lots, StepDigits(lotStep));
   if(lots > rawLots + 1e-9 || lots < minLot)
     {
      reason = "Could not fit the lot size to the broker's volume step.";
      return(0.0);
     }
   riskMoney = lots * lossPerLot;
   details = StringFormat("balance %.2f, equity %.2f, base %.2f | risk %.2f%% = %.2f | SL %.1f pips | "
                          "loss/lot %.2f (+comm %.2f) | raw lot %.4f -> %.2f | est. risk %.2f (%.2f%%)",
                          balance, equity, base, InpRiskPercent, budget, MathAbs(entry - sl) / g_pipSize,
                          priceLossPerLot, InpCommissionPerLot, (InpLotMode == LOT_MODE_FIXED ? InpFixedLotSize : budget / lossPerLot),
                          lots, riskMoney, (base > 0.0 ? riskMoney / base * 100.0 : 0.0));
   return(lots);
  }

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
bool OpenBuy(const SetupCheck &c, const string reason, datetime signalBar)
  {
   return(OpenTrade(c, reason, signalBar));
  }

bool OpenSell(const SetupCheck &c, const string reason, datetime signalBar)
  {
   return(OpenTrade(c, reason, signalBar));
  }

bool OpenTrade(const SetupCheck &c, const string reason, datetime signalBar)
  {
   bool   isBuy     = c.isBuy;
   string direction = (isBuy ? "BUY" : "SELL");
   double slDist    = c.slDistance;
   double tpDist    = slDist * g_riskReward;

   for(int attempt = 1; attempt <= MAX_SEND_ATTEMPTS; attempt++)
     {
      int own = 0;
      if(CountOpenPositions(own) >= MAX_OPEN_POSITIONS || signalBar == g_lastTradedSignalBar)
        {
         LogDecision("NO TRADE: " + direction + " aborted - position open or signal already traded (duplicate protection).", true);
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

      double entry = (isBuy ? tick.ask : tick.bid);
      double sl    = NormalizePrice(isBuy ? entry - slDist : entry + slDist);
      double tp    = NormalizePrice(isBuy ? entry + tpDist : entry - tpDist);

      double riskMoney = 0.0;
      string lotReason = "", lotDetails = "";
      double lots = CalculateLotSize(isBuy, entry, sl, riskMoney, lotReason, lotDetails);
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

      string comment = StringFormat("%s s%d", TRADE_COMMENT_PREFIX, c.score);
      bool sent = (isBuy ? g_trade.Buy(lots, g_symbol, entry, sl, tp, comment)
                         : g_trade.Sell(lots, g_symbol, entry, sl, tp, comment));
      uint retcode = g_trade.ResultRetcode();

      if(sent && (retcode == TRADE_RETCODE_DONE || retcode == TRADE_RETCODE_DONE_PARTIAL || retcode == TRADE_RETCODE_PLACED))
        {
         g_lastTradedSignalBar = signalBar;
         SavePersistentState();

         double fill = g_trade.ResultPrice();
         TradeMeta m;
         m.positionId    = (long)g_trade.ResultOrder();   // position id = opening order ticket
         m.signalBar     = signalBar;
         m.score         = c.score;
         m.atrPips       = g_atr / g_pipSize;
         m.atrRegime     = g_atrRegime;
         m.confirmType   = c.confirmType;
         m.trendClass    = c.trendClass;
         m.zoneTouches   = c.zoneTouches;
         m.distancePips  = c.distancePips;
         m.spreadPips    = spreadPips;
         m.ask           = tick.ask;
         m.bid           = tick.bid;
         m.slPips        = slDist / g_pipSize;
         m.tpPips        = tpDist / g_pipSize;
         m.estCommission = InpCommissionPerLot * g_trade.ResultVolume();
         m.slMode        = (int)InpSLMode;
         m.riskReward    = g_riskReward;
         m.riskMoney     = riskMoney;
         m.beMoved       = false;
         m.trailMoved    = false;
         AddMeta(m);
         AppendMetaEntry(m);

         Print(g_candleLabel, "TRADE OPENED: ", direction, " ", g_symbol, " at ", TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS));
         Print("   Reason: ", reason);
         Print(StringFormat("   Entry=%s (ask %s / bid %s)  SL=%s (%.1f pips)  TP=%s (%.1f pips, %.1fR)  Lots=%.2f",
                            FormatPrice(fill > 0.0 ? fill : entry), FormatPrice(tick.ask), FormatPrice(tick.bid),
                            FormatPrice(sl), slDist / g_pipSize, FormatPrice(tp), tpDist / g_pipSize,
                            g_riskReward, g_trade.ResultVolume()));
         Print(StringFormat("   Spread=%.1f pips  Est.commission=%.2f  ATR=%.1f pips (%s)  Score=%d  Session=%s  Confirmation=%s",
                            spreadPips, m.estCommission, m.atrPips, RegimeName(m.atrRegime), c.score,
                            SessionName(ClassifySession(TimeCurrent())), ConfirmName(c.confirmType)));
         Print("   Sizing: ", lotDetails);
         Print("   Config: ", ConfigText());
         Print("   Position #", m.positionId, "  Deal #", (string)g_trade.ResultDeal());
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
//| Trade management: break-even + optional simple trailing          |
//+------------------------------------------------------------------+
void ManageOpenPosition()
  {
   if(!InpBreakEvenEnabled && InpTrailMode == TRAIL_OFF)
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
         continue;

      double risk = GetInitialRisk(posId, open, tp);
      if(risk <= 0.0)
         continue;

      double profitDistance = (isBuy ? price - open : open - price);
      double newSL = sl;
      string action = "";
      bool isTrail = false;
      bool isBreakEven = false;

      if(InpBreakEvenEnabled && profitDistance >= InpBreakEvenAtR * risk)
        {
         double beLevel = NormalizePrice(isBuy ? open + PipsToPrice(InpBreakEvenBufferPips)
                                               : open - PipsToPrice(InpBreakEvenBufferPips));
         if(isBuy ? (beLevel > newSL + g_point * 0.5) : (beLevel < newSL - g_point * 0.5))
           {
            newSL  = beLevel;
            isBreakEven = true;
            action = StringFormat("Break-even at +%.1fR", profitDistance / risk);
           }
        }

      if(InpTrailMode != TRAIL_OFF && profitDistance >= InpTrailStartR * risk)
        {
         double trailDistance = (InpTrailMode == TRAIL_ATR ? g_atr * InpTrailATRMultiplier : PipsToPrice(InpTrailFixedPips));
         if(trailDistance > 0.0)
           {
            double trail = NormalizePrice(isBuy ? price - trailDistance : price + trailDistance);
            double step  = risk * TRAIL_STEP_OF_RISK;
            if(isBuy ? (trail > newSL && trail - sl >= step) : (trail < newSL && sl - trail >= step))
              {
               newSL   = trail;
               isTrail = true;
               action  = StringFormat("Trailing stop (%s) at +%.1fR", (InpTrailMode == TRAIL_ATR ? "ATR" : "fixed"),
                                      profitDistance / risk);
              }
           }
        }

      if(action == "")
         continue;
      if(g_lastModifyFail > 0 && TimeCurrent() - g_lastModifyFail < MODIFY_RETRY_SECONDS)
         continue;

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
         Print("MANAGE: ", action, " - ", (isBuy ? "BUY" : "SELL"), " #", posId,
               " SL moved ", FormatPrice(sl), " -> ", FormatPrice(newSL), " (TP unchanged ", FormatPrice(tp), ")");
         g_lastModifyFail = 0;
         if(isBreakEven)
            MarkMetaFlag(posId, false);
         if(isTrail)
            MarkMetaFlag(posId, true);
        }
      else
        {
         Print("MANAGE ERROR: could not move SL for #", posId, ". Retcode ", g_trade.ResultRetcode(),
               " (", g_trade.ResultRetcodeDescription(), "). Retrying in ", MODIFY_RETRY_SECONDS, "s.");
         g_lastModifyFail = TimeCurrent();
        }
     }
  }

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
   if(tp > 0.0 && g_riskReward > 0.0)
      return(MathAbs(tp - open) / g_riskReward);
   return(0.0);
  }

//+------------------------------------------------------------------+
//| Trade metadata (memory; also a file in live/demo for restarts)   |
//+------------------------------------------------------------------+
int FindMetaIndex(long positionId)
  {
   for(int i = g_metaCount - 1; i >= 0; i--)
      if(g_meta[i].positionId == positionId)
         return(i);
   return(-1);
  }

void AddMeta(const TradeMeta &m)
  {
   int idx = FindMetaIndex(m.positionId);
   if(idx < 0)
     {
      ArrayResize(g_meta, g_metaCount + 1, 256);
      idx = g_metaCount;
      g_metaCount++;
     }
   g_meta[idx] = m;
   g_statsDirty = true;
  }

void MarkMetaFlag(long positionId, bool trailing)
  {
   int idx = FindMetaIndex(positionId);
   if(idx < 0)
      return;
   if(trailing)
      g_meta[idx].trailMoved = true;
   else
      g_meta[idx].beMoved = true;
   AppendMetaFlag(positionId, trailing);
   g_statsDirty = true;
  }

string MetaFileName()
  {
   return("GoldBotV4_meta_" + (string)AccountInfoInteger(ACCOUNT_LOGIN) + "_" + g_symbol + "_" +
          (string)InpMagicNumber + ".csv");
  }

int OpenMetaFileForAppend()
  {
   int handle = FileOpen(MetaFileName(), FILE_READ | FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_COMMON, ',');
   if(handle != INVALID_HANDLE)
      FileSeek(handle, 0, SEEK_END);
   else
      Print("WARNING: could not open metadata file ", MetaFileName(), " (error ", GetLastError(), ").");
   return(handle);
  }

void AppendMetaEntry(const TradeMeta &m)
  {
   if(g_isTester)
      return;                                 // tester runs keep metadata in memory only
   int h = OpenMetaFileForAppend();
   if(h == INVALID_HANDLE)
      return;
   FileWrite(h, "E", (string)m.positionId, (string)(long)m.signalBar, (string)m.score,
             DoubleToString(m.atrPips, 2), (string)m.atrRegime, (string)m.confirmType, (string)m.trendClass,
             (string)m.zoneTouches, DoubleToString(m.distancePips, 2), DoubleToString(m.spreadPips, 2),
             DoubleToString(m.ask, g_digits), DoubleToString(m.bid, g_digits), DoubleToString(m.slPips, 2),
             DoubleToString(m.tpPips, 2), DoubleToString(m.estCommission, 2), (string)m.slMode,
             DoubleToString(m.riskReward, 2), DoubleToString(m.riskMoney, 2));
   FileClose(h);
  }

void AppendMetaFlag(long positionId, bool trailing)
  {
   if(g_isTester)
      return;
   int h = OpenMetaFileForAppend();
   if(h == INVALID_HANDLE)
      return;
   FileWrite(h, (trailing ? "T" : "B"), (string)positionId);
   FileClose(h);
  }

int ReadCsvLine(int handle, string &fields[])
  {
   ArrayResize(fields, 0);
   int n = 0;
   while(!FileIsEnding(handle))
     {
      string value = FileReadString(handle);
      ArrayResize(fields, n + 1);
      fields[n] = value;
      n++;
      if(FileIsLineEnding(handle))
         break;
     }
   return(n);
  }

void LoadMetaFile()
  {
   ArrayResize(g_meta, 0);
   g_metaCount = 0;
   if(g_isTester || !FileIsExist(MetaFileName(), FILE_COMMON))
      return;
   int h = FileOpen(MetaFileName(), FILE_READ | FILE_CSV | FILE_ANSI | FILE_COMMON, ',');
   if(h == INVALID_HANDLE)
     {
      Print("WARNING: could not read metadata file ", MetaFileName(), " (error ", GetLastError(), ").");
      return;
     }
   string f[];
   while(!FileIsEnding(h))
     {
      int n = ReadCsvLine(h, f);
      if(n >= 19 && f[0] == "E")
        {
         TradeMeta m;
         m.positionId    = StringToInteger(f[1]);
         m.signalBar     = (datetime)StringToInteger(f[2]);
         m.score         = (int)StringToInteger(f[3]);
         m.atrPips       = StringToDouble(f[4]);
         m.atrRegime     = (int)StringToInteger(f[5]);
         m.confirmType   = (int)StringToInteger(f[6]);
         m.trendClass    = (int)StringToInteger(f[7]);
         m.zoneTouches   = (int)StringToInteger(f[8]);
         m.distancePips  = StringToDouble(f[9]);
         m.spreadPips    = StringToDouble(f[10]);
         m.ask           = StringToDouble(f[11]);
         m.bid           = StringToDouble(f[12]);
         m.slPips        = StringToDouble(f[13]);
         m.tpPips        = StringToDouble(f[14]);
         m.estCommission = StringToDouble(f[15]);
         m.slMode        = (int)StringToInteger(f[16]);
         m.riskReward    = StringToDouble(f[17]);
         m.riskMoney     = StringToDouble(f[18]);
         m.beMoved       = false;
         m.trailMoved    = false;
         AddMeta(m);
        }
      else
         if(n >= 2 && (f[0] == "B" || f[0] == "T"))
           {
            int idx = FindMetaIndex(StringToInteger(f[1]));
            if(idx >= 0)
              {
               if(f[0] == "B")
                  g_meta[idx].beMoved = true;
               else
                  g_meta[idx].trailMoved = true;
              }
           }
     }
   FileClose(h);
   Print("Loaded metadata for ", g_metaCount, " trades from ", MetaFileName());
  }

//+------------------------------------------------------------------+
//| Trade records rebuilt from history (restart-safe)                |
//+------------------------------------------------------------------+
void RefreshStatisticsIfNeeded()
  {
   int own = 0;
   CountOpenPositions(own);
   if(own != g_lastOwnPositions)
      g_statsDirty = true;                   // a position opened/closed, even if an event was missed
   if(g_statsDirty)
      RebuildRecords();
  }

void RebuildRecords()
  {
   ArrayResize(g_trades, 0);
   g_tradeCount = 0;
   int own = 0;
   CountOpenPositions(own);
   g_lastOwnPositions = own;

   if(!HistorySelect(0, TimeCurrent() + 86400))
     {
      Print("WARNING: could not load trade history (error ", GetLastError(), ").");
      ComputeSummary();
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
      long   posId      = HistoryDealGetInteger(ticket, DEAL_POSITION_ID);
      bool   ownDeal    = ((ulong)HistoryDealGetInteger(ticket, DEAL_MAGIC) == InpMagicNumber);
      // Entries must carry our magic. Exits are matched by position id instead, because a
      // manual close from the terminal has magic 0 but still closes this EA's position.
      int idx = -1;
      if(entry == DEAL_ENTRY_IN)
        {
         if(!ownDeal)
            continue;
         idx = FindRecentTradeIndex(posId);
        }
      else
        {
         idx = FindTradeIndex(posId);
         if(idx < 0)
            continue;
        }
      double profit     = HistoryDealGetDouble(ticket, DEAL_PROFIT);
      double commission = HistoryDealGetDouble(ticket, DEAL_COMMISSION);
      double swap       = HistoryDealGetDouble(ticket, DEAL_SWAP);

      if(entry == DEAL_ENTRY_IN)
        {
         if(idx >= 0)
           {
            g_trades[idx].volume     += HistoryDealGetDouble(ticket, DEAL_VOLUME);
            g_trades[idx].gross      += profit;
            g_trades[idx].commission += commission;
            g_trades[idx].swap       += swap;
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
         g_trades[idx].gross      = profit;
         g_trades[idx].commission = commission;
         g_trades[idx].swap       = swap;
         g_trades[idx].session    = ClassifySession(g_trades[idx].openTime);
         g_trades[idx].exitReason = -1;
         g_trades[idx].closed     = false;
         ulong orderTicket = (ulong)HistoryDealGetInteger(ticket, DEAL_ORDER);
         g_trades[idx].initialSL  = HistoryOrderGetDouble(orderTicket, ORDER_SL);
         continue;
        }

      if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY || entry == DEAL_ENTRY_INOUT)
        {
         if(idx < 0)
            continue;
         g_trades[idx].gross      += profit;
         g_trades[idx].commission += commission;
         g_trades[idx].swap       += swap;
         g_trades[idx].closeTime   = (datetime)HistoryDealGetInteger(ticket, DEAL_TIME);
         g_trades[idx].closePrice  = HistoryDealGetDouble(ticket, DEAL_PRICE);
         g_trades[idx].exitReason  = (int)HistoryDealGetInteger(ticket, DEAL_REASON);
         g_trades[idx].closed      = true;
        }
     }

   for(int k = 0; k < g_tradeCount; k++)
      FinalizeRecord(g_trades[k]);

   g_statsDirty = false;
   ComputeSummary();
  }

// Net, estimated-cost net, R multiples, outcome, metadata join
void FinalizeRecord(TradeRecord &t)
  {
   t.net = t.gross + t.commission + t.swap;
   int m = FindMetaIndex(t.positionId);
   t.hasMeta = (m >= 0);
   if(t.hasMeta)
      t.meta = g_meta[m];
   else
     {
      t.meta.positionId = t.positionId;
      t.meta.score = -1;
      t.meta.atrRegime = -1;
      t.meta.confirmType = -1;
      t.meta.trendClass = -1;
      t.meta.zoneTouches = 0;
      t.meta.spreadPips = -1.0;
      t.meta.beMoved = false;
      t.meta.trailMoved = false;
     }

   ENUM_ORDER_TYPE type = (t.isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);

   // Estimated extra costs: assumed commission if the broker/tester charged none, plus assumed slippage
   double extra = 0.0;
   if(t.commission == 0.0)
      extra += InpCommissionPerLot * t.volume;
   if(InpSlippageAssumptionPips > 0.0 && t.openPrice > 0.0)
     {
      double pipLoss = 0.0;
      double probe   = (t.isBuy ? t.openPrice - g_pipSize : t.openPrice + g_pipSize);
      if(OrderCalcProfit(type, g_symbol, t.volume, t.openPrice, probe, pipLoss) && pipLoss < 0.0)
         extra += -pipLoss * InpSlippageAssumptionPips;
     }
   t.netAdj = t.net - extra;

   // R = result / money at risk at the initial SL (price move only; costs make a full loss slightly worse than -1R)
   t.hasR = false;
   t.riskMoney = 0.0;
   t.r = 0.0;
   t.rAdj = 0.0;
   if(t.initialSL > 0.0)
     {
      double loss = 0.0;
      if(OrderCalcProfit(type, g_symbol, t.volume, t.openPrice, t.initialSL, loss) && loss < 0.0)
        {
         t.riskMoney = -loss;
         t.r    = t.net / t.riskMoney;
         t.rAdj = t.netAdj / t.riskMoney;
         t.hasR = true;
        }
     }

   if(t.hasR)
      t.outcome = (t.r > BREAKEVEN_BAND_R ? OUTCOME_WIN : (t.r < -BREAKEVEN_BAND_R ? OUTCOME_LOSS : OUTCOME_BE));
   else
      t.outcome = (t.net > 0.0 ? OUTCOME_WIN : (t.net < 0.0 ? OUTCOME_LOSS : OUTCOME_BE));
  }

// Entry deals: only the last few records can belong to the same position (one position at a time)
int FindRecentTradeIndex(long positionId)
  {
   for(int i = g_tradeCount - 1; i >= 0 && i >= g_tradeCount - 3; i--)
      if(g_trades[i].positionId == positionId)
         return(i);
   return(-1);
  }

int FindTradeIndex(long positionId)
  {
   for(int i = g_tradeCount - 1; i >= 0; i--)
      if(g_trades[i].positionId == positionId)
         return(i);
   return(-1);
  }

//+------------------------------------------------------------------+
//| Statistics                                                       |
//+------------------------------------------------------------------+
void ResetGroup(GroupStats &g)
  {
   g.trades         = 0;
   g.wins           = 0;
   g.losses         = 0;
   g.breakevens     = 0;
   g.grossProfit    = 0.0;
   g.grossLoss      = 0.0;
   g.grossProfitAdj = 0.0;
   g.grossLossAdj   = 0.0;
   g.netAdj         = 0.0;
   g.sumR           = 0.0;
   g.sumRAdj        = 0.0;
   g.countR         = 0;
   g.sumWinR        = 0.0;
   g.sumLossR       = 0.0;
   g.largestWin     = 0.0;
   g.largestLoss    = 0.0;
   g.sumSpread      = 0.0;
   g.countSpread    = 0;
   g.cumNet         = 0.0;
   g.peakNet        = 0.0;
   g.maxDD          = 0.0;
  }

void AddToGroup(GroupStats &g, const TradeRecord &t)
  {
   g.trades++;
   if(t.outcome == OUTCOME_WIN)
      g.wins++;
   else
      if(t.outcome == OUTCOME_LOSS)
         g.losses++;
      else
         g.breakevens++;

   if(t.net > 0.0)
      g.grossProfit += t.net;
   else
      g.grossLoss += -t.net;
   if(t.netAdj > 0.0)
      g.grossProfitAdj += t.netAdj;
   else
      g.grossLossAdj += -t.netAdj;
   g.netAdj += t.netAdj;

   if(t.hasR)
     {
      g.sumR    += t.r;
      g.sumRAdj += t.rAdj;
      g.countR++;
      if(t.outcome == OUTCOME_WIN)
         g.sumWinR += t.r;
      if(t.outcome == OUTCOME_LOSS)
         g.sumLossR += t.r;
     }
   if(t.net > g.largestWin)
      g.largestWin = t.net;
   if(t.net < g.largestLoss)
      g.largestLoss = t.net;
   if(t.hasMeta && t.meta.spreadPips >= 0.0)
     {
      g.sumSpread += t.meta.spreadPips;
      g.countSpread++;
     }
   g.cumNet += t.net;
   if(g.cumNet > g.peakNet)
      g.peakNet = g.cumNet;
   if(g.peakNet - g.cumNet > g.maxDD)
      g.maxDD = g.peakNet - g.cumNet;
  }

double GroupNet(const GroupStats &g)
  {
   return(g.grossProfit - g.grossLoss);
  }

// Cheap summary for the dashboard, cooldown and tester criterion
void ComputeSummary()
  {
   ResetGroup(g_summary);
   g_lastLossTime = 0;
   for(int i = 0; i < g_tradeCount; i++)
     {
      if(!g_trades[i].closed)
         continue;
      AddToGroup(g_summary, g_trades[i]);
      if(g_trades[i].outcome == OUTCOME_LOSS)
         g_lastLossTime = g_trades[i].closeTime;
     }
  }

int KeyIndex(int &keys[], GroupStats &groups[], int key)
  {
   int n = ArraySize(keys);
   for(int i = 0; i < n; i++)
      if(keys[i] == key)
         return(i);
   ArrayResize(keys, n + 1);
   ArrayResize(groups, n + 1);
   keys[n] = key;
   ResetGroup(groups[n]);
   return(n);
  }

int ScoreBucket(int score)
  {
   if(score < 60)
      return(0);
   if(score < 70)
      return(1);
   if(score < 80)
      return(2);
   if(score < 90)
      return(3);
   return(4);
  }

string ScoreBucketName(int b)
  {
   if(b == 0)
      return("score <60");
   if(b == 1)
      return("score 60-69");
   if(b == 2)
      return("score 70-79");
   if(b == 3)
      return("score 80-89");
   return("score 90-100");
  }

string TrendClassName(int c)
  {
   if(c == TRENDCLASS_STRONG)
      return("trend strong");
   if(c == TRENDCLASS_PULLBACK)
      return("trend pullback");
   if(c == TRENDCLASS_NONE)
      return("not trend-aligned");
   return("unknown");
  }

void ComputeFullStatistics()
  {
   ComputeSummary();
   ResetGroup(g_statBuy);
   ResetGroup(g_statSell);
   ResetGroup(g_statUnknownMeta);
   for(int s = 0; s < STAT_SESSION_COUNT; s++)
      ResetGroup(g_statSession[s]);
   for(int h = 0; h < 24; h++)
      ResetGroup(g_statHour[h]);
   for(int d = 0; d < 7; d++)
      ResetGroup(g_statDow[d]);
   for(int r = 0; r < REGIME_COUNT; r++)
      ResetGroup(g_statRegime[r]);
   for(int b = 0; b < SCORE_BUCKET_COUNT; b++)
      ResetGroup(g_statScore[b]);
   for(int c = 0; c < CONF_COUNT; c++)
      ResetGroup(g_statConfirm[c]);
   for(int t = 0; t < TRENDCLASS_COUNT; t++)
      ResetGroup(g_statTrend[t]);
   ResetGroup(g_statZone[0]);
   ResetGroup(g_statZone[1]);
   ArrayResize(g_yearKeys, 0);
   ArrayResize(g_statYear, 0);
   ArrayResize(g_monthKeys, 0);
   ArrayResize(g_statMonth, 0);

   g_statMaxConsecLosses = 0;
   g_longestDDDays   = 0.0;
   g_maxDDPct        = 0.0;
   g_avgTradesPerDay = 0.0;

   double totalNet = 0.0;
   for(int i = 0; i < g_tradeCount; i++)
      if(g_trades[i].closed)
         totalNet += g_trades[i].net;
   double startBalance = AccountInfoDouble(ACCOUNT_BALANCE) - totalNet;

   double cumulative = 0.0, peak = 0.0;
   datetime peakTime = 0, firstOpen = 0;
   int consecutive = 0;

   for(int i = 0; i < g_tradeCount; i++)
     {
      if(!g_trades[i].closed)
         continue;
      TradeRecord t = g_trades[i];
      if(firstOpen == 0)
        {
         firstOpen = t.openTime;
         peakTime  = t.openTime;
        }

      if(t.isBuy)
         AddToGroup(g_statBuy, t);
      else
         AddToGroup(g_statSell, t);
      AddToGroup(g_statSession[t.session], t);

      MqlDateTime dt;
      TimeToStruct(t.openTime, dt);
      AddToGroup(g_statHour[dt.hour], t);
      AddToGroup(g_statDow[dt.day_of_week], t);
      int yearIndex  = KeyIndex(g_yearKeys, g_statYear, dt.year);
      int monthIndex = KeyIndex(g_monthKeys, g_statMonth, dt.year * 100 + dt.mon);
      AddToGroup(g_statYear[yearIndex], t);
      AddToGroup(g_statMonth[monthIndex], t);

      if(t.hasMeta)
        {
         if(t.meta.atrRegime >= 0 && t.meta.atrRegime < REGIME_COUNT)
            AddToGroup(g_statRegime[t.meta.atrRegime], t);
         AddToGroup(g_statScore[ScoreBucket(t.meta.score)], t);
         if(t.meta.confirmType >= 0 && t.meta.confirmType < CONF_COUNT)
            AddToGroup(g_statConfirm[t.meta.confirmType], t);
         if(t.meta.trendClass >= 0 && t.meta.trendClass < TRENDCLASS_COUNT)
            AddToGroup(g_statTrend[t.meta.trendClass], t);
         AddToGroup(g_statZone[t.meta.zoneTouches >= 2 ? 1 : 0], t);
        }
      else
         AddToGroup(g_statUnknownMeta, t);

      // Drawdown depth (money, %) and duration on the closed-trade curve
      bool wasUnderWater = (cumulative < peak);
      cumulative += t.net;
      if(cumulative >= peak)
        {
         if(wasUnderWater)
           {
            double recoveredDays = (double)(t.closeTime - peakTime) / 86400.0;
            if(recoveredDays > g_longestDDDays)
               g_longestDDDays = recoveredDays;
           }
         peak     = cumulative;
         peakTime = t.closeTime;
        }
      else
        {
         double dd = peak - cumulative;
         double peakEquity = startBalance + peak;
         if(peakEquity > 0.0 && dd / peakEquity * 100.0 > g_maxDDPct)
            g_maxDDPct = dd / peakEquity * 100.0;
         double days = (double)(t.closeTime - peakTime) / 86400.0;
         if(days > g_longestDDDays)
            g_longestDDDays = days;
        }

      if(t.outcome == OUTCOME_LOSS)
        {
         consecutive++;
         if(consecutive > g_statMaxConsecLosses)
            g_statMaxConsecLosses = consecutive;
        }
      else
         consecutive = 0;
     }
   // Still under water at the end: count the drawdown period until now
   if(firstOpen > 0 && cumulative < peak)
     {
      double days = (double)(TimeCurrent() - peakTime) / 86400.0;
      if(days > g_longestDDDays)
         g_longestDDDays = days;
     }
   if(firstOpen > 0)
     {
      int weekdays = CountWeekdays(firstOpen, TimeCurrent());
      if(weekdays > 0)
         g_avgTradesPerDay = (double)g_summary.trades / weekdays;
     }
  }

int CountWeekdays(datetime from, datetime to)
  {
   long firstDay = (long)from / 86400;
   long lastDay  = (long)to / 86400;
   if(lastDay < firstDay)
      return(0);
   long days  = lastDay - firstDay + 1;
   int  count = (int)(days / 7) * 5;
   MqlDateTime dt;
   TimeToStruct((datetime)(firstDay * 86400), dt);
   int dow = dt.day_of_week;
   for(long r = 0; r < days % 7; r++)
     {
      int d = (int)((dow + r) % 7);
      if(d >= 1 && d <= 5)
         count++;
     }
   return(count);
  }

string SampleLabel(int n)
  {
   if(n < SAMPLE_VERY_WEAK)
      return("[VERY WEAK evidence: <30 trades]");
   if(n < SAMPLE_PRELIMINARY)
      return("[PRELIMINARY: <50 trades]");
   if(n < SAMPLE_LIMITED)
      return("[LIMITED: <100 trades]");
   return("");
  }

string PFText(double grossProfit, double grossLoss)
  {
   if(grossLoss > 0.0)
      return(DoubleToString(grossProfit / grossLoss, 2));
   return(grossProfit > 0.0 ? "inf" : "n/a");
  }

string GroupLine(const string name, const GroupStats &g)
  {
   if(g.trades == 0)
      return(StringFormat("  %-20s n=0", name));
   double net     = GroupNet(g);
   string avgR    = (g.countR > 0 ? StringFormat("%+.2f", g.sumR / g.countR) : "n/a");
   string avgRAdj = (g.countR > 0 ? StringFormat("%+.2f", g.sumRAdj / g.countR) : "n/a");
   return(StringFormat("  %-20s n=%-4d W/L/BE %d/%d/%d  win %5.1f%%  net %10.2f  exp %8.2f  PF %s (est %s)  avgR %s (est %s)  DD %.2f %s",
                       name, g.trades, g.wins, g.losses, g.breakevens, 100.0 * g.wins / g.trades,
                       net, net / g.trades, PFText(g.grossProfit, g.grossLoss), PFText(g.grossProfitAdj, g.grossLossAdj),
                       avgR, avgRAdj, g.maxDD, SampleLabel(g.trades)));
  }

void AddLine(string &lines[], const string text)
  {
   int n = ArraySize(lines);
   ArrayResize(lines, n + 1);
   lines[n] = text;
  }

string ConfigText()
  {
   string sl = (InpSLMode == SL_MODE_FIXED ? StringFormat("fixed %.0f", InpFixedSLPips)
                                           : StringFormat("ATRx%.1f", InpATRSLMultiplier));
   string trail = "off";
   if(InpTrailMode == TRAIL_ATR)
      trail = StringFormat("ATRx%.1f from %.1fR", InpTrailATRMultiplier, InpTrailStartR);
   if(InpTrailMode == TRAIL_FIXED)
      trail = StringFormat("%.0f pips from %.1fR", InpTrailFixedPips, InpTrailStartR);
   string trend = (InpTrendMode == TREND_MODE_EMA_BOTH ? StringFormat("%s EMA%d/%d", TFName(g_trendTF), g_trendFast, g_trendSlow)
                   : (InpTrendMode == TREND_MODE_EMA200 ? StringFormat("%s EMA%d", TFName(g_trendTF), g_trendSlow) : "OFF"));
   string zone  = (g_zoneSource == ZONE_EMA_PULLBACK ? StringFormat("EMA%d pullback", g_pullbackEMA)
                   : StringFormat("swing%s", (InpRequireMultiTouchZone ? " multi" : "")));
   return(StringFormat("Profile=%s Entry=%s Trend=%s Zone=%s Dir=%s%s SL=%s%s maxATRx%.1f RR=%.1f BE=%s Trail=%s "
                       "Score>=%d Confirm=%s EMA%d=%s MinATR=spreadx%.1f Spike=x%.1f Regime=%d Chase=ATRx%.2f "
                       "Session=%s Spread<=%.1f Cooldown=%d Trades/day=%d",
                       ProfileName(), TFName(g_entryTF), trend, zone, (InpAllowBuy ? "B" : ""), (InpAllowSell ? "S" : ""),
                       sl, (InpUseStructureSL ? "+struct" : ""), InpMaxStopLossATR, g_riskReward,
                       (InpBreakEvenEnabled ? StringFormat("%.1fR", InpBreakEvenAtR) : "off"), trail, g_minScore,
                       ConfirmModeText(), InpEntryEMA, (InpRequireEMAConfirm ? "req" : "score"),
                       InpMinATRToSpread, InpMaxATRSpikeRatio, (int)InpATRRegimeFilter, InpMaxDistanceFromZoneATR,
                       SessionModeText(), InpMaxSpreadPips, g_cooldownMin, g_maxTradesPerDay));
  }

void BuildReport(string &lines[])
  {
   ArrayResize(lines, 0);
   string cur = AccountInfoString(ACCOUNT_CURRENCY);
   GroupStats a = g_summary;
   double net    = GroupNet(a);
   double netAdj = a.netAdj;

   AddLine(lines, "==================== GoldBot V4 statistics (" + ProfileName() + ") ====================");
   AddLine(lines, StringFormat("Run: %s | %s | magic %s | %s", ReportTag(), g_symbol, (string)InpMagicNumber,
                               (g_isTester ? "Strategy Tester" : "live/demo account")));
   AddLine(lines, "Config: " + ConfigText());
   AddLine(lines, StringFormat("Cost assumptions: commission %.2f %s per lot round-turn (applied when none was charged), slippage %.1f pips per trade",
                               InpCommissionPerLot, cur, InpSlippageAssumptionPips));
   if(a.trades == 0)
     {
      AddLine(lines, "No closed trades. Nothing to evaluate.");
      AddLine(lines, "===============================================================");
      return;
     }
   AddLine(lines, StringFormat("Sample: %d closed trades %s", a.trades, SampleLabel(a.trades)));
   AddLine(lines, "--- Summary (actual costs = spread, commission and swap charged; 'est' = after estimated extra costs) ---");
   AddLine(lines, StringFormat("Trades %d | Wins %d | Losses %d | Break-even %d (|R| <= %.2f) | Win rate %.1f%%",
                               a.trades, a.wins, a.losses, a.breakevens, BREAKEVEN_BAND_R, 100.0 * a.wins / a.trades));
   AddLine(lines, StringFormat("Net profit %.2f %s | Net after estimated costs %.2f %s", net, cur, netAdj, cur));
   AddLine(lines, StringFormat("Profit factor %s (est %s) | Expectancy per trade %.2f (est %.2f) %s",
                               PFText(a.grossProfit, a.grossLoss), PFText(a.grossProfitAdj, a.grossLossAdj),
                               net / a.trades, netAdj / a.trades, cur));
   if(a.countR > 0)
      AddLine(lines, StringFormat("Total R %+.2f (est %+.2f) | Average R per trade %+.3f (est %+.3f) | R known for %d trades",
                                  a.sumR, a.sumRAdj, a.sumR / a.countR, a.sumRAdj / a.countR, a.countR));
   AddLine(lines, StringFormat("Average win %.2f %s (%s) | Average loss %.2f %s (%s)",
                               (a.wins > 0 ? a.grossProfit / MathMax(1, a.wins) : 0.0), cur,
                               (a.wins > 0 ? StringFormat("%+.2fR", a.sumWinR / a.wins) : "n/a"),
                               (a.losses > 0 ? -a.grossLoss / MathMax(1, a.losses) : 0.0), cur,
                               (a.losses > 0 ? StringFormat("%+.2fR", a.sumLossR / a.losses) : "n/a")));
   AddLine(lines, StringFormat("Largest win %.2f | Largest loss %.2f | Largest win = %.1f%% of net profit",
                               a.largestWin, a.largestLoss, (net > 0.0 ? a.largestWin / net * 100.0 : 0.0)));
   AddLine(lines, StringFormat("Max drawdown (closed trades) %.2f %s (%.2f%%) | Recovery factor %s | Longest drawdown %.0f days",
                               a.maxDD, cur, g_maxDDPct, (a.maxDD > 0.0 ? DoubleToString(net / a.maxDD, 2) : "n/a"),
                               g_longestDDDays));
   AddLine(lines, StringFormat("Max consecutive losses %d | Average trades per weekday %.2f", g_statMaxConsecLosses, g_avgTradesPerDay));

   int positiveMonths = 0, longestNegMonths = 0, negRun = 0;
   for(int i = 0; i < ArraySize(g_monthKeys); i++)
     {
      if(GroupNet(g_statMonth[i]) > 0.0)
        {
         positiveMonths++;
         negRun = 0;
        }
      else
        {
         negRun++;
         if(negRun > longestNegMonths)
            longestNegMonths = negRun;
        }
     }
   int positiveYears = 0;
   for(int i = 0; i < ArraySize(g_yearKeys); i++)
      if(GroupNet(g_statYear[i]) > 0.0)
         positiveYears++;
   AddLine(lines, StringFormat("Months with trades: %d, positive %d (%.0f%%), longest run of non-positive months %d | Years positive %d of %d",
                               ArraySize(g_monthKeys), positiveMonths,
                               (ArraySize(g_monthKeys) > 0 ? 100.0 * positiveMonths / ArraySize(g_monthKeys) : 0.0),
                               longestNegMonths, positiveYears, ArraySize(g_yearKeys)));

   AddLine(lines, "--- By direction (DD = drawdown of that direction's own trades) ---");
   AddLine(lines, GroupLine("BUY", g_statBuy));
   AddLine(lines, GroupLine("SELL", g_statSell));
   AddLine(lines, "--- By session (entry time) ---");
   for(int s = 0; s < STAT_SESSION_COUNT; s++)
      AddLine(lines, GroupLine(SessionName(s), g_statSession[s]));
   AddLine(lines, "--- By year ---");
   for(int i = 0; i < ArraySize(g_yearKeys); i++)
      AddLine(lines, GroupLine((string)g_yearKeys[i], g_statYear[i]));
   AddLine(lines, "--- By ATR regime at entry (ATR vs its 24h average) ---");
   for(int r = 0; r < REGIME_COUNT; r++)
      AddLine(lines, GroupLine("ATR " + RegimeName(r), g_statRegime[r]));
   AddLine(lines, "--- By quality score ---");
   for(int b = 0; b < SCORE_BUCKET_COUNT; b++)
      AddLine(lines, GroupLine(ScoreBucketName(b), g_statScore[b]));
   AddLine(lines, "--- By confirmation type ---");
   for(int c = 0; c < CONF_COUNT; c++)
      AddLine(lines, GroupLine(ConfirmName(c), g_statConfirm[c]));
   AddLine(lines, "--- By trend strength ---");
   for(int t = 0; t < TRENDCLASS_COUNT; t++)
      AddLine(lines, GroupLine(TrendClassName(t), g_statTrend[t]));
   AddLine(lines, "--- By zone type ---");
   AddLine(lines, GroupLine("single-swing zone", g_statZone[0]));
   AddLine(lines, GroupLine("multi-reaction zone", g_statZone[1]));
   if(g_statUnknownMeta.trades > 0)
      AddLine(lines, GroupLine("metadata missing", g_statUnknownMeta));
   AddLine(lines, "--- By weekday (entry) ---");
   string dayNames[7] = {"Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"};
   for(int d = 0; d < 7; d++)
      if(g_statDow[d].trades > 0)
         AddLine(lines, GroupLine(dayNames[d], g_statDow[d]));
   AddLine(lines, "--- By entry hour (server time) ---");
   for(int h = 0; h < 24; h++)
      if(g_statHour[h].trades > 0)
         AddLine(lines, GroupLine(StringFormat("hour %02d", h), g_statHour[h]));
   AddLine(lines, "--- By month ---");
   for(int i = 0; i < ArraySize(g_monthKeys); i++)
      AddLine(lines, GroupLine(StringFormat("%04d-%02d", g_monthKeys[i] / 100, g_monthKeys[i] % 100), g_statMonth[i]));

   AddLine(lines, "--- Reminders ---");
   if(a.trades < SAMPLE_LIMITED)
      AddLine(lines, "WARNING: fewer than 100 trades. Treat every figure above as limited evidence.");
   AddLine(lines, "Groups with few trades are labelled. A high profit factor from a small sample is not reliable evidence.");
   AddLine(lines, "In-sample results say nothing on their own. Confirm on out-of-sample data and a demo forward test.");
   AddLine(lines, "Historical results do not guarantee future performance.");
   AddLine(lines, "===============================================================");
  }

string ReportTag()
  {
   if(StringLen(InpReportTag) > 0)
      return(InpReportTag);
   return(g_symbol + "_" + (string)InpMagicNumber + (g_isTester ? "_tester" : "_live"));
  }

void WriteReportFile(string &lines[])
  {
   string fileName = "GoldBotV4_" + ReportTag() + "_report.txt";
   int handle = FileOpen(fileName, FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON);
   if(handle == INVALID_HANDLE)
     {
      Print("WARNING: could not write ", fileName, " (error ", GetLastError(), ").");
      return;
     }
   for(int i = 0; i < ArraySize(lines); i++)
      FileWriteString(handle, lines[i] + "\r\n");
   FileClose(handle);
   Print("Report written -> <Common Data Folder>\\Files\\", fileName);
  }

string ExitReasonText(const TradeRecord &t)
  {
   if(t.exitReason == DEAL_REASON_TP)
      return("take profit");
   if(t.exitReason == DEAL_REASON_SL)
     {
      if(t.meta.trailMoved)
         return("trailing stop");
      if(t.meta.beMoved || (t.hasR && t.r > -0.5))
         return("stop after break-even");
      return("stop loss");
     }
   if(t.exitReason == DEAL_REASON_SO)
      return("stop out (margin)");
   return("manual/other");
  }

string OutcomeText(int outcome)
  {
   if(outcome == OUTCOME_WIN)
      return("WIN");
   if(outcome == OUTCOME_LOSS)
      return("LOSS");
   return("BREAKEVEN");
  }

string MetaInt(bool has, int value)
  {
   return(has && value >= 0 ? (string)value : "");
  }

string MetaDouble(bool has, double value, int digits)
  {
   return(has ? DoubleToString(value, digits) : "");
  }

void WriteTradesCSV()
  {
   string fileName = "GoldBotV4_" + ReportTag() + "_trades.csv";
   int handle = FileOpen(fileName, FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_COMMON, ',');
   if(handle == INVALID_HANDLE)
     {
      Print("WARNING: could not write ", fileName, " (error ", GetLastError(), ").");
      return;
     }
   FileWrite(handle, "position", "direction", "open_time", "close_time", "year", "month", "weekday", "hour",
             "session", "open_price", "close_price", "initial_sl", "volume", "sl_pips", "tp_pips", "risk_money",
             "spread_pips", "ask", "bid", "atr_pips", "atr_regime", "score", "score_range", "confirmation",
             "trend", "zone", "distance_from_zone_pips", "sl_mode", "risk_reward", "break_even_moved",
             "trailing_moved", "est_commission", "gross", "commission", "swap", "net", "net_after_est_costs",
             "r", "r_after_est_costs", "outcome", "exit");
   int written = 0;
   for(int i = 0; i < g_tradeCount; i++)
     {
      if(!g_trades[i].closed)
         continue;
      TradeRecord t = g_trades[i];
      bool hm = t.hasMeta;
      MqlDateTime dt;
      TimeToStruct(t.openTime, dt);
      FileWrite(handle,
                (string)t.positionId,
                (t.isBuy ? "BUY" : "SELL"),
                TimeToString(t.openTime, TIME_DATE | TIME_MINUTES),
                TimeToString(t.closeTime, TIME_DATE | TIME_MINUTES),
                (string)dt.year, (string)dt.mon, (string)dt.day_of_week, (string)dt.hour,
                SessionName(t.session),
                DoubleToString(t.openPrice, g_digits),
                DoubleToString(t.closePrice, g_digits),
                DoubleToString(t.initialSL, g_digits),
                DoubleToString(t.volume, 2),
                MetaDouble(hm, t.meta.slPips, 1),
                MetaDouble(hm, t.meta.tpPips, 1),
                DoubleToString(t.riskMoney, 2),
                MetaDouble(hm, t.meta.spreadPips, 1),
                MetaDouble(hm, t.meta.ask, g_digits),
                MetaDouble(hm, t.meta.bid, g_digits),
                MetaDouble(hm, t.meta.atrPips, 1),
                (hm && t.meta.atrRegime >= 0 ? RegimeName(t.meta.atrRegime) : ""),
                MetaInt(hm, t.meta.score),
                (hm ? ScoreBucketName(ScoreBucket(t.meta.score)) : ""),
                (hm ? ConfirmName(t.meta.confirmType) : ""),
                (hm ? TrendClassName(t.meta.trendClass) : ""),
                (hm ? (t.meta.zoneTouches >= 2 ? "multi" : "single") : ""),
                MetaDouble(hm, t.meta.distancePips, 1),
                (hm ? (t.meta.slMode == (int)SL_MODE_FIXED ? "fixed" : "ATR") : ""),
                MetaDouble(hm, t.meta.riskReward, 1),
                (hm ? (t.meta.beMoved ? "1" : "0") : ""),
                (hm ? (t.meta.trailMoved ? "1" : "0") : ""),
                MetaDouble(hm, t.meta.estCommission, 2),
                DoubleToString(t.gross, 2),
                DoubleToString(t.commission, 2),
                DoubleToString(t.swap, 2),
                DoubleToString(t.net, 2),
                DoubleToString(t.netAdj, 2),
                (t.hasR ? DoubleToString(t.r, 3) : ""),
                (t.hasR ? DoubleToString(t.rAdj, 3) : ""),
                OutcomeText(t.outcome),
                ExitReasonText(t));
      written++;
     }
   FileClose(handle);
   Print("Trade list written: ", written, " trades -> <Common Data Folder>\\Files\\", fileName);
  }

void LogClosedTrade(const TradeRecord &t)
  {
   string cur = AccountInfoString(ACCOUNT_CURRENCY);
   long held = (long)(t.closeTime - t.openTime) / 60;
   Print("TRADE CLOSED: ", (t.isBuy ? "BUY" : "SELL"), " ", g_symbol, " #", t.positionId, " - ", ExitReasonText(t),
         " | ", OutcomeText(t.outcome), " | held ", held / 60, "h ", held % 60, "m");
   Print(StringFormat("   Net %.2f %s (gross %.2f, commission %.2f, swap %.2f) | after est. costs %.2f | R %s (est %s)",
                      t.net, cur, t.gross, t.commission, t.swap, t.netAdj,
                      (t.hasR ? StringFormat("%+.2f", t.r) : "n/a"), (t.hasR ? StringFormat("%+.2f", t.rAdj) : "n/a")));
   if(t.hasMeta)
      Print(StringFormat("   Entry context: score %d, %s, %s, ATR %.1f pips (%s), spread %.1f pips, %s zone, break-even %s, trailing %s",
                         t.meta.score, SessionName(t.session), ConfirmName(t.meta.confirmType), t.meta.atrPips,
                         RegimeName(t.meta.atrRegime), t.meta.spreadPips, (t.meta.zoneTouches >= 2 ? "multi" : "single"),
                         (t.meta.beMoved ? "moved" : "not moved"), (t.meta.trailMoved ? "moved" : "not moved")));
  }

//+------------------------------------------------------------------+
//| Checklist log                                                    |
//+------------------------------------------------------------------+
void InitCheck(SetupCheck &c, bool isBuy)
  {
   c.isBuy        = isBuy;
   c.trendText    = "";
   c.trendScore   = 0;
   c.trendClass   = TRENDCLASS_NONE;
   c.zoneOk       = false;
   c.zoneText     = "";
   c.zoneScore    = 0;
   c.zoneTouches  = 0;
   c.candleOk     = false;
   c.candleText   = "";
   c.candleScore  = 0;
   c.confirmType  = -1;
   c.emaOk        = false;
   c.emaText      = "";
   c.emaScore     = 0;
   c.atrOk        = false;
   c.atrText      = "";
   c.atrScore     = 0;
   c.chaseOk      = false;
   c.chaseText    = "";
   c.distancePips = 0.0;
   c.slOk         = false;
   c.slText       = "";
   c.slDistance   = 0.0;
   c.spreadOk     = false;
   c.spreadText   = "";
   c.spreadPips   = 0.0;
   c.score        = 0;
   c.scoreOk      = false;
   c.timeOk       = false;
   c.timeText     = "";
   c.riskOk       = false;
   c.riskText     = "";
   c.accountOk    = false;
   c.accountText  = "";
   c.positionOk   = false;
   c.positionText = "";
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
   string trendMark = (InpTrendMode == TREND_MODE_OFF ? "[--]" : "[OK]");
   string emaMark   = (c.emaScore > 0 ? "[OK]" : (c.emaOk ? "[--]" : "[X] "));

   Print(g_candleLabel, (accepted ? "SETUP CHECK - " : "SETUP REJECTED - "), direction);
   Print("   Trend    ", trendMark, " ", c.trendText, Points(c.trendScore));
   Print("   Zone     ", Mark(c.zoneOk), " ", c.zoneText, Points(c.zoneScore));
   Print("   Candle   ", Mark(c.candleOk), " ", c.candleText, Points(c.candleScore));
   Print("   EMA", InpEntryEMA, "     ", emaMark, " ", c.emaText, Points(c.emaScore));
   Print("   ATR      ", Mark(c.atrOk), " ", c.atrText, Points(c.atrScore));
   Print("   Entry    ", Mark(c.chaseOk), " ", c.chaseText);
   Print("   StopLoss ", Mark(c.slOk), " ", c.slText);
   Print("   Spread   ", Mark(c.spreadOk), " ", c.spreadText);
   Print("   Session  ", Mark(c.timeOk), " ", c.timeText);
   Print("   Score    ", Mark(c.scoreOk), " ", StringFormat("%d/100 (minimum %s)", c.score,
         (g_minScore > 0 ? (string)g_minScore : "off")));
   Print("   Risk     ", Mark(c.riskOk), " ", c.riskText);
   Print("   Account  ", Mark(c.accountOk), " ", c.accountText);
   Print("   Position ", Mark(c.positionOk), " ", c.positionText);
   if(accepted)
      Print("   Risk: ACCEPTED   ACTION: ", direction);
   else
      Print("   ACTION: NO TRADE - Reason: ", c.failures, ".");
  }

//+------------------------------------------------------------------+
//| Dashboard                                                        |
//+------------------------------------------------------------------+
void UpdateDashboard()
  {
   if(!InpShowDashboard || g_isFastTester || !g_initialized)
      return;
   g_lastDashUpdate = TimeCurrent();
   ManageDailyLimits();

   string setupText = "WAITING";
   if(g_setupState == SETUP_BUY)
      setupText = "BUY";
   else
      if(g_setupState == SETUP_SELL)
         setupText = "SELL";

   string cur    = AccountInfoString(ACCOUNT_CURRENCY);
   double dayPL  = g_daily.realizedPL + g_daily.floatingPL;
   double dayPct = (g_dayStartBalance > 0.0 ? dayPL / g_dayStartBalance * 100.0 : 0.0);
   double spread = CurrentSpreadPips();

   string status = "ACTIVE";
   datetime until = 0;
   if(!InpTradingEnabled)
      status = "STOPPED - emergency switch";
   else
      if(g_accountHalted)
         status = "STOPPED - account drawdown halt";
      else
         if(g_tradingStopped)
            status = "STOPPED - " + g_stopReason;
         else
            if(IsInCooldown(until))
               status = "COOLDOWN until " + TimeToString(until, TIME_MINUTES);

   int nowMin = MinutesOfDay(TimeCurrent());
   string sessionState = CurrentSessionLabel() + (IsInTradingSession(nowMin) ? " [trading]" : " [not traded]");
   if(IsNewsBlackout(nowMin))
      sessionState += " NEWS BLACKOUT";

   GroupStats a = g_summary;
   string expText = "n/a", pfText = "n/a", avgRText = "n/a";
   if(a.trades > 0)
     {
      expText = StringFormat("%.2f %s/trade (est %.2f)", GroupNet(a) / a.trades, cur, a.netAdj / a.trades);
      pfText  = PFText(a.grossProfit, a.grossLoss) + " (est " + PFText(a.grossProfitAdj, a.grossLossAdj) + ")";
      if(a.countR > 0)
         avgRText = StringFormat("%+.2f (est %+.2f)", a.sumR / a.countR, a.sumRAdj / a.countR);
     }

   string text = "XAUUSD V4 [" + ProfileName() + "]  (" + g_symbol + ")\n";
   text += "------------------------------\n";
   text += "Trend: " + (InpTrendMode == TREND_MODE_OFF ? "OFF (test) - " : TFName(g_trendTF) + " ") + TrendStateText() + "\n";
   text += "Setup: " + setupText + "\n";
   text += StringFormat("Score: %d/100 (min %s)\n", g_lastScore, (g_minScore > 0 ? (string)g_minScore : "off"));
   text += StringFormat("ATR: %.1f pips (%s)\n", g_atr / g_pipSize, RegimeName(g_atrRegime));
   text += (spread >= 0.0 ? StringFormat("Spread: %.1f pips (max %.1f)\n", spread, InpMaxSpreadPips) : "Spread: n/a\n");
   text += "Session: " + sessionState + "\n";
   text += "------------------------------\n";
   text += StringFormat("Today's Trades: %d%s\n", g_daily.tradesToday,
                        (g_maxTradesPerDay > 0 ? StringFormat(" / %d", g_maxTradesPerDay) : ""));
   text += StringFormat("Today's Wins: %d\n", g_daily.winsToday);
   text += StringFormat("Today's Losses: %d\n", g_daily.lossesToday);
   text += StringFormat("Today's P/L: %.2f %s (%.2f%%)\n", dayPL, cur, dayPct);
   text += StringFormat("Today's R: %+.2f\n", g_daily.rToday);
   text += StringFormat("Consecutive Losses: %d%s\n", g_daily.consecutiveLosses,
                        (g_maxConsecLosses > 0 ? StringFormat(" / %d", g_maxConsecLosses) : ""));
   text += "Daily Status: " + status + "\n";
   text += "Current Position: " + CurrentPositionText() + "\n";
   text += (InpLotMode == LOT_MODE_RISK ? StringFormat("Risk: %.2f%% per trade\n", InpRiskPercent)
                                        : StringFormat("Risk: fixed %.2f lots\n", InpFixedLotSize));
   text += "------------------------------\n";
   text += StringFormat("All trades: %d %s\n", a.trades, SampleLabel(a.trades));
   text += "Expectancy: " + expText + "\n";
   text += "Average R: " + avgRText + "\n";
   text += "Profit Factor: " + pfText + "\n";
   text += StringFormat("Maximum Drawdown: %.2f %s\n", a.maxDD, cur);
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
   if(g_trendFast <= 0 || g_trendSlow <= 0 || g_trendFast >= g_trendSlow)
     { Print("INPUT ERROR: trend EMA periods must be > 0 and fast < slow."); ok = false; }
   if(InpEntryEMA <= 0 || InpATRPeriod <= 0)
     { Print("INPUT ERROR: entry EMA and ATR periods must be > 0."); ok = false; }
   if(InpMinATRToSpread < 0.0 || InpMaxATRSpikeRatio < 0.0 || (InpMaxATRSpikeRatio > 0.0 && InpMaxATRSpikeRatio <= 1.0))
     { Print("INPUT ERROR: ATR/spread ratio must be >= 0 and the spike ratio 0 (off) or above 1.0."); ok = false; }
   if(g_zoneSource == ZONE_EMA_PULLBACK && (g_pullbackEMA <= 0 || g_pullbackEMA <= InpEntryEMA))
     { Print("INPUT ERROR: pullback EMA must be > 0 and longer than the entry timing EMA."); ok = false; }
   if(PeriodSeconds(g_trendTF) < PeriodSeconds(g_entryTF))
     { Print("INPUT ERROR: trend timeframe must not be shorter than the entry timeframe."); ok = false; }
   if(InpSwingStrength < 1 || InpSwingStrength > 10)
     { Print("INPUT ERROR: swing strength must be between 1 and 10."); ok = false; }
   if(InpSwingLookbackBars < InpSwingStrength * 2 + 5 || InpSwingLookbackBars > 1000)
     { Print("INPUT ERROR: swing lookback must be between (2 x strength + 5) and 1000 bars."); ok = false; }
   if(InpZoneMergeATR < 0.0 || InpZoneDistanceATR <= 0.0 || InpMaxDistanceFromZoneATR < 0.0)
     { Print("INPUT ERROR: zone merge >= 0, zone distance > 0, max distance from zone >= 0 (ATR multiples)."); ok = false; }
   if(g_minScore < 0 || g_minScore > 100)
     { Print("INPUT ERROR: minimum score must be 0-100."); ok = false; }
   if(InpFixedSLPips <= 0.0 || InpATRSLMultiplier <= 0.0 || InpSLBufferATR < 0.0 || InpMaxStopLossATR <= 0.0)
     { Print("INPUT ERROR: SL settings must be positive (buffer may be 0)."); ok = false; }
   if(InpSLMode == SL_MODE_ATR && InpATRSLMultiplier >= InpMaxStopLossATR)
     { Print("INPUT ERROR: ATR SL multiplier must be below the maximum SL multiple, otherwise almost no trade can be taken."); ok = false; }
   if(g_riskReward < 1.0 || g_riskReward > 10.0)
     { Print("INPUT ERROR: risk:reward must be between 1.0 and 10.0."); ok = false; }
   if(InpBreakEvenAtR <= 0.0 || InpBreakEvenBufferPips < 0.0)
     { Print("INPUT ERROR: break-even trigger must be > 0 and buffer >= 0."); ok = false; }
   if(InpTrailStartR <= 0.0 || InpTrailATRMultiplier <= 0.0 || InpTrailFixedPips <= 0.0)
     { Print("INPUT ERROR: trailing settings must be > 0."); ok = false; }
   if(InpRiskPercent <= 0.0 || InpRiskPercent > 5.0)
     { Print("INPUT ERROR: risk per trade must be > 0 and <= 5%."); ok = false; }
   if(InpMaxLotSize <= 0.0)
     { Print("INPUT ERROR: safety lot cap must be > 0."); ok = false; }
   if(InpFixedLotSize <= 0.0 || InpFixedLotSize > InpMaxLotSize)
     { Print("INPUT ERROR: fixed lot must be > 0 and not above the safety cap."); ok = false; }
   if(InpCommissionPerLot < 0.0 || InpSlippageAssumptionPips < 0.0)
     { Print("INPUT ERROR: cost assumptions cannot be negative."); ok = false; }
   if(InpMaxDailyLossPercent < 0.0 || InpMaxDailyLossPercent > 100.0 || InpMaxDailyProfitPercent < 0.0)
     { Print("INPUT ERROR: daily loss must be 0-100% and daily profit >= 0."); ok = false; }
   if(g_maxConsecLosses < 0 || g_maxTradesPerDay < 0 || g_cooldownMin < 0)
     { Print("INPUT ERROR: daily counters and cooldown cannot be negative."); ok = false; }
   if(InpMaxAccountDrawdownPercent < 0.0 || InpMaxAccountDrawdownPercent > 100.0)
     { Print("INPUT ERROR: account drawdown limit must be 0-100%."); ok = false; }
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

   if(!ok)
      return(false);

   // Testing-only settings are allowed but announced loudly
   if(InpTrendMode == TREND_MODE_OFF)
      Print("TEST MODE: trend filter is OFF. Trend score is 0, so the maximum score is 70 (60 with EMA-pullback zones).");
   if(InpSLMode == SL_MODE_ATR && InpMaxStopLossATR - InpATRSLMultiplier < 0.5)
      Print("NOTE: max SL multiple is close to the ATR SL multiplier; structure stops will often exceed it.");
   if(InpSLMode == SL_MODE_FIXED)
      Print("NOTE: fixed SL mode still obeys the ATR-based maximum SL (ATR x ", DoubleToString(InpMaxStopLossATR, 1),
            "), so in quiet markets the fixed SL can be rejected as too large.");
   if(InpSessionMode == SESSION_ALL_DAY)
      Print("TEST MODE: session filter is OFF (all day).");
   if(InpMaxDailyLossPercent == 0.0 || g_maxConsecLosses == 0 || g_maxTradesPerDay == 0)
      Print("TEST MODE: at least one daily protection limit is OFF. Do not use this on a real account.");
   if(InpMaxAccountDrawdownPercent == 0.0)
      Print("NOTE: account drawdown protection is OFF.");
   if(InpTrailMode != TRAIL_OFF && InpBreakEvenEnabled && InpTrailStartR < InpBreakEvenAtR)
      Print("NOTE: trailing starts before break-even. That is allowed but more aggressive.");
   return(true);
  }

//+------------------------------------------------------------------+
//| Startup summary                                                  |
//+------------------------------------------------------------------+
void PrintSettings()
  {
   Print("================ GoldBot V4 started - profile ", ProfileName(), " ================");
   Print("Entry timeframe: ", TFName(g_entryTF), " | Trend timeframe: ", TFName(g_trendTF), " | Zones: ",
         (g_zoneSource == ZONE_EMA_PULLBACK ? StringFormat("pullback to EMA%d", g_pullbackEMA) : "swing S/R"),
         " | Target: ", DoubleToString(g_riskReward, 1), "R");
   if(InpProfile != PROFILE_CUSTOM)
      Print("Profile ", ProfileName(), " overrides the [custom] inputs (timeframes, zone source, trend EMAs, R:R, ",
            "min score, consecutive losses, trades/day, cooldown). Choose CUSTOM to use your own values.");
   Print("Symbol: ", g_symbol, " | Digits: ", g_digits, " | Point: ", DoubleToString(g_point, g_digits),
         " | Tick size: ", DoubleToString(SymbolInfoDouble(g_symbol, SYMBOL_TRADE_TICK_SIZE), g_digits),
         " | Tick value: ", DoubleToString(SymbolInfoDouble(g_symbol, SYMBOL_TRADE_TICK_VALUE), 4),
         " | Contract size: ", DoubleToString(SymbolInfoDouble(g_symbol, SYMBOL_TRADE_CONTRACT_SIZE), 2));
   Print(StringFormat("1 pip = %s price = %.1f points%s",
                      DoubleToString(g_pipSize, (g_digits > 2 ? g_digits : 2)), g_pipSize / g_point,
                      (InpPipSize > 0.0 ? " (manual)" : " (auto)")));
   double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   if(bid > 0.0)
     {
      double pipValue = LossPerLot(false, bid, bid + g_pipSize);
      if(pipValue > 0.0)
         Print(StringFormat("Value of 1 pip: %.2f %s per 1.00 lot (%.2f per 0.01 lot)",
                            pipValue, AccountInfoString(ACCOUNT_CURRENCY), pipValue / 100.0));
     }
   Print("Lots: min ", DoubleToString(SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MIN), 2),
         " / max ", DoubleToString(SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MAX), 2),
         " / step ", DoubleToString(SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_STEP), 2),
         " | Mode: ", (InpLotMode == LOT_MODE_RISK ? StringFormat("RISK %.2f%%", InpRiskPercent)
                                                  : StringFormat("FIXED %.2f", InpFixedLotSize)),
         " | Safety cap: ", DoubleToString(InpMaxLotSize, 2));
   Print("Config: ", ConfigText());
   Print(StringFormat("Costs: commission assumption %.2f per lot round-turn | slippage assumption %.1f pips per trade",
                      InpCommissionPerLot, InpSlippageAssumptionPips));
   Print(StringFormat("Daily: loss %s | profit %s | consecutive %s | trades/day %s | cooldown %s",
                      (InpMaxDailyLossPercent > 0.0 ? StringFormat("%.2f%%", InpMaxDailyLossPercent) : "off"),
                      (InpMaxDailyProfitPercent > 0.0 ? StringFormat("%.2f%%", InpMaxDailyProfitPercent) : "off"),
                      (g_maxConsecLosses > 0 ? (string)g_maxConsecLosses : "off"),
                      (g_maxTradesPerDay > 0 ? (string)g_maxTradesPerDay : "off"),
                      (g_cooldownMin > 0 ? StringFormat("%d min", g_cooldownMin) : "off")));
   Print(StringFormat("Account: emergency switch %s | equity drawdown halt %s | peak equity %.2f%s",
                      (InpTradingEnabled ? "trading ON" : "trading OFF"),
                      (InpMaxAccountDrawdownPercent > 0.0 ? StringFormat("%.1f%%", InpMaxAccountDrawdownPercent) : "off"),
                      g_peakEquity, (g_accountHalted ? " | HALT ACTIVE" : "")));
   Print("News blackout: ", (InpNewsFilterEnabled ? InpNewsStartTime + "-" + InpNewsEndTime : "off"),
         " | Max spread: ", DoubleToString(InpMaxSpreadPips, 1), " pips");
   Print("History: ", g_summary.trades, " closed trades found for this EA (magic ", InpMagicNumber, "). ",
         SampleLabel(g_summary.trades));
   Print("Setups are evaluated once per closed ", TFName(g_entryTF), " candle. Max open positions: ", MAX_OPEN_POSITIONS);
   if(g_riskReward < 2.0)
      Print("NOTE: with a ", DoubleToString(g_riskReward, 1), "R target the break-even win rate is ",
            DoubleToString(100.0 / (1.0 + g_riskReward), 0), "% before costs. Spread and commission weigh more on small scalps.");
   Print("====================================================");
  }
//+------------------------------------------------------------------+
