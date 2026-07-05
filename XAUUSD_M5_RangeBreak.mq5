//+------------------------------------------------------------------+
//|                     XAUUSD M5 Range Break EA                     |
//|                   Professional Trading System                    |
//|                    Using CTrade Class & Best Practices           |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026 - Professional Trading"
#property link      "https://www.mql5.com"
#property version   "1.00"
#property strict
#property description "XAUUSD M5 Range Break System with Trend Filter"

//--- Input parameters
input group "=== TRADING PARAMETERS ==="
input double RiskPercent = 1.0;                    // Risk per trade (%)
input double ATRMultiplier = 1.5;                  // ATR multiplier for SL
input double TPMultiplier = 2.0;                   // TP is SL × this value
input int MaxTradesPerDay = 1;                     // Maximum trades per day
input double DailyLossLimit = 2.0;                 // Daily loss limit (%)
input double DailyProfitTarget = 4.0;              // Daily profit target (%)
input double MaxSpreadPoints = 3.0;                // Maximum spread in points

input group "=== TIME PARAMETERS (IST) ==="
input string PreSessionStart = "18:00";            // Pre-session start (IST)
input string PreSessionEnd = "19:00";              // Pre-session end (IST)
input string TradingSessionStart = "19:00";        // Trading session start (IST)
input string TradingSessionEnd = "23:00";          // Trading session end (IST)

input group "=== INDICATOR PARAMETERS ==="
input int ATRPeriod = 14;                          // ATR period
input int EMA50Period = 50;                        // EMA 50 period
input int EMA200Period = 200;                      // EMA 200 period
input int TrailingStopPoints = 10;                 // Trailing stop (points after 1R)

input group "=== NOTIFICATION SETTINGS ==="
input bool EnableNotifications = true;             // Enable push notifications
input bool EnableAlerts = true;                    // Enable sound alerts

//--- Include CTrade class
#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\OrderInfo.mqh>

//--- Global variables
CTrade trade;
CPositionInfo positionInfo;
COrderInfo orderInfo;

double preSessionHigh = 0;
double preSessionLow = 0;
bool preSessionRecorded = false;
datetime lastTradeDate = 0;
double dailyProfitLoss = 0;
double breakEvenLevel = 0;
double trailingStopLevel = 0;
bool breakEvenSet = false;
bool trailingStopActive = false;

// Dashboard variables
int dashboardHandle = -1;
double currentATR = 0;
double currentEMA50 = 0;
double currentEMA200 = 0;
int currentSpread = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   // Validate symbol
   if(Symbol() != "XAUUSD")
   {
      Alert("This EA is designed for XAUUSD only!");
      return INIT_FAILED;
   }
   
   // Validate timeframe
   if(Period() != PERIOD_M5)
   {
      Alert("This EA is designed for M5 timeframe only!");
      return INIT_FAILED;
   }
   
   // Initialize CTrade object
   trade.SetExpertMagicNumber(20260705);           // Magic number for trade identification
   trade.SetAsyncMode(true);                       // Async mode for reliability
   
   // Set trade deviation to avoid slippage issues
   trade.SetDeviationInPoints(10);
   
   // Initialize position info
   positionInfo.SelectByMagic(Symbol(), trade.RequestMagic());
   
   // Print initialization message
   Print("XAUUSD M5 Range Break EA initialized successfully!");
   Print("Magic Number: ", trade.RequestMagic());
   Print("Risk per trade: ", RiskPercent, "%");
   Print("Daily loss limit: ", DailyLossLimit, "%");
   Print("Daily profit target: ", DailyProfitTarget, "%");
   
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Print("EA deinitialized. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // Update current values for dashboard
   UpdateIndicatorValues();
   
   // Check if it's a new day and reset daily variables
   CheckNewDay();
   
   // Calculate daily P&L
   CalculateDailyPnL();
   
   // Record pre-session range (18:00-19:00 IST)
   if(IsPreSessionTime())
   {
      RecordPreSessionRange();
   }
   
   // Trading logic runs during trading session (19:00-23:00 IST)
   if(IsTradingSessionTime() && !IsPreSessionTime())
   {
      // Check daily loss limit
      if(dailyProfitLoss <= -(AccountBalance() * DailyLossLimit / 100))
      {
         SendNotification("Daily loss limit reached! Trading disabled for today.");
         return;
      }
      
      // Check daily profit target
      if(dailyProfitLoss >= (AccountBalance() * DailyProfitTarget / 100))
      {
         SendNotification("Daily profit target reached! Trading disabled for today.");
         return;
      }
      
      // Check if max trades per day reached
      if(CountTradesToday() >= MaxTradesPerDay)
      {
         return;
      }
      
      // Check spread filter
      if(GetCurrentSpread() > MaxSpreadPoints)
      {
         return;
      }
      
      // Trading logic
      ProcessTrades();
   }
   
   // Manage open positions (break-even, trailing stop)
   ManageOpenPositions();
   
   // Update dashboard
   UpdateDashboard();
}

