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
input int      MaxOpenTrades = 5;               // Maximum open trades
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
        Print("Euro M5 Scraping :- Failed to fetch commission from Exness API. WebRequest result: ", res, CharArrayToString(result));
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
    Print("Euro M5 Scalping EA initialized successfully");
    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    EventKillTimer(); // Kill the timer   
    Print("Euro M5 Scalping EA deinitialized");
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
    Print("Euro M5 Scalping EA  === NEW BAR TICK === Current time: ", formattedDateTime);

    
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
            Print("Euro M5 Scalping EA Daily limit reached. Trading stopped. Max Loss: ", MaxDailyLoss);
            return;
        }
    }
 
    // Check basic filters
    if(!CheckBasicFilters())
    {
        Print("Euro M5 Scalping EA Basic filters failed");
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
        Print("Euro M5 Scalping EA FILTER FAILED: Spread too high");
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
        Print("Euro M5 Scalping EA: Trading not allowed (daily loss or disabled)");
        return false;
    }
    if(!IsBelowMaxOpenTrades()) {
        Print("Euro M5 Scalping EA: Max open trades reached");
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
        Print("Euro M5 Scalping EA ERROR: Trading not allowed in terminal");
        return false;
    }
    
    if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
    {
        Print("Euro M5 Scalping EA ERROR: Automated trading not allowed for this EA");
        return false;
    }
    
    if(!AccountInfoInteger(ACCOUNT_TRADE_EXPERT))
    {
        Print("Euro M5 Scalping EA ERROR: Expert trading not allowed for this account");
        return false;
    }
    
    if(!SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE))
    {
        Print("Euro M5 Scalping EAERROR: Trading not allowed for this symbol");
        return false;
    }
    

    bool orderResult = OrderSend(request, result);
   
    if(orderResult)
    {
       Print("Euro M5 Scalping EA === Opened TRADE === Order Type :- ", orderType == 0 ? "Buy  " : "Sell  ","Current Price:- ",orderType == ORDER_TYPE_BUY ? askPrice : bidPrice , "  SL:-  " , stopLoss, "   " , "TP:-  " ,  takeProfit, " ", comment);
        totalTradesToday++;
        return true;
    }
    else
    {
        Print("Euro M5 Scalping EA OrderSend FAILED!  Error code: ", result.retcode,"Error description: ", result.comment, "  Order Type :- ", orderType == 0 ? "Buy  " : "Sell  ","Current Price:- ",orderType == ORDER_TYPE_BUY ? askPrice : bidPrice , "  SL:-  " , stopLoss, "   " , "TP:-  " ,  takeProfit, " ", comment);
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
    return commissionOrSpreadPer001Lot * (lot / 0.01);
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
        Print("Euro M5 Scalping EA  Closed position #", ticket, " due to: ", reason);
    }else{
        Print("Euro M5 Scalping EA Failed to close position #", ticket, " due to: ", reason, ". Error: ", result.retcode);}
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
        Print("Euro M5 Scalping EA Emergency stop: Excessive spread detected");
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

