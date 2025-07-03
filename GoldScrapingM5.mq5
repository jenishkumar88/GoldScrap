#property copyright "Copyright 2025, Expert"
#property version   "1.00"
#property strict

//--- Input Parameters
enum ENUM_ACCOUNT_TYPE
  {
   mt5_mini_real_vc,
   mt5_classic_real_vc,
   mt5_raw_real_vc,
   mt5_zero_real_vc
  };

input group "=== GENERAL SETTINGS ==="
input ENUM_ACCOUNT_TYPE AccountType = mt5_raw_real_vc; // Account Type for Exness API
input double   LotSize = 0.02;                  // Fixed lot size
input int      MagicNumber = 85462796;            // Magic number
input int      MaxOpenTrades = 6;               // Maximum open trades
input double MaxSLAmount = 1.5; // Maximum stop loss per trade in account currency

input group "=== RISK MANAGEMENT ==="
input double   MaxSpread = 40.0;                // Maximum spread in points
input int OrderDelaySeconds = 60; // Minimum seconds to wait before placing next order


input group "=== AUTO CLOSE SETTINGS ==="
input bool     EnableAutoClose = true;          // Enable automatic order closing
input int      AutoCloseMinutes = 40;           // Minutes after which to auto-close orders (0 = disabled)

input group "=== DAILY LIMITS ==="
input bool     StopOnDailyLimit = true;         // Stop EA when daily limit reached   
input double   MaxDailyLoss = 70.0;            // Maximum daily loss in account currency
input double TrailingStopDistance = 0.5; // Distance in account currency to keep SL behind current profit
input double TrailingProfitDistance = 0.80; // Amount (in account currency) to move TP further
input double TrailingProfitTrigger = 0.40; // Amount (in account currency) to move TP trigger

//--- Global Variables
double dailyStartBalance;
datetime lastTradeTime;
int totalTradesToday;
double dailyProfit;
bool tradingEnabled = true;
datetime lastCheckTime;
string usedMagicNumbers[];
int magicCount = 0;

double commissionOrSpreadPer001Lot = 0; // Commission for 0.01 lot, fetched from Exness API
bool isCommission = true;

int lastDayKey = -1; // Composite key for daily tracking (YYYYMMDD)


//+------------------------------------------------------------------+
//| Fetch commission from Exness API                                 |
//+------------------------------------------------------------------+
void FetchCommissionFromExness()
{    
      
    string url = "https://www.exness.com/pwapi/";
    string headers = "Content-Type: application/json\r\nUser-Agent: PostmanRuntime/7.44.1\r\n";
    string accountTypeStr = EnumToString(AccountType);
    string requestBody =
        "{\"operationName\":\"Calculate\",\"variables\":{\"input\":{\"currency\":\"" + AccountInfoString(ACCOUNT_CURRENCY) + "\",\"leverage\":" + IntegerToString((int)AccountInfoInteger(ACCOUNT_LEVERAGE)) + ",\"lot\":0.01,\"account_type\":\"" + accountTypeStr + "\",\"instrument\":\"" + _Symbol + "\"}},\"query\":\"mutation Calculate($input: CalculationInput!) {\\n  calculate(input: $input) {\\n    currency\\n    margin\\n    pip_value\\n    swap_long\\n    swap_short\\n    spread\\n    commission\\n    __typename\\n  }\\n}\"}";
    char post[];
     int len = StringLen(requestBody);
    ArrayResize(post, len);
    StringToCharArray(requestBody, post, 0, len);
    char result[];
    string cookie = "";
    string headersOut = "";
    int timeout = 10000;
    int res = WebRequest("POST", url, headers, timeout, post, result, headersOut);
    if(res == 200)
    {
        string response = CharArrayToString(result);     
        int pos = StringFind(response,accountTypeStr == mt5_mini_real_vc || accountTypeStr ==  mt5_classic_real_vc ?  "\"spread\":" :  "\"commission\":");
        if(pos >= 0)
        {
            int start = pos + StringLen(accountTypeStr == mt5_mini_real_vc || accountTypeStr ==  mt5_classic_real_vc ?  "\"spread\":" :  "\"commission\":");
            int end = StringFind(response, ",", start);
            if(end < 0) end = StringFind(response, "}", start);
            string commissionStr = StringSubstr(response, start, end - start);              
            double tempCommission =  StringToDouble(commissionStr);  
            commissionOrSpreadPer001Lot = tempCommission*2; 
        } 
    }
    else
    {    
        Print("Gold Scraping :- Failed to fetch commission from Exness API. WebRequest result: ", res, CharArrayToString(result));
    }
}


//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
    // Initialize daily tracking
    dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
    dailyProfit = 0;
    totalTradesToday = 0;
    lastTradeTime = 0;
    lastCheckTime = TimeCurrent();
      
    EventSetTimer(1); // Set timer for 1 second intervals    
    Print("Gold Scalping EA initialized successfully");
    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    EventKillTimer(); // Kill the timer   
    Print("Gold Scalping EA deinitialized");
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
    static datetime lastBarTime = 0;
    datetime currentBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);
    
    if(currentBarTime == lastBarTime)
        return;
    lastBarTime = currentBarTime;
    
    MqlDateTime dt;
    TimeToStruct(TimeCurrent() + 19800, dt); // Convert to GMT+5:30 and then to struct

    string ampm;
    int hour = dt.hour;

    if (hour >= 12) {
        ampm = " PM";
        if (hour > 12) hour -= 12;
    } else {
        ampm = " AM";
        if (hour == 0) hour = 12; // Midnight 00:XX becomes 12:XX AM
    }

    string formattedDateTime = StringFormat("%04d.%02d.%02d %02d:%02d:%02d%s", dt.year, dt.mon, dt.day, hour, dt.min, dt.sec, ampm);
    Print("Gold Scalping EA  === NEW BAR TICK === Current time: ", formattedDateTime);

    
    if(AccountType == mt5_mini_real_vc || AccountType ==  mt5_classic_real_vc){
     isCommission = false; 
    }else{
      isCommission = true; 
    static datetime lastCommissionFetch = 0;
    if(TimeCurrent() - lastCommissionFetch > 60) // every 60 seconds
    {
        FetchCommissionFromExness();
        lastCommissionFetch = TimeCurrent();
    }
    } 
}

//+------------------------------------------------------------------+
//| On Timer Event Handler                                           |
//+------------------------------------------------------------------+
void OnTimer()
{      
    // Update daily tracking
    UpdateDailyTracking();
    
    // Check daily limits
    if(StopOnDailyLimit)
    {
        if(dailyProfit <= -MaxDailyLoss )
        {
            tradingEnabled = false;
            Print("Gold Scalping EA Daily limit reached. Trading stopped. Max Loss: ", MaxDailyLoss);
            return;
        }
    }
 
    // Check basic filters
    if(!CheckBasicFilters())
    {
        Print("Gold Scalping EA Basic filters failed");
        return;
    }
    
    // Check for auto-close based on time
    if(EnableAutoClose && AutoCloseMinutes > 0)
    {
        CheckAutoCloseOrders();
    }

    // Check for new entry conditions
    if(IsBelowMaxOpenTrades())
    {
        if(TimeCurrent() - lastTradeTime >= OrderDelaySeconds)
        {
            CheckEntryConditions();
        }
        
    }

    // Manage open positions
    ManagePositions();

    // Check emergency conditions
    CheckEmergencyConditions();
}

//+------------------------------------------------------------------+
//| Check and auto-close orders based on time                       |
//+------------------------------------------------------------------+
void CheckAutoCloseOrders()
{
    datetime currentTime = TimeCurrent();
    int autoCloseSeconds = AutoCloseMinutes * 60; // Convert minutes to seconds
    
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == MagicNumber)
        {
            ulong ticket = PositionGetInteger(POSITION_TICKET);
            datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
            
            // Check if the position has been open for longer than the specified time
            if(currentTime - openTime >= autoCloseSeconds)
            {
                double currentProfit = PositionGetDouble(POSITION_PROFIT);
                string comment = PositionGetString(POSITION_COMMENT);
                
                ClosePosition(ticket, StringFormat("Auto-Close after %d minutes (Profit: %.2f)", 
                            AutoCloseMinutes, currentProfit));
               
            }
        }
    }
}


//+------------------------------------------------------------------+
//| Update daily tracking                                            |
//+------------------------------------------------------------------+
void UpdateDailyTracking()
{
    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);
    int todayKey = dt.year * 10000 + dt.mon * 100 + dt.day;
    if(todayKey != lastDayKey)
    {
        // New day - reset counters
        dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
        dailyProfit = 0;
        totalTradesToday = 0;
        tradingEnabled = true;
        lastDayKey = todayKey;
    }
    else
    {
        // Calculate daily profit
        dailyProfit = AccountInfoDouble(ACCOUNT_BALANCE) - dailyStartBalance;
    }
}


//+------------------------------------------------------------------+
//| Check basic filters                                              |
//+------------------------------------------------------------------+
bool CheckBasicFilters()
{
    // Check spread
    double currentSpread = (double)(SymbolInfoInteger(_Symbol, SYMBOL_SPREAD));

    if(currentSpread > MaxSpread)
    {
        Print("Gold Scalping EA FILTER FAILED: Spread too high");
        return false;
    }
           
    return true;
}


//+------------------------------------------------------------------+
//| Helper: Check if trading is allowed (daily loss, enable flag)    |
//+------------------------------------------------------------------+
bool IsTradingAllowed() {
    if(!tradingEnabled) return false;
    if(StopOnDailyLimit && dailyProfit <= -MaxDailyLoss) return false;
    return true;
}

//+------------------------------------------------------------------+
//| Helper: Check if open trades are below max allowed              |
//+------------------------------------------------------------------+
bool IsBelowMaxOpenTrades() {
    return CountOpenTrades() < MaxOpenTrades;
}

