// --- Strategy function prototypes ---
bool BreakoutStrategySignal(double &sl, double &tp, string &comment, int &orderType);
bool PullbackScalpingStrategySignal(double &sl, double &tp, string &comment, int &orderType);
bool TrendMACrossStrategySignal(double &sl, double &tp, string &comment, int &orderType);
void CheckEntryConditions()
{
    if(!IsTradingAllowed()) return;
    if(!IsBelowMaxOpenTrades()) return;
    static datetime lastTradeBarTime = 0;
    datetime currentBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);
    if(currentBarTime == lastTradeBarTime) return;
    lastTradeBarTime = currentBarTime;
    // --- Strategy loop ---
    double sl = 0, tp = 0;
    string comment = "";
    int orderType = -1;
    if(BreakoutStrategySignal(sl, tp, comment, orderType)) {
        OpenTrade((ENUM_ORDER_TYPE)orderType, sl, tp, comment);
        return;
    }
    if(PullbackScalpingStrategySignal(sl, tp, comment, orderType)) {
        OpenTrade((ENUM_ORDER_TYPE)orderType, sl, tp, comment);
        return;
    }
    if(TrendMACrossStrategySignal(sl, tp, comment, orderType)) {
        OpenTrade((ENUM_ORDER_TYPE)orderType, sl, tp, comment);
        return;
    }
}

// --- Breakout Scalping Strategy ---
bool BreakoutStrategySignal(double &sl, double &tp, string &comment, int &orderType)
{
    int rangeBars = 10;
    double atrThreshold = 30 * SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    // --- ATR ---
    int atrHandle = iATR(_Symbol, PERIOD_CURRENT, rangeBars);
    double atrBuffer[1];
    if(CopyBuffer(atrHandle, 0, 1, 1, atrBuffer) <= 0) { IndicatorRelease(atrHandle); return false; }
    double atr = atrBuffer[0];
    IndicatorRelease(atrHandle);
    double buffer = 0.5 * atr;
    // --- Range ---
    double rangeHigh = iHigh(_Symbol, PERIOD_CURRENT, 1);
    double rangeLow = iLow(_Symbol, PERIOD_CURRENT, 1);
    for(int i=2; i<=rangeBars; i++) {
        double h = iHigh(_Symbol, PERIOD_CURRENT, i);
        double l = iLow(_Symbol, PERIOD_CURRENT, i);
        if(h > rangeHigh) rangeHigh = h;
        if(l < rangeLow) rangeLow = l;
    }
    if(atr < atrThreshold) return false;
    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    // --- RSI ---
    int rsiHandle = iRSI(_Symbol, PERIOD_CURRENT, 14, PRICE_CLOSE);
    double rsiBuffer[1];
    if(CopyBuffer(rsiHandle, 0, 1, 1, rsiBuffer) <= 0) { IndicatorRelease(rsiHandle); return false; }
    double rsi = rsiBuffer[0];
    IndicatorRelease(rsiHandle);
    // Buy breakout
    if(ask > rangeHigh + buffer && rsi > 55) {
        sl = rangeLow;
        tp = rangeHigh + (rangeHigh - rangeLow);
        comment = "Breakout Buy";
        orderType = ORDER_TYPE_BUY;
        return true;
    }
    // Sell breakout
    if(bid < rangeLow - buffer && rsi < 45) {
        sl = rangeHigh;
        tp = rangeLow - (rangeHigh - rangeLow);
        comment = "Breakout Sell";
        orderType = ORDER_TYPE_SELL;
        return true;
    }
    return false;
}

// --- Pullback Scalping Strategy ---
bool PullbackScalpingStrategySignal(double &sl, double &tp, string &comment, int &orderType)
{
    int emaFastPeriod = 20;
    int emaSlowPeriod = 50;
    int shift = 1; // previous closed bar
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
    double close = iClose(_Symbol, PERIOD_CURRENT, shift);
    double open = iOpen(_Symbol, PERIOD_CURRENT, shift);
    double high = iHigh(_Symbol, PERIOD_CURRENT, shift);
    double low = iLow(_Symbol, PERIOD_CURRENT, shift);
    double prevClose = iClose(_Symbol, PERIOD_CURRENT, shift+1);
    double prevOpen = iOpen(_Symbol, PERIOD_CURRENT, shift+1);
    double prevHigh = iHigh(_Symbol, PERIOD_CURRENT, shift+1);
    double prevLow = iLow(_Symbol, PERIOD_CURRENT, shift+1);
    double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    // --- Uptrend: EMA20 > EMA50 ---
    if(prevEmaFast > prevEmaSlow) {
        // Pullback: price at or below EMA20
        if(close <= prevEmaFast + 2*point) {
            // Pin bar: long lower wick
            double body = MathAbs(close - open);
            double lowerWick = MathMin(open, close) - low;
            double upperWick = high - MathMax(open, close);
            if(lowerWick > 2*body && lowerWick > upperWick) {
                sl = low - 2*point;
                tp = close + (close - sl) * 1.5;
                comment = "Pullback PinBar Buy";
                orderType = ORDER_TYPE_BUY;
                return true;
            }
            // Bullish engulfing
            if(close > open && prevClose < prevOpen && close > prevOpen && open < prevClose) {
                sl = low - 2*point;
                tp = close + (close - sl) * 1.5;
                comment = "Pullback Engulf Buy";
                orderType = ORDER_TYPE_BUY;
                return true;
            }
        }
    }
    // --- Downtrend: EMA20 < EMA50 ---
    if(prevEmaFast < prevEmaSlow) {
        // Pullback: price at or above EMA20
        if(close >= prevEmaFast - 2*point) {
            // Pin bar: long upper wick
            double body = MathAbs(close - open);
            double upperWick = high - MathMax(open, close);
            double lowerWick = MathMin(open, close) - low;
            if(upperWick > 2*body && upperWick > lowerWick) {
                sl = high + 2*point;
                tp = close - (sl - close) * 1.5;
                comment = "Pullback PinBar Sell";
                orderType = ORDER_TYPE_SELL;
                return true;
            }
            // Bearish engulfing
            if(close < open && prevClose > prevOpen && close < prevOpen && open > prevClose) {
                sl = high + 2*point;
                tp = close - (sl - close) * 1.5;
                comment = "Pullback Engulf Sell";
                orderType = ORDER_TYPE_SELL;
                return true;
            }
        }
    }
    return false;
}