//+------------------------------------------------------------------+
//| Process trading signals and open positions                       |
//+------------------------------------------------------------------+
void ProcessTrades()
{
   // Get current price and range values
   double currentBid = SymbolInfoDouble(Symbol(), SYMBOL_BID);
   double currentAsk = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
   
   // Don't trade if pre-session range not recorded
   if(!preSessionRecorded)
      return;
   
   // Check for existing position
   if(positionInfo.SelectByMagic(Symbol(), trade.RequestMagic()))
      return;  // Only 1 trade per day
   
   // Get trend filter values
   double ema50 = GetEMA(EMA50Period);
   double ema200 = GetEMA(EMA200Period);
   double atr = GetATR();
   
   // BUY SIGNAL: Price breaks above range high + EMA50 > EMA200
   if(currentBid > preSessionHigh && ema50 > ema200)
   {
      OpenBuyPosition(atr, currentAsk);
      return;
   }
   
   // SELL SIGNAL: Price breaks below range low + EMA50 < EMA200
   if(currentBid < preSessionLow && ema50 < ema200)
   {
      OpenSellPosition(atr, currentBid);
      return;
   }
}

//+------------------------------------------------------------------+
//| Open buy position with proper risk management                    |
//+------------------------------------------------------------------+
void OpenBuyPosition(double atr, double entryPrice)
{
   // Calculate stop loss and take profit
   double stopLoss = atr * ATRMultiplier;
   double takeProfit = stopLoss * TPMultiplier;
   double slPrice = entryPrice - stopLoss;
   double tpPrice = entryPrice + takeProfit;
   
   // Validate prices
   if(slPrice <= 0 || tpPrice <= 0)
      return;
   
   // Calculate volume based on risk
   double volume = CalculateVolume(stopLoss);
   
   if(volume <= 0)
   {
      Print("Invalid volume calculated: ", volume);
      return;
   }
   
   // Normalize volume to symbol specifications
   volume = NormalizeVolume(volume);
   
   // Place order
   if(trade.Buy(volume, Symbol(), entryPrice, slPrice, tpPrice, "Range Break Buy"))
   {
      Print("BUY order placed - Entry: ", entryPrice, " SL: ", slPrice, " TP: ", tpPrice, " Volume: ", volume);
      
      // Calculate break-even level (1R from entry)
      breakEvenLevel = entryPrice + stopLoss;
      breakEvenSet = false;
      trailingStopActive = false;
      lastTradeDate = TimeCurrent();
      
      SendNotificationMessage("BUY signal triggered! Entry: " + DoubleToString(entryPrice, 2) + 
                              " | SL: " + DoubleToString(slPrice, 2) + " | TP: " + DoubleToString(tpPrice, 2));
   }
   else
   {
      Print("Failed to place BUY order. Error: ", GetLastError());
   }
}