//+------------------------------------------------------------------+
//| Open trade function                                              |
//+------------------------------------------------------------------+
bool OpenTrade(ENUM_ORDER_TYPE orderType, double stopLoss, double takeProfit, string comment)
{
    if(!IsTradingAllowed()) {
        Print("Gold Scalping EA: Trading not allowed (daily loss or disabled)");
        return false;
    }
    if(!IsBelowMaxOpenTrades()) {
        Print("Gold Scalping EA: Max open trades reached");
        return false;
    }
        
    double lotSize = LotSize;
   
    // Normalize lot size
    double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   
    lotSize = MathMax(minLot, MathMin(maxLot, NormalizeDouble(lotSize / lotStep, 0) * lotStep));
   
    // Get current prices
    double askPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double bidPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);

    
    MqlTradeRequest request = {};
    MqlTradeResult result = {};
    
    request.action = TRADE_ACTION_DEAL;
    request.symbol = _Symbol;
    request.volume = lotSize;
    request.type = orderType;
    request.price = (orderType == ORDER_TYPE_BUY) ? askPrice : bidPrice;
    request.sl = stopLoss;
    request.tp = takeProfit;
    request.magic = MagicNumber;
    request.comment = comment;
    request.type_filling = ORDER_FILLING_IOC;
       
    // Check if trading is allowed
    if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
    {
        Print("Gold Scalping EA ERROR: Trading not allowed in terminal");
        return false;
    }
    
    if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
    {
        Print("Gold Scalping EA ERROR: Automated trading not allowed for this EA");
        return false;
    }
    
    if(!AccountInfoInteger(ACCOUNT_TRADE_EXPERT))
    {
        Print("Gold Scalping EA ERROR: Expert trading not allowed for this account");
        return false;
    }
    
    if(!SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE))
    {
        Print("Gold Scalping EAERROR: Trading not allowed for this symbol");
        return false;
    }
    

    bool orderResult = OrderSend(request, result);
   
    if(orderResult)
    {
       Print("Gold Scalping EA === Opened TRADE === Order Type :- ", orderType == 0 ? "Buy  " : "Sell  ","Current Price:- ",orderType == ORDER_TYPE_BUY ? askPrice : bidPrice , "  SL:-  " , stopLoss, "   " , "TP:-  " ,  takeProfit, " ", comment);
        totalTradesToday++;
        return true;
    }
    else
    {
        Print("Gold Scalping EA OrderSend FAILED!  Error code: ", result.retcode,"Error description: ", result.comment, "  Order Type :- ", orderType == 0 ? "Buy  " : "Sell  ","Current Price:- ",orderType == ORDER_TYPE_BUY ? askPrice : bidPrice , "  SL:-  " , stopLoss, "   " , "TP:-  " ,  takeProfit, " ", comment);
        // Print additional error information
        switch(result.retcode)
        {
            case TRADE_RETCODE_REQUOTE:
                Print("Requote error - price changed");
                break;
            case TRADE_RETCODE_REJECT:
                Print("Request rejected");
                break;
            case TRADE_RETCODE_MARKET_CLOSED:
                Print("Market is closed");
                break;
            case TRADE_RETCODE_PLACED:
                Print("Order placed successfully");
                break;
            case TRADE_RETCODE_DONE:
                Print("Request completed");
                break;
            case TRADE_RETCODE_DONE_PARTIAL:
                Print("Request completed partially");
                break;
            case TRADE_RETCODE_ERROR:
                Print("Common error");
                break;
            case TRADE_RETCODE_TIMEOUT:
                Print("Request timeout");
                break;
            case TRADE_RETCODE_INVALID:
                Print("Invalid request");
                break;
            case TRADE_RETCODE_INVALID_VOLUME:
                Print("Invalid volume");
                break;
            case TRADE_RETCODE_INVALID_PRICE:
                Print("Invalid price");
                break;
            case TRADE_RETCODE_INVALID_STOPS:
                Print("Invalid stops");
                break;
            case TRADE_RETCODE_TRADE_DISABLED:
                Print("Trade disabled");
                break;
            case TRADE_RETCODE_NO_MONEY:
                Print("No money");
                break;
            case TRADE_RETCODE_PRICE_CHANGED:
                Print("Price changed");
                break;
            case TRADE_RETCODE_PRICE_OFF:
                Print("Off quotes");
                break;
            case TRADE_RETCODE_INVALID_EXPIRATION:
                Print("Invalid expiration");
                break;
            case TRADE_RETCODE_ORDER_CHANGED:
                Print("Order changed");
                break;
            case TRADE_RETCODE_TOO_MANY_REQUESTS:
                Print("Too many requests");
                break;
            case TRADE_RETCODE_NO_CHANGES:
                Print("No changes");
                break;
            case TRADE_RETCODE_SERVER_DISABLES_AT:
                Print("Server disables AT");
                break;
            case TRADE_RETCODE_CLIENT_DISABLES_AT:
                Print("Client disables AT");
                break;
            case TRADE_RETCODE_LOCKED:
                Print("Locked");
                break;
            case TRADE_RETCODE_FROZEN:
                Print("Frozen");
                break;
            case TRADE_RETCODE_INVALID_FILL:
                Print("Invalid fill");
                break;
            case TRADE_RETCODE_CONNECTION:
                Print("Connection problem");
                break;
            case TRADE_RETCODE_ONLY_REAL:
                Print("Only real accounts");
                break;
            case TRADE_RETCODE_LIMIT_ORDERS:
                Print("Limit orders");
                break;
            case TRADE_RETCODE_LIMIT_VOLUME:
                Print("Limit volume");
                break;
            case TRADE_RETCODE_INVALID_ORDER:
                Print("Invalid order");
                break;
            case TRADE_RETCODE_POSITION_CLOSED:
                Print("Position closed");
                break;
            default:
                Print("Unknown error code: ", result.retcode);
                break;
        }
        return false;
    }
}

//+------------------------------------------------------------------+
//| Count open trades                                                |
//+------------------------------------------------------------------+
int CountOpenTrades()
{
    int count = 0;
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == MagicNumber)
        {
            count++;
        }
    }
    return count;
}

//+------------------------------------------------------------------+
//| Manage positions                                                 |
//+------------------------------------------------------------------+
void ManagePositions()
{
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == MagicNumber)
        {
            ulong ticket = PositionGetInteger(POSITION_TICKET);
            string comment = PositionGetString(POSITION_COMMENT);
            double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
            double close = SymbolInfoDouble(_Symbol, SYMBOL_BID);
            int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
            // Early exit for BB trades
            if(StringFind(comment, "BB Breakout") >= 0)
            {
                int bbPeriod = 20;
                double bbDeviation = 2.0;
                int shift = 1;
                int bbHandle = iBands(_Symbol, PERIOD_CURRENT, bbPeriod, 0, bbDeviation, PRICE_CLOSE);
                double upper[2], lower[2];
                if(CopyBuffer(bbHandle, 0, shift, 2, upper) > 0 && CopyBuffer(bbHandle, 2, shift, 2, lower) > 0)
                {
                    IndicatorRelease(bbHandle);
                    ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
                    double lastClose = iClose(_Symbol, PERIOD_CURRENT, shift);
                    // Exit if price closes back inside band
                    if(posType == POSITION_TYPE_BUY && lastClose < upper[1])
                        ClosePosition(ticket, "BB Early Exit");
                    if(posType == POSITION_TYPE_SELL && lastClose > lower[1])
                        ClosePosition(ticket, "BB Early Exit");
                }
                else { IndicatorRelease(bbHandle); }
            }
            ApplyTrailingStop(ticket);
            ApplyTrailingProfit(ticket);
        }
    }
}

// Helper to calculate commission for any lot size
double CalculateCommissionOrSpread(double lot) {
    if(isCommission){
    return commissionOrSpreadPer001Lot * (lot / 0.01) + 0.10 <= 0.20 ? 0.40 : commissionOrSpreadPer001Lot * (lot / 0.01) + 0.10 ;
    }else{
     return 0.25;
    }
}


//+------------------------------------------------------------------+
//| Apply trailing Stop              |
//+------------------------------------------------------------------+
void ApplyTrailingStop(ulong ticket)
{
    if(!PositionSelectByTicket(ticket)) return;
    string symbol = PositionGetString(POSITION_SYMBOL);
    int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
    double profitCurrency = PositionGetDouble(POSITION_PROFIT);
    double volume = PositionGetDouble(POSITION_VOLUME);
    double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
    ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
    double currentSL = PositionGetDouble(POSITION_SL);
    double currentTP = PositionGetDouble(POSITION_TP);
    double tick_value = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
    double tick_size = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
    double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
    double currentPrice = (posType == POSITION_TYPE_BUY) ? SymbolInfoDouble(symbol, SYMBOL_BID) : SymbolInfoDouble(symbol, SYMBOL_ASK);
  
    // Calculate commission for this specific position
    double commission = CalculateCommissionOrSpread(volume);
  
    // Only trigger if profit is above trigger
    if(profitCurrency >= commission) {
        double targetProfit = profitCurrency - TrailingStopDistance;
        // Calculate price difference needed to lock in targetProfit
        double requiredPriceDiff = (targetProfit * tick_size) / (volume * tick_value);
        double newSL = (posType == POSITION_TYPE_BUY) ? openPrice + requiredPriceDiff : openPrice - requiredPriceDiff;
        newSL = NormalizeDouble(newSL, digits);
        // For buy: SL must be above open, above current SL, below current price
        // For sell: SL must be below open, below current SL, above current price
        bool valid = false;
        if(posType == POSITION_TYPE_BUY) {
            valid = (newSL > openPrice) && ((newSL > currentSL) || (currentSL == 0)) && (newSL < currentPrice);
            if(valid && (currentPrice - newSL >= SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL) * point))
                ModifyPosition(ticket, newSL, currentTP);
        } else {
            valid = (newSL < openPrice) && ((newSL < currentSL) || (currentSL == 0)) && (newSL > currentPrice);
            if(valid && (newSL - currentPrice >= SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL) * point))
                ModifyPosition(ticket, newSL, currentTP);
        }
    }
}

//+------------------------------------------------------------------+
//| Apply trailing Take Profit based on USD profit difference       |
//+------------------------------------------------------------------+
void ApplyTrailingProfit(ulong ticket)
{
    if(!PositionSelectByTicket(ticket)) return;
    string symbol = PositionGetString(POSITION_SYMBOL);
    int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
    double profitCurrency = PositionGetDouble(POSITION_PROFIT);
    double volume = PositionGetDouble(POSITION_VOLUME);
    double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
    ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
    double currentSL = PositionGetDouble(POSITION_SL);
    double currentTP = PositionGetDouble(POSITION_TP);
    if(currentTP == 0) return;
    double tick_value = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
    double tick_size = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
    double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
    double currentPrice = (posType == POSITION_TYPE_BUY) ? SymbolInfoDouble(symbol, SYMBOL_BID) : SymbolInfoDouble(symbol, SYMBOL_ASK);
    double profitAtTP = (posType == POSITION_TYPE_BUY)
        ? ((currentTP - openPrice) * volume * tick_value) / tick_size
        : ((openPrice - currentTP) * volume * tick_value) / tick_size;
    double profitAtCurrentPrice = (posType == POSITION_TYPE_BUY)
        ? ((currentPrice - openPrice) * volume * tick_value) / tick_size
        : ((openPrice - currentPrice) * volume * tick_value) / tick_size;
    double profitDifference = profitAtTP - profitAtCurrentPrice;

    // Calculate commission for this specific position
    double commission = CalculateCommissionOrSpread(volume);

    if(profitDifference <= TrailingProfitTrigger && profitDifference > 0) {
        double newTPProfit = profitAtTP + TrailingProfitDistance;
        double requiredPriceDiff = (newTPProfit * tick_size) / (volume * tick_value);
        double newTP = (posType == POSITION_TYPE_BUY)
            ? openPrice + requiredPriceDiff
            : openPrice - requiredPriceDiff;
        newTP = NormalizeDouble(newTP, digits);
        bool valid = false;
        if(posType == POSITION_TYPE_BUY) {
            valid = (newTP > currentTP) && (newTP > currentPrice);
            if(valid && (newTP - currentPrice >= SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL) * point))
                ModifyPosition(ticket, currentSL, newTP);
        } else {
            valid = (newTP < currentTP) && (newTP < currentPrice);
            if(valid && (currentPrice - newTP >= SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL) * point))
                ModifyPosition(ticket, currentSL, newTP);
        }
    }
}

//+------------------------------------------------------------------+
//| Modify position                                                  |
//+------------------------------------------------------------------+
void ModifyPosition(ulong ticket, double stopLoss, double takeProfit)
{
    MqlTradeRequest request = {};
    MqlTradeResult result = {};
    
    request.action = TRADE_ACTION_SLTP;
    request.position = ticket;
    request.sl = stopLoss;
    request.tp = takeProfit;
    
    OrderSend(request, result);
}

//+------------------------------------------------------------------+
//| Close position                                                   |
//+------------------------------------------------------------------+
void ClosePosition(ulong ticket, string reason = "Early Exit")
{
    MqlTradeRequest request = {};
    MqlTradeResult result = {};
    if(!PositionSelectByTicket(ticket))
        return;
    request.action = TRADE_ACTION_DEAL;
    request.position = ticket;
    request.symbol = _Symbol;
    request.volume = PositionGetDouble(POSITION_VOLUME);
    request.type = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
    request.price = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    request.magic = MagicNumber;
    request.comment = reason;
    bool sent = OrderSend(request, result);
    if(sent){
        Print("Gold Scalping EA  Closed position #", ticket, " due to: ", reason);
    }else{
        Print("Gold Scalping EA Failed to close position #", ticket, " due to: ", reason, ". Error: ", result.retcode);}
}


//+------------------------------------------------------------------+
//| Emergency stop conditions                                        |
//+------------------------------------------------------------------+
void CheckEmergencyConditions()
{
    // Check for excessive spread
    double currentSpread = (double)(SymbolInfoInteger(_Symbol, SYMBOL_SPREAD));
    if(currentSpread > MaxSpread * 3)
    {
        tradingEnabled = false;
        Print("Gold Scalping EA Emergency stop: Excessive spread detected");
        // Close all positions due to emergency
        for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
            if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == MagicNumber)
            {
                ulong ticket = PositionGetInteger(POSITION_TICKET);
                ClosePosition(ticket, "Emergency: Excessive Spread");
            }
        }
    }
   
}


//+------------------------------------------------------------------+
//| On Trade Event Handler                                           |
//+------------------------------------------------------------------+
void OnTrade()
{
    // Update daily profit when trade is closed
    UpdateDailyTracking();

    // Check emergency conditions
    CheckEmergencyConditions();
}