// --- Trend-Following MA Cross Strategy ---
bool TrendMACrossStrategySignal(double &sl, double &tp, string &comment, int &orderType)
{
    int fastMAPeriod = 9, slowMAPeriod = 21, shift = 1;
    // --- M5 EMA handles ---
    int fastMAHandle = iMA(_Symbol, PERIOD_CURRENT, fastMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
    int slowMAHandle = iMA(_Symbol, PERIOD_CURRENT, slowMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
    double fastMA[2], slowMA[2];
    if(CopyBuffer(fastMAHandle, 0, shift, 2, fastMA) <= 0) { IndicatorRelease(fastMAHandle); IndicatorRelease(slowMAHandle); return false; }
    if(CopyBuffer(slowMAHandle, 0, shift, 2, slowMA) <= 0) { IndicatorRelease(fastMAHandle); IndicatorRelease(slowMAHandle); return false; }
    IndicatorRelease(fastMAHandle); IndicatorRelease(slowMAHandle);
    double prevFast = fastMA[1], prevSlow = slowMA[1];
    double currFast = fastMA[0], currSlow = slowMA[0];
    // --- Cross detection ---
    bool crossUp = (prevFast <= prevSlow && currFast > currSlow);
    bool crossDown = (prevFast >= prevSlow && currFast < currSlow);
    // --- RSI confirmation ---
    int rsiHandle = iRSI(_Symbol, PERIOD_CURRENT, 14, PRICE_CLOSE);
    double rsiBuffer[1];
    if(CopyBuffer(rsiHandle, 0, 1, 1, rsiBuffer) <= 0) { IndicatorRelease(rsiHandle); return false; }
    double rsi = rsiBuffer[0];
    IndicatorRelease(rsiHandle);
    // --- MACD confirmation ---
    int macdHandle = iMACD(_Symbol, PERIOD_CURRENT, 12, 26, 9, PRICE_CLOSE);
    double macdMain[1], macdSignal[1];
    if(CopyBuffer(macdHandle, 0, 1, 1, macdMain) <= 0) { IndicatorRelease(macdHandle); return false; }
    if(CopyBuffer(macdHandle, 1, 1, 1, macdSignal) <= 0) { IndicatorRelease(macdHandle); return false; }
    double macd = macdMain[0];
    IndicatorRelease(macdHandle);
    // --- Higher timeframe (H1) filter ---
    int fastMAH1Handle = iMA(_Symbol, PERIOD_H1, fastMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
    int slowMAH1Handle = iMA(_Symbol, PERIOD_H1, slowMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
    double fastMAH1[1], slowMAH1[1];
    if(CopyBuffer(fastMAH1Handle, 0, 1, 1, fastMAH1) <= 0) { IndicatorRelease(fastMAH1Handle); IndicatorRelease(slowMAH1Handle); return false; }
    if(CopyBuffer(slowMAH1Handle, 0, 1, 1, slowMAH1) <= 0) { IndicatorRelease(fastMAH1Handle); IndicatorRelease(slowMAH1Handle); return false; }
    IndicatorRelease(fastMAH1Handle); IndicatorRelease(slowMAH1Handle);
    double fastH1 = fastMAH1[0], slowH1 = slowMAH1[0];
    double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    // --- Buy signal ---
    if(crossUp && rsi > 55 && macd > 0 && fastH1 > slowH1) {
        // SL: recent swing low
        double slCandidate = iLow(_Symbol, PERIOD_CURRENT, shift);
        for(int i=shift+1; i<=shift+5; i++) {
            double l = iLow(_Symbol, PERIOD_CURRENT, i);
            if(l < slCandidate) slCandidate = l;
        }
        sl = slCandidate - 2*point;
        tp = currFast + 1.5 * (currFast - sl);
        comment = "MA Cross Buy";
        orderType = ORDER_TYPE_BUY;
        return true;
    }
    // --- Sell signal ---
    if(crossDown && rsi < 45 && macd < 0 && fastH1 < slowH1) {
        // SL: recent swing high
        double slCandidate = iHigh(_Symbol, PERIOD_CURRENT, shift);
        for(int i=shift+1; i<=shift+5; i++) {
            double h = iHigh(_Symbol, PERIOD_CURRENT, i);
            if(h > slCandidate) slCandidate = h;
        }
        sl = slCandidate + 2*point;
        tp = currFast - 1.5 * (sl - currFast);
        comment = "MA Cross Sell";
        orderType = ORDER_TYPE_SELL;
        return true;
    }
    return false;
} 