//+------------------------------------------------------------------+
//| Open sell position with proper risk management                   |
//+------------------------------------------------------------------+
void OpenSellPosition(double atr, double entryPrice)
{
   // Calculate stop loss and take profit
   double stopLoss = atr * ATRMultiplier;
   double takeProfit = stopLoss * TPMultiplier;
   double slPrice = entryPrice + stopLoss;
   double tpPrice = entryPrice - takeProfit;
   
   // Validate prices
   if(slPrice <= 0 || tpPrice <= 0)
      return;
   
   // Calculate volume based on risk
   double volume = CalculateVolume(stopLoss);
   
   if(volume <= 0)
   {
      Print("Invalid volume calculated: ", volume);
      return;
   }
   
   // Normalize volume to symbol specifications
   volume = NormalizeVolume(volume);
   
   // Place order
   if(trade.Sell(volume, Symbol(), entryPrice, slPrice, tpPrice, "Range Break Sell"))
   {
      Print("SELL order placed - Entry: ", entryPrice, " SL: ", slPrice, " TP: ", tpPrice, " Volume: ", volume);
      
      // Calculate break-even level (1R from entry)
      breakEvenLevel = entryPrice - stopLoss;
      breakEvenSet = false;
      trailingStopActive = false;
      lastTradeDate = TimeCurrent();
      
      SendNotificationMessage("SELL signal triggered! Entry: " + DoubleToString(entryPrice, 2) + 
                              " | SL: " + DoubleToString(slPrice, 2) + " | TP: " + DoubleToString(tpPrice, 2));
   }
   else
   {
      Print("Failed to place SELL order. Error: ", GetLastError());
   }
}