//+------------------------------------------------------------------+
//| Enhanced CheckEntryConditions with Hybrid Scalping Strategies   |
//+------------------------------------------------------------------+
void CheckEntryConditions()
{
    if(!IsTradingAllowed()) return;
    if(!IsBelowMaxOpenTrades()) return;

    /*static datetime lastTradeBarTime = 0;
    datetime currentBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);
    if(currentBarTime == lastTradeBarTime) return;
    lastTradeBarTime = currentBarTime;*/

    if(BreakoutStrategySignal()) return;
    if(PullbackScalpingStrategySignal()) return;
    if(TrendMACrossStrategySignal()) return;
    if(BollingerBandBreakoutStrategySignal()) return;
    if(StochasticReversalStrategySignal()) return;
    if(VWAPBounceStrategySignal()) return;
    if(MeanReversionVWAPMAStrategySignal()) return;
    if(RangeChannelTradingStrategySignal()) return;
    if(HeikinAshiTrendFollowingStrategySignal()) return;
    if(ParabolicSARReversalStrategySignal()) return;
    if(CCIDivergenceStrategySignal()) return;
    if(OrderBlockBounceStrategySignal()) return;
}


// --- Breakout Scalping Strategy with Advanced Filters ---
bool BreakoutStrategySignal()
{
    int rangeBars = 10;
    double atrThreshold = 30 * SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    int shift = 1;
    double minATR = 10 * SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    double minEMADist = 10 * SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    double minBodyRatio = 0.5;
    int adxPeriod = 14;
    double minADX = 25.0;
    int consecutiveTradeLimit = 1;
    static int lastBuyBar_Breakout = -1000, lastSellBar_Breakout = -1000;
    int currentBar = Bars(_Symbol, PERIOD_CURRENT);

    // --- ATR filter ---
    int atrHandle = iATR(_Symbol, PERIOD_CURRENT, 14);
    double atrBuffer[2];
    if(CopyBuffer(atrHandle, 0, shift, 2, atrBuffer) <= 0) { IndicatorRelease(atrHandle); return false; }
    double atr = atrBuffer[0];
    IndicatorRelease(atrHandle);
    if(atr < minATR) return false;

    // --- ADX filter ---
    int adxHandle = iADX(_Symbol, PERIOD_CURRENT, adxPeriod);
    double adxBuffer[2];
    if(CopyBuffer(adxHandle, 0, shift, 2, adxBuffer) <= 0) { IndicatorRelease(adxHandle); return false; }
    double adx = adxBuffer[0];
    IndicatorRelease(adxHandle);
    if(adx < minADX) return false;

    // --- MACD confirmation ---
    int macdHandle = iMACD(_Symbol, PERIOD_CURRENT, 12, 26, 9, PRICE_CLOSE);
    double macdMain[1], macdSignal[1];
    if(CopyBuffer(macdHandle, 0, shift, 1, macdMain) <= 0) { IndicatorRelease(macdHandle); return false; }
    if(CopyBuffer(macdHandle, 1, shift, 1, macdSignal) <= 0) { IndicatorRelease(macdHandle); return false; }
    double macd = macdMain[0], macdSig = macdSignal[0];
    IndicatorRelease(macdHandle);

    // --- H1 Trend filter ---
    int emaFastH1 = iMA(_Symbol, PERIOD_H1, 20, 0, MODE_EMA, PRICE_CLOSE);
    int emaSlowH1 = iMA(_Symbol, PERIOD_H1, 50, 0, MODE_EMA, PRICE_CLOSE);
    double fastH1[1], slowH1[1];
    bool uptrend = false, downtrend = false;
    if(CopyBuffer(emaFastH1, 0, 0, 1, fastH1) > 0 && CopyBuffer(emaSlowH1, 0, 0, 1, slowH1) > 0) {
        uptrend = fastH1[0] > slowH1[0];
        downtrend = fastH1[0] < slowH1[0];
    }
    IndicatorRelease(emaFastH1); IndicatorRelease(emaSlowH1);

    // --- Range ---
    double rangeHigh = iHigh(_Symbol, PERIOD_CURRENT, 1);
    double rangeLow = iLow(_Symbol, PERIOD_CURRENT, 1);
    for(int i=2; i<=rangeBars; i++) {
        double h = iHigh(_Symbol, PERIOD_CURRENT, i);
        double l = iLow(_Symbol, PERIOD_CURRENT, i);
        if(h > rangeHigh) rangeHigh = h;
        if(l < rangeLow) rangeLow = l;
    }
    double bandWidth = rangeHigh - rangeLow;
    if(bandWidth < minEMADist) return false;

    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

    // --- RSI ---
    int rsiHandle = iRSI(_Symbol, PERIOD_CURRENT, 14, PRICE_CLOSE);
    double rsiBuffer[1];
    if(CopyBuffer(rsiHandle, 0, shift, 1, rsiBuffer) <= 0) { IndicatorRelease(rsiHandle); return false; }
    double rsi = rsiBuffer[0];
    IndicatorRelease(rsiHandle);

    // --- Candle quality ---
    double close = iClose(_Symbol, PERIOD_CURRENT, shift);
    double open = iOpen(_Symbol, PERIOD_CURRENT, shift);
    double high = iHigh(_Symbol, PERIOD_CURRENT, shift);
    double low = iLow(_Symbol, PERIOD_CURRENT, shift);
    double body = MathAbs(close - open);
    if(body < minBodyRatio * atr) return false;
    double candleRange = high - low;
    bool strongBull = (close >= high - 0.2 * candleRange);
    bool strongBear = (close <= low + 0.2 * candleRange);

    // Buy breakout
    if(ask > rangeHigh && rsi > 55 && uptrend && adx > minADX && macd > macdSig && strongBull && (currentBar - lastBuyBar_Breakout > consecutiveTradeLimit)) {
        double sl = rangeLow - 1.2 * atr;
        double entry = ask;
        double maxSLDist = GetMaxSLDistance(LotSize);
        if((entry - sl) > maxSLDist) sl = entry - maxSLDist;
        double tp = close + (close - sl) * 1.5;
        double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
        double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
        double expectedProfit = ((tp - entry) / tick_size) * tick_value * LotSize;
        double commission = CalculateCommissionOrSpread(LotSize);
        if(expectedProfit < commission) return false;
        if(OpenTrade(ORDER_TYPE_BUY, sl, tp, "Breakout Buy")) {
            lastBuyBar_Breakout = currentBar;
            return true;
        }
    }
    // Sell breakout
    if(bid < rangeLow && rsi < 45 && downtrend && adx > minADX && macd < macdSig && strongBear && (currentBar - lastSellBar_Breakout > consecutiveTradeLimit)) {
        double sl = rangeHigh + 1.2 * atr;
        double entry = bid;
        double maxSLDist = GetMaxSLDistance(LotSize);
        if((sl - entry) > maxSLDist) sl = entry + maxSLDist;
        double tp = close - (sl - close) * 1.5;
        double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
        double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
        double expectedProfit = ((entry - tp) / tick_size) * tick_value * LotSize;
        double commission = CalculateCommissionOrSpread(LotSize);
        if(expectedProfit < commission) return false;
        if(OpenTrade(ORDER_TYPE_SELL, sl, tp, "Breakout Sell")) {
            lastSellBar_Breakout = currentBar;
            return true;
        }
    }
    return false;
} 

// --- Pullback Scalping Strategy with Advanced Filters ---
bool PullbackScalpingStrategySignal()
{
    int emaFastPeriod = 20;
    int emaSlowPeriod = 50;
    int shift = 1; // previous closed bar
    double minATR = 10 * SymbolInfoDouble(_Symbol, SYMBOL_POINT); // Minimum ATR
    double minEMADist = 10 * SymbolInfoDouble(_Symbol, SYMBOL_POINT); // Minimum EMA distance
    double minBodyRatio = 0.5; // Candle body at least 50% of ATR
    int adxPeriod = 14;
    double minADX = 25.0;
    int consecutiveTradeLimit = 1;
    static int lastBuyBar = -1000, lastSellBar = -1000;
    int currentBar = Bars(_Symbol, PERIOD_CURRENT);

    // --- ATR filter ---
    int atrHandle = iATR(_Symbol, PERIOD_CURRENT, 14);
    double atrBuffer[2];
    if(CopyBuffer(atrHandle, 0, shift, 2, atrBuffer) <= 0) { IndicatorRelease(atrHandle); return false; }
    double atr = atrBuffer[0];
    IndicatorRelease(atrHandle);
    if(atr < minATR) return false;

    // --- EMA handles ---
    int emaFastHandle = iMA(_Symbol, PERIOD_CURRENT, emaFastPeriod, 0, MODE_EMA, PRICE_CLOSE);
    int emaSlowHandle = iMA(_Symbol, PERIOD_CURRENT, emaSlowPeriod, 0, MODE_EMA, PRICE_CLOSE);
    double emaFast[2], emaSlow[2];
    if(CopyBuffer(emaFastHandle, 0, shift, 2, emaFast) <= 0) { IndicatorRelease(emaFastHandle); IndicatorRelease(emaSlowHandle); return false; }
    if(CopyBuffer(emaSlowHandle, 0, shift, 2, emaSlow) <= 0) { IndicatorRelease(emaFastHandle); IndicatorRelease(emaSlowHandle); return false; }
    IndicatorRelease(emaFastHandle);
    IndicatorRelease(emaSlowHandle);
    double prevEmaFast = emaFast[1];
    double prevEmaSlow = emaSlow[1];
    double currEmaFast = emaFast[0];
    double currEmaSlow = emaSlow[0];
    double emaDist = MathAbs(currEmaFast - currEmaSlow);
    if(emaDist < minEMADist) return false;

    // --- ADX filter ---
    int adxHandle = iADX(_Symbol, PERIOD_CURRENT, adxPeriod);
    double adxBuffer[2];
    if(CopyBuffer(adxHandle, 0, shift, 2, adxBuffer) <= 0) { IndicatorRelease(adxHandle); return false; }
    double adx = adxBuffer[0];
    IndicatorRelease(adxHandle);
    if(adx < minADX) return false;

    // --- MACD confirmation ---
    int macdHandle = iMACD(_Symbol, PERIOD_CURRENT, 12, 26, 9, PRICE_CLOSE);
    double macdMain[1], macdSignal[1];
    if(CopyBuffer(macdHandle, 0, shift, 1, macdMain) <= 0) { IndicatorRelease(macdHandle); return false; }
    if(CopyBuffer(macdHandle, 1, shift, 1, macdSignal) <= 0) { IndicatorRelease(macdHandle); return false; }
    double macd = macdMain[0], macdSig = macdSignal[0];
    IndicatorRelease(macdHandle);

    // --- H1 Trend filter ---
    int emaFastH1 = iMA(_Symbol, PERIOD_H1, 20, 0, MODE_EMA, PRICE_CLOSE);
    int emaSlowH1 = iMA(_Symbol, PERIOD_H1, 50, 0, MODE_EMA, PRICE_CLOSE);
    double fastH1[1], slowH1[1];
    bool uptrend = false, downtrend = false;
    if(CopyBuffer(emaFastH1, 0, 0, 1, fastH1) > 0 && CopyBuffer(emaSlowH1, 0, 0, 1, slowH1) > 0) {
        uptrend = fastH1[0] > slowH1[0];
        downtrend = fastH1[0] < slowH1[0];
    }
    IndicatorRelease(emaFastH1); IndicatorRelease(emaSlowH1);

    double close = iClose(_Symbol, PERIOD_CURRENT, shift);
    double open = iOpen(_Symbol, PERIOD_CURRENT, shift);
    double high = iHigh(_Symbol, PERIOD_CURRENT, shift);
    double low = iLow(_Symbol, PERIOD_CURRENT, shift);
    double body = MathAbs(close - open);
    if(body < minBodyRatio * atr) return false;
    double candleRange = high - low;
    bool strongBull = (close >= high - 0.2 * candleRange);
    bool strongBear = (close <= low + 0.2 * candleRange);
    double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

    // --- Uptrend: EMA20 > EMA50, H1 uptrend, ADX, MACD, candle quality ---
    if(prevEmaFast > prevEmaSlow && uptrend && adx > minADX && macd > macdSig && strongBull && (currentBar - lastBuyBar > consecutiveTradeLimit)) {
        if(close <= prevEmaFast + 2*point) {
            double sl = low - 1.2 * atr;
            double entry = close;
            double maxSLDist = GetMaxSLDistance(LotSize);
            if((entry - sl) > maxSLDist) sl = entry - maxSLDist;
            double tp = close + (close - sl) * 1.5;
            double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
            double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
            double expectedProfit = ((tp - entry) / tick_size) * tick_value * LotSize;
            double commission = CalculateCommissionOrSpread(LotSize);
            if(expectedProfit < commission) return false;
            OpenTrade(ORDER_TYPE_BUY, sl, tp, "Pullback PinBar Buy");
            lastBuyBar = currentBar;
            return true;
        }
    }
    // --- Downtrend: EMA20 < EMA50, H1 downtrend, ADX, MACD, candle quality ---
    if(prevEmaFast < prevEmaSlow && downtrend && adx > minADX && macd < macdSig && strongBear && (currentBar - lastSellBar > consecutiveTradeLimit)) {
        if(close >= prevEmaFast - 2*point) {
            double sl = high + 1.2 * atr;
            double entry = close;
            double maxSLDist = GetMaxSLDistance(LotSize);
            if((sl - entry) > maxSLDist) sl = entry + maxSLDist;
            double tp = close - (sl - close) * 1.5;
            double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
            double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
            double expectedProfit = ((entry - tp) / tick_size) * tick_value * LotSize;
            double commission = CalculateCommissionOrSpread(LotSize);
            if(expectedProfit < commission) return false;
            OpenTrade(ORDER_TYPE_SELL, sl, tp, "Pullback PinBar Sell");
            lastSellBar = currentBar;
            return true;
        }
    }
    return false;
} 

// --- Trend-Following MA Cross Strategy with Advanced Filters ---
bool TrendMACrossStrategySignal()
{
    int fastMAPeriod = 9, slowMAPeriod = 21, shift = 1;
    double minATR = 10 * SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    double minEMADist = 10 * SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    double minBodyRatio = 0.5;
    int adxPeriod = 14;
    double minADX = 25.0;
    int consecutiveTradeLimit = 1;
    static int lastBuyBar = -1000, lastSellBar = -1000;
    int currentBar = Bars(_Symbol, PERIOD_CURRENT);

    // --- ATR filter ---
    int atrHandle = iATR(_Symbol, PERIOD_CURRENT, 14);
    double atrBuffer[2];
    if(CopyBuffer(atrHandle, 0, shift, 2, atrBuffer) <= 0) { IndicatorRelease(atrHandle); return false; }
    double atr = atrBuffer[0];
    IndicatorRelease(atrHandle);
    if(atr < minATR) return false;

    // --- ADX filter ---
    int adxHandle = iADX(_Symbol, PERIOD_CURRENT, adxPeriod);
    double adxBuffer[2];
    if(CopyBuffer(adxHandle, 0, shift, 2, adxBuffer) <= 0) { IndicatorRelease(adxHandle); return false; }
    double adx = adxBuffer[0];
    IndicatorRelease(adxHandle);
    if(adx < minADX) return false;

    // --- MACD confirmation ---
    int macdHandle = iMACD(_Symbol, PERIOD_CURRENT, 12, 26, 9, PRICE_CLOSE);
    double macdMain[1], macdSignal[1];
    if(CopyBuffer(macdHandle, 0, shift, 1, macdMain) <= 0) { IndicatorRelease(macdHandle); return false; }
    if(CopyBuffer(macdHandle, 1, shift, 1, macdSignal) <= 0) { IndicatorRelease(macdHandle); return false; }
    double macd = macdMain[0], macdSig = macdSignal[0];
    IndicatorRelease(macdHandle);

    // --- H1 Trend filter ---
    int emaFastH1 = iMA(_Symbol, PERIOD_H1, 20, 0, MODE_EMA, PRICE_CLOSE);
    int emaSlowH1 = iMA(_Symbol, PERIOD_H1, 50, 0, MODE_EMA, PRICE_CLOSE);
    double fastH1[1], slowH1[1];
    bool uptrend = false, downtrend = false;
    if(CopyBuffer(emaFastH1, 0, 0, 1, fastH1) > 0 && CopyBuffer(emaSlowH1, 0, 0, 1, slowH1) > 0) {
        uptrend = fastH1[0] > slowH1[0];
        downtrend = fastH1[0] < slowH1[0];
    }
    IndicatorRelease(emaFastH1); IndicatorRelease(emaSlowH1);

    // --- M5 EMA handles ---
    int fastMAHandle = iMA(_Symbol, PERIOD_CURRENT, fastMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
    int slowMAHandle = iMA(_Symbol, PERIOD_CURRENT, slowMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
    double fastMA[2], slowMA[2];
    if(CopyBuffer(fastMAHandle, 0, shift, 2, fastMA) <= 0) { IndicatorRelease(fastMAHandle); IndicatorRelease(slowMAHandle); return false; }
    if(CopyBuffer(slowMAHandle, 0, shift, 2, slowMA) <= 0) { IndicatorRelease(fastMAHandle); IndicatorRelease(slowMAHandle); return false; }
    IndicatorRelease(fastMAHandle); IndicatorRelease(slowMAHandle);
    double prevFast = fastMA[1], prevSlow = slowMA[1];
    double currFast = fastMA[0], currSlow = slowMA[0];
    double emaDist = MathAbs(currFast - currSlow);
    if(emaDist < minEMADist) return false;

    // --- Candle quality ---
    double close = iClose(_Symbol, PERIOD_CURRENT, shift);
    double open = iOpen(_Symbol, PERIOD_CURRENT, shift);
    double high = iHigh(_Symbol, PERIOD_CURRENT, shift);
    double low = iLow(_Symbol, PERIOD_CURRENT, shift);
    double body = MathAbs(close - open);
    if(body < minBodyRatio * atr) return false;
    double candleRange = high - low;
    bool strongBull = (close >= high - 0.2 * candleRange);
    bool strongBear = (close <= low + 0.2 * candleRange);

    // --- Cross detection ---
    bool crossUp = (prevFast <= prevSlow && currFast > currSlow);
    bool crossDown = (prevFast >= prevSlow && currFast < currSlow);

    // --- Buy signal ---
    if(crossUp && uptrend && adx > minADX && macd > macdSig && strongBull && (currentBar - lastBuyBar > consecutiveTradeLimit)) {
        double sl = low - 1.2 * atr;
        double entry = close;
        double maxSLDist = GetMaxSLDistance(LotSize);
        if((entry - sl) > maxSLDist) sl = entry - maxSLDist;
        double tp = close + (close - sl) * 1.5;
        double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
        double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
        double expectedProfit = ((tp - entry) / tick_size) * tick_value * LotSize;
        double commission = CalculateCommissionOrSpread(LotSize);
        if(expectedProfit < commission) return false;
        if(OpenTrade(ORDER_TYPE_BUY, sl, tp, "MA Cross Buy")) {
            lastBuyBar = currentBar;
            return true;
        }
    }
    // --- Sell signal ---
    if(crossDown && downtrend && adx > minADX && macd < macdSig && strongBear && (currentBar - lastSellBar > consecutiveTradeLimit)) {
        double sl = high + 1.2 * atr;
        double entry = close;
        double maxSLDist = GetMaxSLDistance(LotSize);
        if((sl - entry) > maxSLDist) sl = entry + maxSLDist;
        double tp = close - (sl - close) * 1.5;
        double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
        double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
        double expectedProfit = ((entry - tp) / tick_size) * tick_value * LotSize;
        double commission = CalculateCommissionOrSpread(LotSize);
        if(expectedProfit < commission) return false;
        if(OpenTrade(ORDER_TYPE_SELL, sl, tp, "MA Cross Sell")) {
            lastSellBar = currentBar;
            return true;
        }
    }
    return false;
} 

// --- Bollinger Band Breakout Strategy with Advanced Filters and Exits ---
bool BollingerBandBreakoutStrategySignal()
{
    // Dynamic parameters
    int bbPeriod = 20;
    double bbDeviation = 2.0;
    int rsiPeriod = 14;
    double rsiBuy = 55.0, rsiSell = 45.0;
    double minVolatility = 10 * SymbolInfoDouble(_Symbol, SYMBOL_POINT); // ATR filter
    double minBandWidth = 30 * SymbolInfoDouble(_Symbol, SYMBOL_POINT); // Minimum band width
    double maxSpread = MaxSpread; // Use input
    int shift = 1; // Use last closed bar
    double bandBufferRatio = 0.10; // 10% of band width
    double minBodyRatio = 0.5; // Candle body at least 50% of band width
    int minVolume = 100; // Minimum tick volume (dynamic)
    int minRetestBars = 2, maxRetestBars = 5; // Retest window
    int consecutiveTradeLimit = 1; // Only 1 trade per direction per N bars
    static int lastBuyBar = -1000, lastSellBar = -1000;
    int currentBar = Bars(_Symbol, PERIOD_CURRENT);

    // --- Spread filter ---
    double currentSpread = (double)(SymbolInfoInteger(_Symbol, SYMBOL_SPREAD));
    if(currentSpread > maxSpread) return false;

    // --- Volatility filter (ATR) ---
    int atrPeriod = 14;
    int atrHandle = iATR(_Symbol, PERIOD_CURRENT, atrPeriod);
    double atrBuffer[2];
    if(CopyBuffer(atrHandle, 0, shift, 2, atrBuffer) <= 0) { IndicatorRelease(atrHandle); return false; }
    double atr = atrBuffer[0];
    IndicatorRelease(atrHandle);
    if(atr < minVolatility) return false;

    // --- Bollinger Bands ---
    int bbHandle = iBands(_Symbol, PERIOD_CURRENT, bbPeriod, 0, bbDeviation, PRICE_CLOSE);
    double upper[2], middle[2], lower[2];
    if(CopyBuffer(bbHandle, 0, shift, 2, upper) <= 0) { IndicatorRelease(bbHandle); return false; }
    if(CopyBuffer(bbHandle, 1, shift, 2, middle) <= 0) { IndicatorRelease(bbHandle); return false; }
    if(CopyBuffer(bbHandle, 2, shift, 2, lower) <= 0) { IndicatorRelease(bbHandle); return false; }
    IndicatorRelease(bbHandle);
    double close = iClose(_Symbol, PERIOD_CURRENT, shift);
    double open = iOpen(_Symbol, PERIOD_CURRENT, shift);
    double high = iHigh(_Symbol, PERIOD_CURRENT, shift);
    double low = iLow(_Symbol, PERIOD_CURRENT, shift);
    double bandWidth = upper[1] - lower[1];
    double buffer = bandBufferRatio * bandWidth;
    double body = MathAbs(close - open);

    // --- No trade in choppy/low volatility ---
    if(bandWidth < minBandWidth) return false;

    // --- Minimum candle body size ---
    if(body < minBodyRatio * bandWidth) return false;

    // --- Volume filter ---
    long tickVolume = iVolume(_Symbol, PERIOD_CURRENT, shift);
    if(tickVolume < minVolume) return false;

    // --- Breakout candle quality: close in top/bottom 20% of range ---
    double candleRange = high - low;
    bool strongBull = (close >= high - 0.2 * candleRange);
    bool strongBear = (close <= low + 0.2 * candleRange);

    // --- RSI ---
    int rsiHandle = iRSI(_Symbol, PERIOD_CURRENT, rsiPeriod, PRICE_CLOSE);
    double rsiBuffer[1];
    if(CopyBuffer(rsiHandle, 0, shift, 1, rsiBuffer) <= 0) { IndicatorRelease(rsiHandle); return false; }
    double rsi = rsiBuffer[0];
    IndicatorRelease(rsiHandle);

    // --- MACD confirmation ---
    int macdHandle = iMACD(_Symbol, PERIOD_CURRENT, 12, 26, 9, PRICE_CLOSE);
    double macdMain[1], macdSignal[1];
    if(CopyBuffer(macdHandle, 0, shift, 1, macdMain) <= 0) { IndicatorRelease(macdHandle); return false; }
    if(CopyBuffer(macdHandle, 1, shift, 1, macdSignal) <= 0) { IndicatorRelease(macdHandle); return false; }
    double macd = macdMain[0], macdSig = macdSignal[0];
    IndicatorRelease(macdHandle);

    double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

    // --- Trend filter (H1 EMA20/EMA50) ---
    int emaFastH1 = iMA(_Symbol, PERIOD_H1, 20, 0, MODE_EMA, PRICE_CLOSE);
    int emaSlowH1 = iMA(_Symbol, PERIOD_H1, 50, 0, MODE_EMA, PRICE_CLOSE);
    double fastH1[1], slowH1[1];
    bool uptrend = false, downtrend = false;
    if(CopyBuffer(emaFastH1, 0, 0, 1, fastH1) > 0 && CopyBuffer(emaSlowH1, 0, 0, 1, slowH1) > 0) {
        uptrend = fastH1[0] > slowH1[0];
        downtrend = fastH1[0] < slowH1[0];
    }
    IndicatorRelease(emaFastH1); IndicatorRelease(emaSlowH1);

    // --- Retest confirmation ---
    bool retestBuy = false, retestSell = false;
    for(int i = minRetestBars; i <= maxRetestBars; i++) {
        double prevClose = iClose(_Symbol, PERIOD_CURRENT, shift + i);
        if(prevClose <= upper[1] + buffer) { retestBuy = true; break; }
    }
    for(int i = minRetestBars; i <= maxRetestBars; i++) {
        double prevClose = iClose(_Symbol, PERIOD_CURRENT, shift + i);
        if(prevClose >= lower[1] - buffer) { retestSell = true; break; }
    }

    // --- Buy breakout: close above upper band + buffer, strong candle, RSI, MACD, uptrend, retest, limit trades ---
    double slBuy = upper[1] - buffer; // Tighter SL just inside band
    double entryBuy = close;
    double maxSLDist = GetMaxSLDistance(LotSize);
    if((entryBuy - slBuy) > maxSLDist) slBuy = entryBuy - maxSLDist;
    double commission = CalculateCommissionOrSpread(LotSize);
    if(close > upper[1] + buffer && rsi > rsiBuy && uptrend && retestBuy && strongBull && macd > macdSig && (currentBar - lastBuyBar > consecutiveTradeLimit)) {
        double tp = close + (close - slBuy) * 1.5;
        double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
        double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
        double expectedProfit = ((tp - entryBuy) / tick_size) * tick_value * LotSize;
        if(expectedProfit < commission) return false;
        if(OpenTrade(ORDER_TYPE_BUY, slBuy, tp, "BB Breakout Buy")) {
            lastBuyBar = currentBar;
            return true;
        }
    }
    // --- Sell breakout: close below lower band - buffer, strong candle, RSI, MACD, downtrend, retest, limit trades ---
    double slSell = lower[1] + buffer; // Tighter SL just inside band
    double entrySell = close;
    if((slSell - entrySell) > maxSLDist) slSell = entrySell + maxSLDist;
    if(close < lower[1] - buffer && rsi < rsiSell && downtrend && retestSell && strongBear && macd < macdSig && (currentBar - lastSellBar > consecutiveTradeLimit)) {
        double tp = close - (slSell - close) * 1.5;
        double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
        double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
        double expectedProfit = ((entrySell - tp) / tick_size) * tick_value * LotSize;
        double commission = CalculateCommissionOrSpread(LotSize);
        if(expectedProfit < commission) return false;
        if(OpenTrade(ORDER_TYPE_SELL, slSell, tp, "BB Breakout Sell")) {
            lastSellBar = currentBar;
            return true;
        }
    }
    return false;
} 

// --- Stochastic Oscillator Reversal Strategy with Advanced Filters ---
bool StochasticReversalStrategySignal()
{
    int kPeriod = 14, dPeriod = 3, slowing = 3;
    double overbought = 80.0, oversold = 20.0;
    double minVolatility = 10 * SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    double minATR = 10 * SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    double minEMADist = 10 * SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    double minBodyRatio = 0.5;
    int adxPeriod = 14;
    double minADX = 25.0;
    int consecutiveTradeLimit = 1;
    static int lastBuyBar = -1000, lastSellBar = -1000;
    int currentBar = Bars(_Symbol, PERIOD_CURRENT);
    int shift = 1;

    // --- ATR filter ---
    int atrHandle = iATR(_Symbol, PERIOD_CURRENT, 14);
    double atrBuffer[2];
    if(CopyBuffer(atrHandle, 0, shift, 2, atrBuffer) <= 0) { IndicatorRelease(atrHandle); return false; }
    double atr = atrBuffer[0];
    IndicatorRelease(atrHandle);
    if(atr < minATR) return false;

    // --- ADX filter ---
    int adxHandle = iADX(_Symbol, PERIOD_CURRENT, adxPeriod);
    double adxBuffer[2];
    if(CopyBuffer(adxHandle, 0, shift, 2, adxBuffer) <= 0) { IndicatorRelease(adxHandle); return false; }
    double adx = adxBuffer[0];
    IndicatorRelease(adxHandle);
    if(adx < minADX) return false;

    // --- MACD confirmation ---
    int macdHandle = iMACD(_Symbol, PERIOD_CURRENT, 12, 26, 9, PRICE_CLOSE);
    double macdMain[1], macdSignal[1];
    if(CopyBuffer(macdHandle, 0, shift, 1, macdMain) <= 0) { IndicatorRelease(macdHandle); return false; }
    if(CopyBuffer(macdHandle, 1, shift, 1, macdSignal) <= 0) { IndicatorRelease(macdHandle); return false; }
    double macd = macdMain[0], macdSig = macdSignal[0];
    IndicatorRelease(macdHandle);

    // --- H1 Trend filter ---
    int emaFastH1 = iMA(_Symbol, PERIOD_H1, 20, 0, MODE_EMA, PRICE_CLOSE);
    int emaSlowH1 = iMA(_Symbol, PERIOD_H1, 50, 0, MODE_EMA, PRICE_CLOSE);
    double fastH1[1], slowH1[1];
    bool uptrend = false, downtrend = false;
    if(CopyBuffer(emaFastH1, 0, 0, 1, fastH1) > 0 && CopyBuffer(emaSlowH1, 0, 0, 1, slowH1) > 0) {
        uptrend = fastH1[0] > slowH1[0];
        downtrend = fastH1[0] < slowH1[0];
    }
    IndicatorRelease(emaFastH1); IndicatorRelease(emaSlowH1);

    // --- EMA handles ---
    int emaFastHandle = iMA(_Symbol, PERIOD_CURRENT, 20, 0, MODE_EMA, PRICE_CLOSE);
    int emaSlowHandle = iMA(_Symbol, PERIOD_CURRENT, 50, 0, MODE_EMA, PRICE_CLOSE);
    double emaFast[2], emaSlow[2];
    if(CopyBuffer(emaFastHandle, 0, shift, 2, emaFast) <= 0) { IndicatorRelease(emaFastHandle); IndicatorRelease(emaSlowHandle); return false; }
    if(CopyBuffer(emaSlowHandle, 0, shift, 2, emaSlow) <= 0) { IndicatorRelease(emaFastHandle); IndicatorRelease(emaSlowHandle); return false; }
    IndicatorRelease(emaFastHandle); IndicatorRelease(emaSlowHandle);
    double currEmaFast = emaFast[0];
    double currEmaSlow = emaSlow[0];
    double emaDist = MathAbs(currEmaFast - currEmaSlow);
    if(emaDist < minEMADist) return false;

    // --- Stochastic ---
    int stochHandle = iStochastic(_Symbol, PERIOD_CURRENT, kPeriod, dPeriod, slowing, MODE_SMA, 0);
    double kBuffer[2], dBuffer[2];
    if(CopyBuffer(stochHandle, 0, shift, 2, kBuffer) <= 0) { IndicatorRelease(stochHandle); return false; }
    if(CopyBuffer(stochHandle, 1, shift, 2, dBuffer) <= 0) { IndicatorRelease(stochHandle); return false; }
    IndicatorRelease(stochHandle);
    double prevK = kBuffer[1], prevD = dBuffer[1];
    double currK = kBuffer[0], currD = dBuffer[0];

    // --- Candle body filter ---
    double close = iClose(_Symbol, PERIOD_CURRENT, shift);
    double open = iOpen(_Symbol, PERIOD_CURRENT, shift);
    double high = iHigh(_Symbol, PERIOD_CURRENT, shift);
    double low = iLow(_Symbol, PERIOD_CURRENT, shift);
    double body = MathAbs(close - open);
    if(body < minBodyRatio * atr) return false;
    double candleRange = high - low;
    bool strongBull = (close >= high - 0.2 * candleRange);
    bool strongBear = (close <= low + 0.2 * candleRange);
    double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

    // --- Buy reversal: K crosses above D in oversold, uptrend, limit trades ---
    if(prevK < prevD && currK > currD && prevK < oversold && currK > oversold && uptrend && adx > minADX && macd > macdSig && strongBull && (currentBar - lastBuyBar > consecutiveTradeLimit)) {
        double sl = low - 1.2 * atr;
        double entry = close;
        double maxSLDist = GetMaxSLDistance(LotSize);
        if((entry - sl) > maxSLDist) sl = entry - maxSLDist;
        double tp = close + (close - sl) * 1.5;
        double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
        double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
        double expectedProfit = ((tp - entry) / tick_size) * tick_value * LotSize;
        double commission = CalculateCommissionOrSpread(LotSize);
        if(expectedProfit < commission) return false;
        if(OpenTrade(ORDER_TYPE_BUY, sl, tp, "Stoch Reversal Buy")) {
            lastBuyBar = currentBar;
            return true;
        }
    }
    // --- Sell reversal: K crosses below D in overbought, downtrend, limit trades ---
    if(prevK > prevD && currK < currD && prevK > overbought && currK < overbought && downtrend && adx > minADX && macd < macdSig && strongBear && (currentBar - lastSellBar > consecutiveTradeLimit)) {
        double sl = high + 1.2 * atr;
        double entry = close;
        double maxSLDist = GetMaxSLDistance(LotSize);
        if((sl - entry) > maxSLDist) sl = entry + maxSLDist;
        double tp = close - (sl - close) * 1.5;
        double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
        double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
        double expectedProfit = ((entry - tp) / tick_size) * tick_value * LotSize;
        double commission = CalculateCommissionOrSpread(LotSize);
        if(expectedProfit < commission) return false;
        if(OpenTrade(ORDER_TYPE_SELL, sl, tp, "Stoch Reversal Sell")) {
            lastSellBar = currentBar;
            return true;
        }
    }
    return false;
} 

// --- VWAP Bounce Strategy with Advanced Filters ---
bool VWAPBounceStrategySignal()
{
    double minATR = 10 * SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    double minEMADist = 10 * SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    double minBodyRatio = 0.5;
    int adxPeriod = 14;
    double minADX = 25.0;
    int consecutiveTradeLimit = 1;
    static int lastBuyBar = -1000, lastSellBar = -1000;
    int currentBar = Bars(_Symbol, PERIOD_CURRENT);
    int shift = 1;

    // --- ATR filter ---
    int atrHandle = iATR(_Symbol, PERIOD_CURRENT, 14);
    double atrBuffer[2];
    if(CopyBuffer(atrHandle, 0, shift, 2, atrBuffer) <= 0) { IndicatorRelease(atrHandle); return false; }
    double atr = atrBuffer[0];
    IndicatorRelease(atrHandle);
    if(atr < minATR) return false;

    // --- ADX filter ---
    int adxHandle = iADX(_Symbol, PERIOD_CURRENT, adxPeriod);
    double adxBuffer[2];
    if(CopyBuffer(adxHandle, 0, shift, 2, adxBuffer) <= 0) { IndicatorRelease(adxHandle); return false; }
    double adx = adxBuffer[0];
    IndicatorRelease(adxHandle);
    if(adx < minADX) return false;

    // --- MACD confirmation ---
    int macdHandle = iMACD(_Symbol, PERIOD_CURRENT, 12, 26, 9, PRICE_CLOSE);
    double macdMain[1], macdSignal[1];
    if(CopyBuffer(macdHandle, 0, shift, 1, macdMain) <= 0) { IndicatorRelease(macdHandle); return false; }
    if(CopyBuffer(macdHandle, 1, shift, 1, macdSignal) <= 0) { IndicatorRelease(macdHandle); return false; }
    double macd = macdMain[0], macdSig = macdSignal[0];
    IndicatorRelease(macdHandle);

    // --- H1 Trend filter ---
    int emaFastH1 = iMA(_Symbol, PERIOD_H1, 20, 0, MODE_EMA, PRICE_CLOSE);
    int emaSlowH1 = iMA(_Symbol, PERIOD_H1, 50, 0, MODE_EMA, PRICE_CLOSE);
    double fastH1[1], slowH1[1];
    bool uptrend = false, downtrend = false;
    if(CopyBuffer(emaFastH1, 0, 0, 1, fastH1) > 0 && CopyBuffer(emaSlowH1, 0, 0, 1, slowH1) > 0) {
        uptrend = fastH1[0] > slowH1[0];
        downtrend = fastH1[0] < slowH1[0];
    }
    IndicatorRelease(emaFastH1); IndicatorRelease(emaSlowH1);

    // --- EMA handles ---
    int emaFastHandle = iMA(_Symbol, PERIOD_CURRENT, 20, 0, MODE_EMA, PRICE_CLOSE);
    int emaSlowHandle = iMA(_Symbol, PERIOD_CURRENT, 50, 0, MODE_EMA, PRICE_CLOSE);
    double emaFast[2], emaSlow[2];
    if(CopyBuffer(emaFastHandle, 0, shift, 2, emaFast) <= 0) { IndicatorRelease(emaFastHandle); IndicatorRelease(emaSlowHandle); return false; }
    if(CopyBuffer(emaSlowHandle, 0, shift, 2, emaSlow) <= 0) { IndicatorRelease(emaFastHandle); IndicatorRelease(emaSlowHandle); return false; }
    IndicatorRelease(emaFastHandle); IndicatorRelease(emaSlowHandle);
    double currEmaFast = emaFast[0];
    double currEmaSlow = emaSlow[0];
    double emaDist = MathAbs(currEmaFast - currEmaSlow);
    if(emaDist < minEMADist) return false;

    // --- VWAP calculation (manual, since no native iVWAP) ---
    double vwap = 0.0, totalPV = 0.0, totalVol = 0.0;
    int vwapLookback = 30;
    for(int i = shift; i < shift + vwapLookback; i++) {
        double price = (iHigh(_Symbol, PERIOD_CURRENT, i) + iLow(_Symbol, PERIOD_CURRENT, i) + iClose(_Symbol, PERIOD_CURRENT, i)) / 3.0;
        double vol = iVolume(_Symbol, PERIOD_CURRENT, i);
        totalPV += price * vol;
        totalVol += vol;
    }
    if(totalVol > 0) vwap = totalPV / totalVol;
    else return false;

    // --- Candle body filter ---
    double close = iClose(_Symbol, PERIOD_CURRENT, shift);
    double open = iOpen(_Symbol, PERIOD_CURRENT, shift);
    double high = iHigh(_Symbol, PERIOD_CURRENT, shift);
    double low = iLow(_Symbol, PERIOD_CURRENT, shift);
    double body = MathAbs(close - open);
    if(body < minBodyRatio * atr) return false;
    double candleRange = high - low;
    bool strongBull = (close >= high - 0.2 * candleRange);
    bool strongBear = (close <= low + 0.2 * candleRange);
    double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

    // --- Buy bounce: price dips below VWAP and closes above, uptrend, limit trades ---
    if(low < vwap && close > vwap && uptrend && adx > minADX && macd > macdSig && strongBull && (currentBar - lastBuyBar > consecutiveTradeLimit)) {
        double sl = low - 1.2 * atr;
        double entry = close;
        double maxSLDist = GetMaxSLDistance(LotSize);
        if((entry - sl) > maxSLDist) sl = entry - maxSLDist;
        double tp = close + (close - sl) * 1.5;
        double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
        double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
        double expectedProfit = ((tp - entry) / tick_size) * tick_value * LotSize;
        double commission = CalculateCommissionOrSpread(LotSize);
        if(expectedProfit < commission) return false;
        if(OpenTrade(ORDER_TYPE_BUY, sl, tp, "VWAP Bounce Buy")) {
            lastBuyBar = currentBar;
            return true;
        }
    }
    // --- Sell bounce: price spikes above VWAP and closes below, downtrend, limit trades ---
    if(high > vwap && close < vwap && downtrend && adx > minADX && macd < macdSig && strongBear && (currentBar - lastSellBar > consecutiveTradeLimit)) {
        double sl = high + 1.2 * atr;
        double entry = close;
        double maxSLDist = GetMaxSLDistance(LotSize);
        if((sl - entry) > maxSLDist) sl = entry + maxSLDist;
        double tp = close - (sl - close) * 1.5;
        double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
        double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
        double expectedProfit = ((entry - tp) / tick_size) * tick_value * LotSize;
        double commission = CalculateCommissionOrSpread(LotSize);
        if(expectedProfit < commission) return false;
        if(OpenTrade(ORDER_TYPE_SELL, sl, tp, "VWAP Bounce Sell")) {
            lastSellBar = currentBar;
            return true;
        }
    }
    return false;
} 

// Helper: Calculate max SL price distance for given lot size
// Returns price distance (in price units, not points)
double GetMaxSLDistance(double lot) {
    double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    if(tickValue == 0 || tickSize == 0) return 0;
    double points = (MaxSLAmount / (tickValue * lot)) * tickSize / point;
    return points * point;
} 

// --- Mean Reversion to VWAP/MA Strategy ---
bool MeanReversionVWAPMAStrategySignal()
{
    int shift = 1;
    double atrPeriod = 14;
    double atrHandle = iATR(_Symbol, PERIOD_CURRENT, atrPeriod);
    double atrBuffer[2];
    if(CopyBuffer(atrHandle, 0, shift, 2, atrBuffer) <= 0) { IndicatorRelease(atrHandle); return false; }
    double atr = atrBuffer[0];
    IndicatorRelease(atrHandle);
    double lowVolThreshold = 10 * SymbolInfoDouble(_Symbol, SYMBOL_POINT); // Low volatility threshold
    if(atr > lowVolThreshold) return false; // Only trade in low volatility

    // --- VWAP calculation (manual, since no native iVWAP) ---
    double vwap = 0.0, totalPV = 0.0, totalVol = 0.0;
    int vwapLookback = 30;
    for(int i = shift; i < shift + vwapLookback; i++) {
        double price = (iHigh(_Symbol, PERIOD_CURRENT, i) + iLow(_Symbol, PERIOD_CURRENT, i) + iClose(_Symbol, PERIOD_CURRENT, i)) / 3.0;
        double vol = iVolume(_Symbol, PERIOD_CURRENT, i);
        totalPV += price * vol;
        totalVol += vol;
    }
    if(totalVol > 0) vwap = totalPV / totalVol;
    else return false;

    // --- MA calculation ---
    int maPeriod = 20;
    int maHandle = iMA(_Symbol, PERIOD_CURRENT, maPeriod, 0, MODE_EMA, PRICE_CLOSE);
    double maBuffer[2];
    if(CopyBuffer(maHandle, 0, shift, 2, maBuffer) <= 0) { IndicatorRelease(maHandle); return false; }
    double ma = maBuffer[0];
    IndicatorRelease(maHandle);

    double close = iClose(_Symbol, PERIOD_CURRENT, shift);
    double open = iOpen(_Symbol, PERIOD_CURRENT, shift);
    double high = iHigh(_Symbol, PERIOD_CURRENT, shift);
    double low = iLow(_Symbol, PERIOD_CURRENT, shift);
    double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    double lot = LotSize;
    double maxSLDist = GetMaxSLDistance(lot);
    int consecutiveTradeLimit = 1;
    static int lastBuyBar = -1000;
    static int lastSellBar = -1000;
    int currentBar = Bars(_Symbol, PERIOD_CURRENT);

    // --- RSI confirmation ---
    int rsiPeriod = 14;
    int rsiHandle = iRSI(_Symbol, PERIOD_CURRENT, rsiPeriod, PRICE_CLOSE);
    double rsiBuffer[1];
    if(CopyBuffer(rsiHandle, 0, shift, 1, rsiBuffer) <= 0) { IndicatorRelease(rsiHandle); return false; }
    double rsi = rsiBuffer[0];
    IndicatorRelease(rsiHandle);

    // --- Stochastic confirmation ---
    int kPeriod = 14, dPeriod = 3, slowing = 3;
    int stochHandle = iStochastic(_Symbol, PERIOD_CURRENT, kPeriod, dPeriod, slowing, MODE_SMA, 0);
    double kBuffer[2], dBuffer[2];
    if(CopyBuffer(stochHandle, 0, shift, 2, kBuffer) <= 0) { IndicatorRelease(stochHandle); return false; }
    if(CopyBuffer(stochHandle, 1, shift, 2, dBuffer) <= 0) { IndicatorRelease(stochHandle); return false; }
    IndicatorRelease(stochHandle);
    double currK = kBuffer[0], currD = dBuffer[0];

    // --- Mean reversion logic ---
    double deviationVWAP = MathAbs(close - vwap);
    double deviationMA = MathAbs(close - ma);
    double minDeviation = 1.5 * atr; // Require price to be at least 1.5 ATR away from VWAP/MA

    // --- Buy: price below VWAP/MA by minDeviation, RSI < 35, Stoch < 20 ---
    if(close < vwap - minDeviation && close < ma - minDeviation && rsi < 35 && currK < 20 && currD < 20 && (currentBar - lastBuyBar > consecutiveTradeLimit)) {
        double entry = close;
        double sl = low - 1.2 * atr;
        if((entry - sl) > maxSLDist) sl = entry - maxSLDist;
        double tp = vwap;
        double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
        double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
        double expectedProfit = ((tp - entry) / tick_size) * tick_value * lot;
        double commission = CalculateCommissionOrSpread(lot);
        if(expectedProfit < commission) return false;
        if(OpenTrade(ORDER_TYPE_BUY, sl, tp, "MeanRev VWAP/MA Buy")) {
            lastBuyBar = currentBar;
            return true;
        }
    }
    // --- Sell: price above VWAP/MA by minDeviation, RSI > 65, Stoch > 80 ---
    if(close > vwap + minDeviation && close > ma + minDeviation && rsi > 65 && currK > 80 && currD > 80 && (currentBar - lastSellBar > consecutiveTradeLimit)) {
        double entry = close;
        double sl = high + 1.2 * atr;
        if((sl - entry) > maxSLDist) sl = entry + maxSLDist;
        double tp = vwap;
        double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
        double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
        double expectedProfit = ((entry - tp) / tick_size) * tick_value * lot;
        double commission = CalculateCommissionOrSpread(lot);
        if(expectedProfit < commission) return false;
        if(OpenTrade(ORDER_TYPE_SELL, sl, tp, "MeanRev VWAP/MA Sell")) {
            lastSellBar = currentBar;
            return true;
        }
    }
    return false;
}

// --- Range/Channel Trading Strategy ---
bool RangeChannelTradingStrategySignal()
{
    int shift = 1;
    int rangeBars = 30;
    double atrPeriod = 14;
    double atrHandle = iATR(_Symbol, PERIOD_CURRENT, atrPeriod);
    double atrBuffer[2];
    if(CopyBuffer(atrHandle, 0, shift, 2, atrBuffer) <= 0) { IndicatorRelease(atrHandle); return false; }
    double atr = atrBuffer[0];
    IndicatorRelease(atrHandle);
    double lowVolThreshold = 10 * SymbolInfoDouble(_Symbol, SYMBOL_POINT); // Low volatility threshold
    if(atr > lowVolThreshold) return false; // Only trade in low volatility

    // --- Identify range ---
    double rangeHigh = iHigh(_Symbol, PERIOD_CURRENT, shift);
    double rangeLow = iLow(_Symbol, PERIOD_CURRENT, shift);
    for(int i=shift+1; i<shift+rangeBars; i++) {
        double h = iHigh(_Symbol, PERIOD_CURRENT, i);
        double l = iLow(_Symbol, PERIOD_CURRENT, i);
        if(h > rangeHigh) rangeHigh = h;
        if(l < rangeLow) rangeLow = l;
    }
    double rangeWidth = rangeHigh - rangeLow;
    if(rangeWidth < 10 * SymbolInfoDouble(_Symbol, SYMBOL_POINT)) return false; // Avoid too tight ranges

    // --- Flat MA filter ---
    int maPeriod = 20;
    int maHandle = iMA(_Symbol, PERIOD_CURRENT, maPeriod, 0, MODE_SMA, PRICE_CLOSE);
    double maBuffer[10];
    if(CopyBuffer(maHandle, 0, shift, 10, maBuffer) <= 0) { IndicatorRelease(maHandle); return false; }
    IndicatorRelease(maHandle);
    double maMax = maBuffer[0], maMin = maBuffer[0];
    for(int i=1; i<10; i++) {
        if(maBuffer[i] > maMax) maMax = maBuffer[i];
        if(maBuffer[i] < maMin) maMin = maBuffer[i];
    }
    if((maMax - maMin) > 5 * SymbolInfoDouble(_Symbol, SYMBOL_POINT)) return false; // MA not flat enough

    double close = iClose(_Symbol, PERIOD_CURRENT, shift);
    double open = iOpen(_Symbol, PERIOD_CURRENT, shift);
    double high = iHigh(_Symbol, PERIOD_CURRENT, shift);
    double low = iLow(_Symbol, PERIOD_CURRENT, shift);
    double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    double lot = LotSize;
    double maxSLDist = GetMaxSLDistance(lot);
    int consecutiveTradeLimit = 1;
    static int lastBuyBar = -1000, lastSellBar = -1000;
    int currentBar = Bars(_Symbol, PERIOD_CURRENT);

    // --- Oscillator confirmation (Stochastic) ---
    int kPeriod = 14, dPeriod = 3, slowing = 3;
    int stochHandle = iStochastic(_Symbol, PERIOD_CURRENT, kPeriod, dPeriod, slowing, MODE_SMA, 0);
    double kBuffer[2], dBuffer[2];
    if(CopyBuffer(stochHandle, 0, shift, 2, kBuffer) <= 0) { IndicatorRelease(stochHandle); return false; }
    if(CopyBuffer(stochHandle, 1, shift, 2, dBuffer) <= 0) { IndicatorRelease(stochHandle); return false; }
    IndicatorRelease(stochHandle);
    double currK = kBuffer[0], currD = dBuffer[0];

    // --- Candlestick reversal: bullish/bearish engulfing ---
    double prevClose = iClose(_Symbol, PERIOD_CURRENT, shift+1);
    double prevOpen = iOpen(_Symbol, PERIOD_CURRENT, shift+1);
    bool bullishEngulf = (close > open && prevClose < prevOpen && close > prevOpen && open < prevClose);
    bool bearishEngulf = (close < open && prevClose > prevOpen && close < prevOpen && open > prevClose);

    // --- Buy: price near range low, bullish engulfing, Stoch < 20 ---
    if(close < rangeLow + 2*atr && bullishEngulf && currK < 20 && currD < 20 && (currentBar - lastBuyBar > consecutiveTradeLimit)) {
        double entry = close;
        double sl = rangeLow - 1.2 * atr;
        if((entry - sl) > maxSLDist) sl = entry - maxSLDist;
        double tp = rangeHigh;
        double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
        double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
        double expectedProfit = ((tp - entry) / tick_size) * tick_value * lot;
        double commission = CalculateCommissionOrSpread(lot);
        if(expectedProfit < commission) return false;
        if(OpenTrade(ORDER_TYPE_BUY, sl, tp, "Range Buy")) {
            lastBuyBar = currentBar;
            return true;
        }
    }
    // --- Sell: price near range high, bearish engulfing, Stoch > 80 ---
    if(close > rangeHigh - 2*atr && bearishEngulf && currK > 80 && currD > 80 && (currentBar - lastSellBar > consecutiveTradeLimit)) {
        double entry = close;
        double sl = rangeHigh + 1.2 * atr;
        if((sl - entry) > maxSLDist) sl = entry + maxSLDist;
        double tp = rangeLow;
        double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
        double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
        double expectedProfit = ((entry - tp) / tick_size) * tick_value * lot;
        double commission = CalculateCommissionOrSpread(lot);
        if(expectedProfit < commission) return false;
        if(OpenTrade(ORDER_TYPE_SELL, sl, tp, "Range Sell")) {
            lastSellBar = currentBar;
            return true;
        }
    }
    return false;
}

// --- Heikin Ashi Trend Following Strategy ---
bool HeikinAshiTrendFollowingStrategySignal()
{
    int shift = 1;
    double atrPeriod = 14;
    double atrHandle = iATR(_Symbol, PERIOD_CURRENT, atrPeriod);
    double atrBuffer[2];
    if(CopyBuffer(atrHandle, 0, shift, 2, atrBuffer) <= 0) { IndicatorRelease(atrHandle); return false; }
    double atr = atrBuffer[0];
    IndicatorRelease(atrHandle);
    double minATR = 10 * SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    if(atr < minATR) return false; // Only trade in sufficient volatility

    // --- Higher timeframe trend filter (H1 EMA20/EMA50) ---
    int emaFastH1 = iMA(_Symbol, PERIOD_H1, 20, 0, MODE_EMA, PRICE_CLOSE);
    int emaSlowH1 = iMA(_Symbol, PERIOD_H1, 50, 0, MODE_EMA, PRICE_CLOSE);
    double fastH1[1], slowH1[1];
    bool uptrend = false, downtrend = false;
    if(CopyBuffer(emaFastH1, 0, 0, 1, fastH1) > 0 && CopyBuffer(emaSlowH1, 0, 0, 1, slowH1) > 0) {
        uptrend = fastH1[0] > slowH1[0];
        downtrend = fastH1[0] < slowH1[0];
    }
    IndicatorRelease(emaFastH1); IndicatorRelease(emaSlowH1);

    double lot = LotSize;
    double maxSLDist = GetMaxSLDistance(lot);
    int consecutiveTradeLimit = 1;
    static int lastBuyBar = -1000, lastSellBar = -1000;
    int currentBar = Bars(_Symbol, PERIOD_CURRENT);

    // --- Heikin Ashi calculation (manual) ---
    double haClose[3], haOpen[3], haHigh[3], haLow[3];
    for(int i=0; i<3; i++) {
        double c = iClose(_Symbol, PERIOD_CURRENT, shift+i);
        double o = iOpen(_Symbol, PERIOD_CURRENT, shift+i);
        double h = iHigh(_Symbol, PERIOD_CURRENT, shift+i);
        double l = iLow(_Symbol, PERIOD_CURRENT, shift+i);
        if(i==0) {
            haClose[i] = (o + h + l + c) / 4.0;
            haOpen[i] = (o + c) / 2.0;
        } else {
            haClose[i] = (o + h + l + c) / 4.0;
            haOpen[i] = (haOpen[i-1] + haClose[i-1]) / 2.0;
        }
        haHigh[i] = MathMax(h, MathMax(haOpen[i], haClose[i]));
        haLow[i] = MathMin(l, MathMin(haOpen[i], haClose[i]));
    }
    // --- Heikin Ashi color and size ---
    bool haBull = haClose[0] > haOpen[0];
    bool haBear = haClose[0] < haOpen[0];
    double haBody = MathAbs(haClose[0] - haOpen[0]);
    double minBody = 0.5 * atr;
    // --- Entry on color change or pullback ---
    // Buy: H1 uptrend, HA color change to bull, body size, previous HA was bear
    if(uptrend && haBull && haBody > minBody && haClose[1] < haOpen[1] && (currentBar - lastBuyBar > consecutiveTradeLimit)) {
        double entry = haClose[0];
        double sl = haLow[0] - 1.2 * atr;
        if((entry - sl) > maxSLDist) sl = entry - maxSLDist;
        double tp = entry + 2 * (entry - sl);
        double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
        double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
        double expectedProfit = ((tp - entry) / tick_size) * tick_value * lot;
        double commission = CalculateCommissionOrSpread(lot);
        if(expectedProfit < commission) return false;
        if(OpenTrade(ORDER_TYPE_BUY, sl, tp, "HA Trend Buy")) {
            lastBuyBar = currentBar;
            return true;
        }
    }
    // Sell: H1 downtrend, HA color change to bear, body size, previous HA was bull
    if(downtrend && haBear && haBody > minBody && haClose[1] > haOpen[1] && (currentBar - lastSellBar > consecutiveTradeLimit)) {
        double entry = haClose[0];
        double sl = haHigh[0] + 1.2 * atr;
        if((sl - entry) > maxSLDist) sl = entry + maxSLDist;
        double tp = entry - 2 * (sl - entry);
        double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
        double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
        double expectedProfit = ((entry - tp) / tick_size) * tick_value * lot;
        double commission = CalculateCommissionOrSpread(lot);
        if(expectedProfit < commission) return false;
        if(OpenTrade(ORDER_TYPE_SELL, sl, tp, "HA Trend Sell")) {
            lastSellBar = currentBar;
            return true;
        }
    }
    return false;
}

// --- Parabolic SAR Reversal Strategy ---
bool ParabolicSARReversalStrategySignal()
{
    int shift = 1;
    double atrPeriod = 14;
    double atrHandle = iATR(_Symbol, PERIOD_CURRENT, atrPeriod);
    double atrBuffer[2];
    if(CopyBuffer(atrHandle, 0, shift, 2, atrBuffer) <= 0) { IndicatorRelease(atrHandle); return false; }
    double atr = atrBuffer[0];
    IndicatorRelease(atrHandle);
    double minATR = 10 * SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    if(atr < minATR) return false;

    // --- Parabolic SAR ---
    double sarStep = 0.02, sarMax = 0.2;
    int sarHandle = iSAR(_Symbol, PERIOD_CURRENT, sarStep, sarMax);
    double sarBuffer[2];
    if(CopyBuffer(sarHandle, 0, shift, 2, sarBuffer) <= 0) { IndicatorRelease(sarHandle); return false; }
    IndicatorRelease(sarHandle);
    double prevSAR = sarBuffer[1];
    double currSAR = sarBuffer[0];
    double prevClose = iClose(_Symbol, PERIOD_CURRENT, shift+1);
    double close = iClose(_Symbol, PERIOD_CURRENT, shift);
    double open = iOpen(_Symbol, PERIOD_CURRENT, shift);
    double high = iHigh(_Symbol, PERIOD_CURRENT, shift);
    double low = iLow(_Symbol, PERIOD_CURRENT, shift);
    double lot = LotSize;
    double maxSLDist = GetMaxSLDistance(lot);
    int consecutiveTradeLimit = 1;
    static int lastBuyBar = -1000, lastSellBar = -1000;
    int currentBar = Bars(_Symbol, PERIOD_CURRENT);

    // --- H1 Trend filter (EMA20/EMA50) ---
    int emaFastH1 = iMA(_Symbol, PERIOD_H1, 20, 0, MODE_EMA, PRICE_CLOSE);
    int emaSlowH1 = iMA(_Symbol, PERIOD_H1, 50, 0, MODE_EMA, PRICE_CLOSE);
    double fastH1[1], slowH1[1];
    bool uptrend = false, downtrend = false;
    if(CopyBuffer(emaFastH1, 0, 0, 1, fastH1) > 0 && CopyBuffer(emaSlowH1, 0, 0, 1, slowH1) > 0) {
        uptrend = fastH1[0] > slowH1[0];
        downtrend = fastH1[0] < slowH1[0];
    }
    IndicatorRelease(emaFastH1); IndicatorRelease(emaSlowH1);

    // --- MACD confirmation ---
    int macdHandle = iMACD(_Symbol, PERIOD_CURRENT, 12, 26, 9, PRICE_CLOSE);
    double macdMain[1], macdSignal[1];
    if(CopyBuffer(macdHandle, 0, shift, 1, macdMain) <= 0) { IndicatorRelease(macdHandle); return false; }
    if(CopyBuffer(macdHandle, 1, shift, 1, macdSignal) <= 0) { IndicatorRelease(macdHandle); return false; }
    double macd = macdMain[0], macdSig = macdSignal[0];
    IndicatorRelease(macdHandle);

    // --- RSI confirmation ---
    int rsiPeriod = 14;
    int rsiHandle = iRSI(_Symbol, PERIOD_CURRENT, rsiPeriod, PRICE_CLOSE);
    double rsiBuffer[1];
    if(CopyBuffer(rsiHandle, 0, shift, 1, rsiBuffer) <= 0) { IndicatorRelease(rsiHandle); return false; }
    double rsi = rsiBuffer[0];
    IndicatorRelease(rsiHandle);

    // --- Buy: SAR flips below price, uptrend, MACD > signal, RSI > 55, previous SAR above price ---
    if(prevSAR > prevClose && currSAR < close && uptrend && macd > macdSig && rsi > 55 && (currentBar - lastBuyBar > consecutiveTradeLimit)) {
        double entry = close;
        double sl = low - 1.2 * atr;
        if((entry - sl) > maxSLDist) sl = entry - maxSLDist;
        double tp = entry + 2 * (entry - sl);
        double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
        double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
        double expectedProfit = ((tp - entry) / tick_size) * tick_value * lot;
        double commission = CalculateCommissionOrSpread(lot);
        if(expectedProfit < commission) return false;
        if(OpenTrade(ORDER_TYPE_BUY, sl, tp, "SAR Reversal Buy")) {
            lastBuyBar = currentBar;
            return true;
        }
    }
    // --- Sell: SAR flips above price, downtrend, MACD < signal, RSI < 45, previous SAR below price ---
    if(prevSAR < prevClose && currSAR > close && downtrend && macd < macdSig && rsi < 45 && (currentBar - lastSellBar > consecutiveTradeLimit)) {
        double entry = close;
        double sl = high + 1.2 * atr;
        if((sl - entry) > maxSLDist) sl = entry + maxSLDist;
        double tp = entry - 2 * (sl - entry);
        double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
        double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
        double expectedProfit = ((entry - tp) / tick_size) * tick_value * lot;
        double commission = CalculateCommissionOrSpread(lot);
        if(expectedProfit < commission) return false;
        if(OpenTrade(ORDER_TYPE_SELL, sl, tp, "SAR Reversal Sell")) {
            lastSellBar = currentBar;
            return true;
        }
    }
    return false;
}

// --- CCI Divergence Strategy ---
bool CCIDivergenceStrategySignal()
{
    int shift = 1;
    int cciPeriod = 20;
    int lookback = 10;
    double atrPeriod = 14;
    double atrHandle = iATR(_Symbol, PERIOD_CURRENT, atrPeriod);
    double atrBuffer[2];
    if(CopyBuffer(atrHandle, 0, shift, 2, atrBuffer) <= 0) { IndicatorRelease(atrHandle); return false; }
    double atr = atrBuffer[0];
    IndicatorRelease(atrHandle);
    double minATR = 10 * SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    if(atr < minATR) return false;

    // --- CCI ---
    int cciHandle = iCCI(_Symbol, PERIOD_CURRENT, cciPeriod, PRICE_TYPICAL);
    double cciBuffer[];
    ArrayResize(cciBuffer, lookback+2);
    if(CopyBuffer(cciHandle, 0, shift, lookback+2, cciBuffer) <= 0) { IndicatorRelease(cciHandle); return false; }
    IndicatorRelease(cciHandle);

    // --- Find price/CCI highs and lows ---
    double priceHigh = iHigh(_Symbol, PERIOD_CURRENT, shift);
    double priceLow = iLow(_Symbol, PERIOD_CURRENT, shift);
    double cciHigh = cciBuffer[0];
    double cciLow = cciBuffer[0];
    int priceHighIdx = shift, priceLowIdx = shift, cciHighIdx = 0, cciLowIdx = 0;
    for(int i=1; i<=lookback; i++) {
        double h = iHigh(_Symbol, PERIOD_CURRENT, shift+i);
        double l = iLow(_Symbol, PERIOD_CURRENT, shift+i);
        if(h > priceHigh) { priceHigh = h; priceHighIdx = shift+i; }
        if(l < priceLow) { priceLow = l; priceLowIdx = shift+i; }
        if(cciBuffer[i] > cciHigh) { cciHigh = cciBuffer[i]; cciHighIdx = i; }
        if(cciBuffer[i] < cciLow) { cciLow = cciBuffer[i]; cciLowIdx = i; }
    }

    double close = iClose(_Symbol, PERIOD_CURRENT, shift);
    double open = iOpen(_Symbol, PERIOD_CURRENT, shift);
    double high = iHigh(_Symbol, PERIOD_CURRENT, shift);
    double low = iLow(_Symbol, PERIOD_CURRENT, shift);
    double lot = LotSize;
    double maxSLDist = GetMaxSLDistance(lot);
    int consecutiveTradeLimit = 1;
    static int lastBuyBar = -1000, lastSellBar = -1000;
    int currentBar = Bars(_Symbol, PERIOD_CURRENT);
    long tickVolume = iVolume(_Symbol, PERIOD_CURRENT, shift);
    long avgVolume = 0;
    for(int i=shift; i<shift+lookback; i++) avgVolume += iVolume(_Symbol, PERIOD_CURRENT, i);
    avgVolume /= lookback;

    // --- Bullish divergence: price makes new low, CCI does not ---
    bool bullishDiv = (priceLowIdx == shift && cciLowIdx != 0 && cciBuffer[0] > cciBuffer[cciLowIdx]);
    // --- Bearish divergence: price makes new high, CCI does not ---
    bool bearishDiv = (priceHighIdx == shift && cciHighIdx != 0 && cciBuffer[0] < cciBuffer[cciHighIdx]);

    // --- Price action confirmation: bullish/bearish engulfing ---
    double prevClose = iClose(_Symbol, PERIOD_CURRENT, shift+1);
    double prevOpen = iOpen(_Symbol, PERIOD_CURRENT, shift+1);
    bool bullishEngulf = (close > open && prevClose < prevOpen && close > prevOpen && open < prevClose);
    bool bearishEngulf = (close < open && prevClose > prevOpen && close < prevOpen && open > prevClose);

    // --- Buy: bullish divergence, bullish engulfing, above average volume ---
    if(bullishDiv && bullishEngulf && tickVolume > avgVolume && (currentBar - lastBuyBar > consecutiveTradeLimit)) {
        double entry = close;
        double sl = low - 1.2 * atr;
        if((entry - sl) > maxSLDist) sl = entry - maxSLDist;
        double tp = entry + 2 * (entry - sl);
        double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
        double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
        double expectedProfit = ((tp - entry) / tick_size) * tick_value * lot;
        double commission = CalculateCommissionOrSpread(lot);
        if(expectedProfit < commission) return false;
        if(OpenTrade(ORDER_TYPE_BUY, sl, tp, "CCI Div Buy")) {
            lastBuyBar = currentBar;
            return true;
        }
    }
    // --- Sell: bearish divergence, bearish engulfing, above average volume ---
    if(bearishDiv && bearishEngulf && tickVolume > avgVolume && (currentBar - lastSellBar > consecutiveTradeLimit)) {
        double entry = close;
        double sl = high + 1.2 * atr;
        if((sl - entry) > maxSLDist) sl = entry + maxSLDist;
        double tp = entry - 2 * (sl - entry);
        double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
        double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
        double expectedProfit = ((entry - tp) / tick_size) * tick_value * lot;
        double commission = CalculateCommissionOrSpread(lot);
        if(expectedProfit < commission) return false;
        if(OpenTrade(ORDER_TYPE_SELL, sl, tp, "CCI Div Sell")) {
            lastSellBar = currentBar;
            return true;
        }
    }
    return false;
} 

// --- Order Block/Institutional Level Bounce Strategy ---
bool OrderBlockBounceStrategySignal()
{
    int shift = 1;
    int blockLookback = 20;
    int blockSize = 3; // Number of bars for consolidation
    double atrPeriod = 14;
    double atrHandle = iATR(_Symbol, PERIOD_CURRENT, atrPeriod);
    double atrBuffer[2];
    if(CopyBuffer(atrHandle, 0, shift, 2, atrBuffer) <= 0) { IndicatorRelease(atrHandle); return false; }
    double atr = atrBuffer[0];
    IndicatorRelease(atrHandle);
    double minATR = 10 * SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    if(atr < minATR) return false;

    // --- Find recent order block (consolidation before a strong move) ---
    double blockHigh = 0, blockLow = 0;
    int blockStart = -1;
    for(int i=shift+blockSize; i<shift+blockLookback; i++) {
        bool isConsolidation = true;
        double localHigh = iHigh(_Symbol, PERIOD_CURRENT, i);
        double localLow = iLow(_Symbol, PERIOD_CURRENT, i);
        for(int j=0; j<blockSize; j++) {
            double h = iHigh(_Symbol, PERIOD_CURRENT, i-j);
            double l = iLow(_Symbol, PERIOD_CURRENT, i-j);
            if(MathAbs(h-l) > 1.5*atr) { isConsolidation = false; break; }
            if(h > localHigh) localHigh = h;
            if(l < localLow) localLow = l;
        }
        // Check for strong move after block
        if(isConsolidation) {
            double moveBarHigh = iHigh(_Symbol, PERIOD_CURRENT, i-blockSize);
            double moveBarLow = iLow(_Symbol, PERIOD_CURRENT, i-blockSize);
            if(MathAbs(moveBarHigh-moveBarLow) > 2*atr) {
                blockHigh = localHigh;
                blockLow = localLow;
                blockStart = i;
                break;
            }
        }
    }
    if(blockStart == -1) return false;

    double close = iClose(_Symbol, PERIOD_CURRENT, shift);
    double open = iOpen(_Symbol, PERIOD_CURRENT, shift);
    double high = iHigh(_Symbol, PERIOD_CURRENT, shift);
    double low = iLow(_Symbol, PERIOD_CURRENT, shift);
    double lot = LotSize;
    double maxSLDist = GetMaxSLDistance(lot);
    int consecutiveTradeLimit = 1;
    static int lastBuyBar = -1000, lastSellBar = -1000;
    int currentBar = Bars(_Symbol, PERIOD_CURRENT);
    long tickVolume = iVolume(_Symbol, PERIOD_CURRENT, shift);
    long avgVolume = 0;
    for(int i=shift; i<shift+blockSize; i++) avgVolume += iVolume(_Symbol, PERIOD_CURRENT, i);
    avgVolume /= blockSize;

    // --- Oscillator confirmation (Stochastic) ---
    int kPeriod = 14, dPeriod = 3, slowing = 3;
    int stochHandle = iStochastic(_Symbol, PERIOD_CURRENT, kPeriod, dPeriod, slowing, MODE_SMA, 0);
    double kBuffer[2], dBuffer[2];
    if(CopyBuffer(stochHandle, 0, shift, 2, kBuffer) <= 0) { IndicatorRelease(stochHandle); return false; }
    if(CopyBuffer(stochHandle, 1, shift, 2, dBuffer) <= 0) { IndicatorRelease(stochHandle); return false; }
    IndicatorRelease(stochHandle);
    double currK = kBuffer[0], currD = dBuffer[0];

    // --- Wick rejection ---
    double upperWick = high - MathMax(open, close);
    double lowerWick = MathMin(open, close) - low;
    double body = MathAbs(close - open);

    // --- Buy: price returns to blockLow, volume spike, lower wick rejection, Stoch < 20 ---
    if(close < blockLow + 2*atr && tickVolume > 1.5*avgVolume && lowerWick > 2*body && currK < 20 && currD < 20 && (currentBar - lastBuyBar > consecutiveTradeLimit)) {
        double entry = close;
        double sl = blockLow - 1.2 * atr;
        if((entry - sl) > maxSLDist) sl = entry - maxSLDist;
        double tp = blockHigh;
        double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
        double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
        double expectedProfit = ((tp - entry) / tick_size) * tick_value * lot;
        double commission = CalculateCommissionOrSpread(lot);
        if(expectedProfit < commission) return false;
        if(OpenTrade(ORDER_TYPE_BUY, sl, tp, "OrderBlock Buy")) {
            lastBuyBar = currentBar;
            return true;
        }
    }
    // --- Sell: price returns to blockHigh, volume spike, upper wick rejection, Stoch > 80 ---
    if(close > blockHigh - 2*atr && tickVolume > 1.5*avgVolume && upperWick > 2*body && currK > 80 && currD > 80 && (currentBar - lastSellBar > consecutiveTradeLimit)) {
        double entry = close;
        double sl = blockHigh + 1.2 * atr;
        if((sl - entry) > maxSLDist) sl = entry + maxSLDist;
        double tp = blockLow;
        double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
        double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
        double expectedProfit = ((entry - tp) / tick_size) * tick_value * lot;
        double commission = CalculateCommissionOrSpread(lot);
        if(expectedProfit < commission) return false;
        if(OpenTrade(ORDER_TYPE_SELL, sl, tp, "OrderBlock Sell")) {
            lastSellBar = currentBar;
            return true;
        }
    }
    return false;
}