//+------------------------------------------------------------------+
//| Manage open positions (break-even and trailing stop)             |
//+------------------------------------------------------------------+
void ManageOpenPositions()
{
   // Check if there's an open position
   if(!positionInfo.SelectByMagic(Symbol(), trade.RequestMagic()))
      return;
   
   double currentPrice = SymbolInfoDouble(Symbol(), (positionInfo.PositionType() == POSITION_TYPE_BUY) ? SYMBOL_BID : SYMBOL_ASK);
   double positionOpenPrice = positionInfo.PriceOpen();
   double positionStopLoss = positionInfo.StopLoss();
   double positionTakeProfit = positionInfo.TakeProfit();
   ENUM_POSITION_TYPE posType = positionInfo.PositionType();
   
   double atr = GetATR();
   double oneR = atr * ATRMultiplier;  // Risk amount (1R)
   
   // BUY POSITION management
   if(posType == POSITION_TYPE_BUY)
   {
      // Set break-even at 1R
      if(!breakEvenSet && currentPrice >= positionOpenPrice + oneR)
      {
         if(trade.ModifyPosition(Symbol(), positionOpenPrice, positionTakeProfit))
         {
            Print("Break-even set for BUY position");
            breakEvenSet = true;
            trailingStopActive = true;
            SendNotificationMessage("Break-even activated for BUY position!");
         }
      }
      
      // Trailing stop after break-even
      if(trailingStopActive && currentPrice > positionOpenPrice)
      {
         double newSL = currentPrice - TrailingStopPoints * Point();
         if(newSL > positionStopLoss)
         {
            if(trade.ModifyPosition(Symbol(), newSL, positionTakeProfit))
            {
               Print("Trailing stop updated: ", newSL);
            }
         }
      }
   }
   
   // SELL POSITION management
   if(posType == POSITION_TYPE_SELL)
   {
      // Set break-even at 1R
      if(!breakEvenSet && currentPrice <= positionOpenPrice - oneR)
      {
         if(trade.ModifyPosition(Symbol(), positionOpenPrice, positionTakeProfit))
         {
            Print("Break-even set for SELL position");
            breakEvenSet = true;
            trailingStopActive = true;
            SendNotificationMessage("Break-even activated for SELL position!");
         }
      }
      
      // Trailing stop after break-even
      if(trailingStopActive && currentPrice < positionOpenPrice)
      {
         double newSL = currentPrice + TrailingStopPoints * Point();
         if(newSL < positionStopLoss)
         {
            if(trade.ModifyPosition(Symbol(), newSL, positionTakeProfit))
            {
               Print("Trailing stop updated: ", newSL);
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Record pre-session range (18:00-19:00 IST)                       |
//+------------------------------------------------------------------+
void RecordPreSessionRange()
{
   if(preSessionRecorded)
      return;  // Already recorded for this session
   
   // Get high and low from price history
   MqlRates rates[];
   int copied = CopyRates(Symbol(), PERIOD_M5, 0, 12, rates);  // Last 60 minutes (12 x 5min bars)
   
   if(copied > 0)
   {
      double high = rates[0].high;
      double low = rates[0].low;
      
      for(int i = 0; i < copied; i++)
      {
         if(rates[i].high > high) high = rates[i].high;
         if(rates[i].low < low) low = rates[i].low;
      }
      
      preSessionHigh = high;
      preSessionLow = low;
      preSessionRecorded = true;
      
      Print("Pre-session range recorded - High: ", preSessionHigh, " Low: ", preSessionLow);
   }
}

//+------------------------------------------------------------------+
//| Calculate volume based on risk management                         |
//+------------------------------------------------------------------+
double CalculateVolume(double stopLossPoints)
{
   if(stopLossPoints <= 0)
      return 0;
   
   // Get account balance
   double accountBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   
   // Calculate risk in currency
   double riskAmount = accountBalance * (RiskPercent / 100);
   
   // Get symbol's tick size and tick value
   double tickSize = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_VALUE);
   
   if(tickSize <= 0 || tickValue <= 0)
      return 0;
   
   // Calculate volume
   double volume = riskAmount / (stopLossPoints * tickSize * tickValue);
   
   return volume;
}

//+------------------------------------------------------------------+
//| Normalize volume to symbol specifications                         |
//+------------------------------------------------------------------+
double NormalizeVolume(double volume)
{
   double minVolume = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MIN);
   double maxVolume = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MAX);
   double volumeStep = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_STEP);
   
   if(volume < minVolume)
      volume = minVolume;
   
   if(volume > maxVolume)
      volume = maxVolume;
   
   volume = NormalizeDouble(volume / volumeStep, 0) * volumeStep;
   
   return volume;
}

//+------------------------------------------------------------------+
//| Get current ATR value                                             |
//+------------------------------------------------------------------+
double GetATR()
{
   int handle = iATR(Symbol(), PERIOD_M5, ATRPeriod);
   
   if(handle == INVALID_HANDLE)
   {
      Print("Error creating ATR handle");
      return 0;
   }
   
   double buffer[];
   ArraySetAsSeries(buffer, true);
   
   if(CopyBuffer(handle, 0, 0, 1, buffer) < 1)
   {
      Print("Error copying ATR buffer");
      IndicatorRelease(handle);
      return 0;
   }
   
   IndicatorRelease(handle);
   return buffer[0];
}

//+------------------------------------------------------------------+
//| Get EMA value                                                     |
//+------------------------------------------------------------------+
double GetEMA(int period)
{
   int handle = iMA(Symbol(), PERIOD_M5, period, 0, MODE_EMA, PRICE_CLOSE);
   
   if(handle == INVALID_HANDLE)
   {
      Print("Error creating EMA handle for period: ", period);
      return 0;
   }
   
   double buffer[];
   ArraySetAsSeries(buffer, true);
   
   if(CopyBuffer(handle, 0, 0, 1, buffer) < 1)
   {
      Print("Error copying EMA buffer");
      IndicatorRelease(handle);
      return 0;
   }
   
   IndicatorRelease(handle);
   return buffer[0];
}

//+------------------------------------------------------------------+
//| Get current spread in points                                      |
//+------------------------------------------------------------------+
int GetCurrentSpread()
{
   double bid = SymbolInfoDouble(Symbol(), SYMBOL_BID);
   double ask = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
   double point = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
   
   if(point <= 0)
      return 0;
   
   int spread = (int)((ask - bid) / point);
   return spread;
}

//+------------------------------------------------------------------+
//| Check if current time is pre-session time (18:00-19:00 IST)      |
//+------------------------------------------------------------------+
bool IsPreSessionTime()
{
   MqlDateTime dateTime;
   TimeToStruct(TimeCurrent(), dateTime);
   
   // Convert current time to IST (GMT+5:30)
   int istHour = (dateTime.hour + 5) % 24;
   int istMin = dateTime.min + 30;
   
   if(istMin >= 60)
   {
      istHour = (istHour + 1) % 24;
      istMin -= 60;
   }
   
   // Convert time strings to hours and minutes
   int preStartPos = StringFind(PreSessionStart, ":");
   int preStartHour = (int)StringToInteger(StringSubstr(PreSessionStart, 0, preStartPos));
   int preStartMin = (int)StringToInteger(StringSubstr(PreSessionStart, preStartPos + 1));
   
   int preEndPos = StringFind(PreSessionEnd, ":");
   int preEndHour = (int)StringToInteger(StringSubstr(PreSessionEnd, 0, preEndPos));
   int preEndMin = (int)StringToInteger(StringSubstr(PreSessionEnd, preEndPos + 1));
   
   int currentTime = istHour * 60 + istMin;
   int startTime = preStartHour * 60 + preStartMin;
   int endTime = preEndHour * 60 + preEndMin;
   
   return (currentTime >= startTime && currentTime < endTime);
}

//+------------------------------------------------------------------+
//| Check if current time is trading session time (19:00-23:00 IST)  |
//+------------------------------------------------------------------+
bool IsTradingSessionTime()
{
   MqlDateTime dateTime;
   TimeToStruct(TimeCurrent(), dateTime);
   
   // Convert current time to IST (GMT+5:30)
   int istHour = (dateTime.hour + 5) % 24;
   int istMin = dateTime.min + 30;
   
   if(istMin >= 60)
   {
      istHour = (istHour + 1) % 24;
      istMin -= 60;
   }
   
   // Convert time strings to hours and minutes
   int tradStartPos = StringFind(TradingSessionStart, ":");
   int tradStartHour = (int)StringToInteger(StringSubstr(TradingSessionStart, 0, tradStartPos));
   int tradStartMin = (int)StringToInteger(StringSubstr(TradingSessionStart, tradStartPos + 1));
   
   int tradEndPos = StringFind(TradingSessionEnd, ":");
   int tradEndHour = (int)StringToInteger(StringSubstr(TradingSessionEnd, 0, tradEndPos));
   int tradEndMin = (int)StringToInteger(StringSubstr(TradingSessionEnd, tradEndPos + 1));
   
   int currentTime = istHour * 60 + istMin;
   int startTime = tradStartHour * 60 + tradStartMin;
   int endTime = tradEndHour * 60 + tradEndMin;
   
   return (currentTime >= startTime && currentTime < endTime);
}

//+------------------------------------------------------------------+
//| Count trades executed today                                       |
//+------------------------------------------------------------------+
int CountTradesToday()
{
   int count = 0;
   int total = HistoryDealsTotal();
   
   // Count closed deals today with this EA's magic number
   for(int i = total - 1; i >= 0; i--)
   {
      ulong dealTicket = HistoryDealGetTicket(i);
      
      if(dealTicket == 0)
         continue;
      
      if(HistoryDealGetInteger(dealTicket, DEAL_MAGIC) == trade.RequestMagic() &&
         HistoryDealGetString(dealTicket, DEAL_SYMBOL) == Symbol())
      {
         datetime dealTime = (datetime)HistoryDealGetInteger(dealTicket, DEAL_TIME);
         
         // Check if deal is from today
         MqlDateTime dealDateTime;
         TimeToStruct(dealTime, dealDateTime);
         
         MqlDateTime currentDateTime;
         TimeToStruct(TimeCurrent(), currentDateTime);
         
         if(dealDateTime.year == currentDateTime.year &&
            dealDateTime.mon == currentDateTime.mon &&
            dealDateTime.day == currentDateTime.day)
         {
            count++;
         }
      }
   }
   
   return count;
}

//+------------------------------------------------------------------+
//| Calculate daily P&L                                               |
//+------------------------------------------------------------------+
void CalculateDailyPnL()
{
   dailyProfitLoss = 0;
   
   // Check closed deals today
   int total = HistoryDealsTotal();
   
   for(int i = total - 1; i >= 0; i--)
   {
      ulong dealTicket = HistoryDealGetTicket(i);
      
      if(dealTicket == 0)
         continue;
      
      // Check if deal belongs to this EA and is from today
      if(HistoryDealGetInteger(dealTicket, DEAL_MAGIC) == trade.RequestMagic() &&
         HistoryDealGetString(dealTicket, DEAL_SYMBOL) == Symbol())
      {
         datetime dealTime = (datetime)HistoryDealGetInteger(dealTicket, DEAL_TIME);
         
         // Check if deal is from today
         MqlDateTime dealDateTime;
         TimeToStruct(dealTime, dealDateTime);
         
         MqlDateTime currentDateTime;
         TimeToStruct(TimeCurrent(), currentDateTime);
         
         if(dealDateTime.year == currentDateTime.year &&
            dealDateTime.mon == currentDateTime.mon &&
            dealDateTime.day == currentDateTime.day)
         {
            double profit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
            double commission = HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
            double swap = HistoryDealGetDouble(dealTicket, DEAL_SWAP);
            
            dailyProfitLoss += (profit + commission + swap);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Check if new day and reset daily variables                        |
//+------------------------------------------------------------------+
void CheckNewDay()
{
   MqlDateTime lastDateTime;
   TimeToStruct(lastTradeDate, lastDateTime);
   
   MqlDateTime currentDateTime;
   TimeToStruct(TimeCurrent(), currentDateTime);
   
   if(lastDateTime.year != currentDateTime.year ||
      lastDateTime.mon != currentDateTime.mon ||
      lastDateTime.day != currentDateTime.day)
   {
      preSessionRecorded = false;
      preSessionHigh = 0;
      preSessionLow = 0;
      dailyProfitLoss = 0;
      lastTradeDate = TimeCurrent();
      
      Print("New day detected - Pre-session range reset");
   }
}

//+------------------------------------------------------------------+
//| Update indicator values for dashboard                             |
//+------------------------------------------------------------------+
void UpdateIndicatorValues()
{
   currentATR = GetATR();
   currentEMA50 = GetEMA(EMA50Period);
   currentEMA200 = GetEMA(EMA200Period);
   currentSpread = GetCurrentSpread();
}

//+------------------------------------------------------------------+
//| Update dashboard with current information                         |
//+------------------------------------------------------------------+
void UpdateDashboard()
{
   // Create dashboard string
   string dashboard = "";
   
   dashboard += "═══════════════════════════════════════\n";
   dashboard += "     XAUUSD M5 RANGE BREAK EA\n";
   dashboard += "═══════════════════════════════════════\n\n";
   
   // Time information
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   dashboard += "Time (GMT): " + IntegerToString(dt.hour) + ":" + 
               (dt.min < 10 ? "0" : "") + IntegerToString(dt.min) + "\n";
   
   // Price information
   double bid = SymbolInfoDouble(Symbol(), SYMBOL_BID);
   double ask = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
   dashboard += "Bid/Ask: " + DoubleToString(bid, 2) + " / " + DoubleToString(ask, 2) + "\n\n";
   
   // Pre-session range
   dashboard += "PRE-SESSION RANGE (18:00-19:00 IST):\n";
   dashboard += "  High: " + DoubleToString(preSessionHigh, 2) + "\n";
   dashboard += "  Low:  " + DoubleToString(preSessionLow, 2) + "\n";
   dashboard += "  Recorded: " + (preSessionRecorded ? "YES" : "NO") + "\n\n";
   
   // Trend information
   string trend = (currentEMA50 > currentEMA200) ? "BULLISH" : "BEARISH";
   dashboard += "TREND FILTER:\n";
   dashboard += "  EMA50: " + DoubleToString(currentEMA50, 2) + "\n";
   dashboard += "  EMA200: " + DoubleToString(currentEMA200, 2) + "\n";
   dashboard += "  Status: " + trend + "\n\n";
   
   // ATR information
   dashboard += "ATR & VOLATILITY:\n";
   dashboard += "  ATR(14): " + DoubleToString(currentATR, 2) + "\n";
   dashboard += "  SL Distance: " + DoubleToString(currentATR * ATRMultiplier, 2) + " (ATR×" + DoubleToString(ATRMultiplier, 1) + ")\n";
   dashboard += "  TP Distance: " + DoubleToString(currentATR * ATRMultiplier * TPMultiplier, 2) + "\n\n";
   
   // Spread information
   dashboard += "SPREAD FILTER:\n";
   dashboard += "  Current: " + IntegerToString(currentSpread) + " points\n";
   dashboard += "  Max Allowed: " + DoubleToString(MaxSpreadPoints, 0) + " points\n";
   dashboard += "  Status: " + (currentSpread <= MaxSpreadPoints ? "ACCEPTABLE" : "TOO HIGH") + "\n\n";
   
   // Daily P&L
   dashboard += "DAILY P&L:\n";
   dashboard += "  Daily P/L: $" + DoubleToString(dailyProfitLoss, 2) + "\n";
   dashboard += "  Loss Limit: -$" + DoubleToString(AccountBalance() * DailyLossLimit / 100, 2) + "\n";
   dashboard += "  Profit Target: +$" + DoubleToString(AccountBalance() * DailyProfitTarget / 100, 2) + "\n";
   dashboard += "  Trades Today: " + IntegerToString(CountTradesToday()) + " / " + IntegerToString(MaxTradesPerDay) + "\n\n";
   
   // Position information
   if(positionInfo.SelectByMagic(Symbol(), trade.RequestMagic()))
   {
      dashboard += "OPEN POSITION:\n";
      dashboard += "  Type: " + (positionInfo.PositionType() == POSITION_TYPE_BUY ? "BUY" : "SELL") + "\n";
      dashboard += "  Entry: " + DoubleToString(positionInfo.PriceOpen(), 2) + "\n";
      dashboard += "  Current P/L: $" + DoubleToString(positionInfo.Profit(), 2) + "\n";
      dashboard += "  SL: " + DoubleToString(positionInfo.StopLoss(), 2) + "\n";
      dashboard += "  TP: " + DoubleToString(positionInfo.TakeProfit(), 2) + "\n";
   }
   else
   {
      dashboard += "POSITION: NONE\n";
   }
   
   dashboard += "\n═══════════════════════════════════════\n";
   
   // Display on chart
   Comment(dashboard);
}

//+------------------------------------------------------------------+
//| Send notification (push or alert) - FIXED: Renamed to avoid recursion|
//+------------------------------------------------------------------+
void SendNotificationMessage(string message)
{
   if(EnableNotifications)
   {
      SendNotification(message);
   }
   
   if(EnableAlerts)
   {
      Alert(message);
   }
   
   Print(message);
}

//+------------------------------------------------------------------+
//| End of Expert Advisor                                             |
//+------------------------------------------------------------------+
