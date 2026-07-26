//+------------------------------------------------------------------+
//|                                  EnvelopeMartingale_EA_V1.mq5      |
//|  EA de rompimento de bandas do indicador Envelopes - versao       |
//|  MARTINGALE (mesma direcao, lote crescente) em vez de hedge       |
//|                                                                    |
//|  LOGICA:                                                          |
//|  - Quando o candle FECHA acima da banda superior -> abre VENDA     |
//|  - Quando o candle FECHA abaixo da banda inferior -> abre COMPRA   |
//|                                                                    |
//|  - Enquanto so existir 1 posicao (ainda nao "escapou"), ela fecha  |
//|    pelo metodo normal: alvo dinamico (% do delta) ou toque/        |
//|    alcance da banda oposta - igual a versao com hedge.             |
//|                                                                    |
//|  - MARTINGALE: se o preco andar contra a ULTIMA posicao aberta ate |
//|    seu preco de entrada +/- (OffsetMultiplier x delta atual), o EA |
//|    NAO abre hedge - abre OUTRA posicao na MESMA direcao, com lote  |
//|    maior (lote anterior x InpMartingaleMultiplier).                |
//|  - A partir da 1a vez que isso acontece, o EA entra em modo        |
//|    martingale: para de negociar pelo metodo normal (nao abre novos |
//|    ciclos independentes) e passa a monitorar o GRUPO inteiro       |
//|    (todas as posicoes do ciclo) esperando o lucro flutuante        |
//|    combinado atingir InpMartingaleCloseProfit para fechar TUDO de  |
//|    uma vez. So entao volta a operar pelo metodo normal.            |
//|  - Cada nova "fuga" (preco contra a ultima posicao aberta pelo     |
//|    mesmo offset) repete o processo: abre mais um lance na mesma    |
//|    direcao com lote maior, ate o limite InpMaxMartingaleSteps.     |
//|    Ao atingir o limite, o EA para de adicionar posicoes e so       |
//|    aguarda o grupo bater a meta de lucro (ou o preco reverter).    |
//|                                                                    |
//|  - Sem Stop Loss. O lote cresce geometricamente a cada lance -     |
//|    RISCO ELEVADO, tipico de martingale.                            |
//|  - Um painel no grafico mostra o status do modo martingale.       |
//+------------------------------------------------------------------+
#property copyright "Gilvan"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

//--- INPUTS -----------------------------------------------------------
input group "=== Envelopes ==="
input ENUM_TIMEFRAMES InpTimeframe   = PERIOD_CURRENT; // Timeframe usado no calculo do Envelope
input int             InpEnvPeriod  = 14;              // Periodo da media movel
input ENUM_MA_METHOD  InpEnvMethod  = MODE_SMA;         // Metodo da media movel
input ENUM_APPLIED_PRICE InpEnvPrice = PRICE_CLOSE;     // Preco aplicado
input double          InpEnvDeviation = 0.10;           // Desvio percentual das bandas (%)

input group "=== Regras de Saida (fase normal, antes de escapar) ==="
input double InpTargetPercent = 85.0;   // % do DELTA para fechar a operacao (100 = banda oposta)

input group "=== Gerenciamento ==="
input double InpLotSize      = 0.10;    // Lote fixo inicial (1a posicao do ciclo)
input ulong  InpMagicNumber  = 20260727; // Numero magico
input int    InpSlippagePts  = 10;      // Slippage em pontos

input group "=== Martingale ==="
input double InpOffsetMultiplier     = 1.35;  // Offset = InpOffsetMultiplier x delta atual (gatilho para novo lance)
input double InpMartingaleMultiplier = 2.0;   // Multiplicador de lote a cada novo lance (lote anterior x este valor)
input int    InpMaxMartingaleSteps   = 4;     // Maximo de lances de martingale (alem da 1a posicao)
input double InpCommissionPerLotRoundTurn = 0.0; // Custo estimado (comissao ida+volta) por lote, em moeda da conta
input double InpMartingaleCloseProfit = 50.0; // Valor (moeda da conta) para fechar TODO o grupo quando o martingale estiver ativo

//--- GLOBAIS ------------------------------------------------------------
CTrade   trade;
int      envHandle = INVALID_HANDLE;
datetime lastBarTime = 0;

double   g_targetSell = 0.0;   // alvo dinamico para fechar venda (fase normal, antes de escapar)
double   g_targetBuy  = 0.0;   // alvo dinamico para fechar compra (fase normal, antes de escapar)
bool     g_targetsReady = false;

double   g_lastDelta = 0.0;    // delta (banda sup - banda inf) do ultimo candle fechado
double   g_lastUpper = 0.0;    // banda superior do ultimo candle fechado
double   g_lastLower = 0.0;    // banda inferior do ultimo candle fechado

bool     g_martingaleActive = false; // ja escapou pelo menos 1 vez? (grupo em andamento, metodo normal pausado)
int      g_martingaleStep   = 0;     // quantos lances alem do 1o ja foram abertos no ciclo atual
ulong    g_lastLegTicket    = 0;     // ticket da ultima posicao aberta (referencia p/ proximo gatilho)
double   g_lastLegLot       = 0.0;   // lote da ultima posicao aberta

//+------------------------------------------------------------------+
int OnInit()
{
   envHandle = iEnvelopes(_Symbol, InpTimeframe, InpEnvPeriod, 0, InpEnvMethod,
                           InpEnvPrice, InpEnvDeviation);
   if(envHandle == INVALID_HANDLE)
   {
      Print("Erro ao criar handle do Envelopes: ", GetLastError());
      return(INIT_FAILED);
   }

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippagePts);
   trade.SetTypeFillingBySymbol(_Symbol);

   g_martingaleActive = false;
   g_martingaleStep   = 0;
   g_lastLegTicket    = 0;
   g_lastLegLot       = 0.0;

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(envHandle != INVALID_HANDLE)
      IndicatorRelease(envHandle);

   Comment("");
}

//+------------------------------------------------------------------+
bool IsNewBar()
{
   datetime t = iTime(_Symbol, InpTimeframe, 0);
   if(t != lastBarTime)
   {
      lastBarTime = t;
      return(true);
   }
   return(false);
}

//+------------------------------------------------------------------+
//| Ajusta o lote aos limites/step do simbolo                        |
//+------------------------------------------------------------------+
double NormalizeLot(double lot)
{
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(step > 0)
      lot = MathRound(lot / step) * step;

   if(lot < minLot) lot = minLot;
   if(lot > maxLot) lot = maxLot;

   return(NormalizeDouble(lot, 2));
}

//+------------------------------------------------------------------+
//| Existe alguma posicao aberta deste EA no momento? So pode existir |
//| 1 ciclo por vez (posicao normal isolada OU grupo martingale)      |
//+------------------------------------------------------------------+
bool HasAnyPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      return(true);
   }
   return(false);
}

//+------------------------------------------------------------------+
//| Abre a 1a posicao de um novo ciclo (ainda fora do martingale)     |
//+------------------------------------------------------------------+
void OpenFirstLeg(ENUM_POSITION_TYPE dir)
{
   double lot = NormalizeLot(InpLotSize);
   bool   ok;

   if(dir == POSITION_TYPE_SELL)
   {
      double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      ok = trade.Sell(lot, _Symbol, price, 0, 0, "EnvMartingale Sell #0");
   }
   else
   {
      double price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      ok = trade.Buy(lot, _Symbol, price, 0, 0, "EnvMartingale Buy #0");
   }

   if(!ok) return;

   g_lastLegTicket    = trade.ResultOrder();
   g_lastLegLot       = lot;
   g_martingaleActive = false;
   g_martingaleStep   = 0;
}

//+------------------------------------------------------------------+
//| Recalcula bandas do ultimo candle fechado, atualiza alvos         |
//| dinamicos (fase normal) e verifica sinal de entrada de um novo    |
//| ciclo (somente quando nao ha nenhuma posicao aberta)              |
//+------------------------------------------------------------------+
void ProcessNewBar()
{
   double upperBuf[], lowerBuf[];
   ArraySetAsSeries(upperBuf, true);
   ArraySetAsSeries(lowerBuf, true);

   // buffer 0 = banda superior, buffer 1 = banda inferior (iEnvelopes)
   if(CopyBuffer(envHandle, 0, 1, 1, upperBuf) < 1) return;
   if(CopyBuffer(envHandle, 1, 1, 1, lowerBuf) < 1) return;

   double upper1 = upperBuf[0];
   double lower1 = lowerBuf[0];
   double close1 = iClose(_Symbol, InpTimeframe, 1);

   double delta = upper1 - lower1;
   if(delta <= 0) return;

   g_lastDelta = delta; // usado tambem pelo martingale (offset = multiplicador x delta)
   g_lastUpper = upper1;
   g_lastLower = lower1;

   g_targetSell = upper1 - (InpTargetPercent / 100.0) * delta;
   g_targetBuy  = lower1 + (InpTargetPercent / 100.0) * delta;
   g_targetsReady = true;

   // novo ciclo so pode comecar quando nao ha nenhuma posicao aberta - enquanto o
   // grupo martingale estiver em andamento (ou a 1a posicao ainda aberta), nao
   // abre nada novo por sinal de rompimento
   if(HasAnyPosition()) return;

   if(close1 > upper1)
      OpenFirstLeg(POSITION_TYPE_SELL);
   else if(close1 < lower1)
      OpenFirstLeg(POSITION_TYPE_BUY);
}

//+------------------------------------------------------------------+
//| Fecha a posicao unica pelo metodo normal (alvo dinamico ou banda) |
//| - so se aplica ENQUANTO o martingale ainda nao foi acionado       |
//+------------------------------------------------------------------+
void CheckNormalExit()
{
   if(g_martingaleActive) return; // uma vez em martingale, so fecha pelo lucro do grupo
   if(!g_targetsReady) return;
   if(g_lastLegTicket == 0) return;
   if(!PositionSelectByTicket(g_lastLegTicket)) { g_lastLegTicket = 0; g_lastLegLot = 0.0; return; }

   long   type       = PositionGetInteger(POSITION_TYPE);
   double entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   double bid        = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask        = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   bool shouldClose = false;

   if(type == POSITION_TYPE_SELL)
      shouldClose = (bid <= g_targetSell || bid <= g_lastLower || g_lastLower >= entryPrice);
   else if(type == POSITION_TYPE_BUY)
      shouldClose = (ask >= g_targetBuy || ask >= g_lastUpper || g_lastUpper <= entryPrice);

   if(shouldClose)
   {
      trade.PositionClose(g_lastLegTicket);
      g_lastLegTicket = 0;
      g_lastLegLot    = 0.0;
   }
}

//+------------------------------------------------------------------+
//| Abre mais um lance de martingale, na mesma direcao, com lote      |
//| maior (lote anterior x InpMartingaleMultiplier)                   |
//+------------------------------------------------------------------+
void OpenNextLeg(ENUM_POSITION_TYPE dir)
{
   double lot = NormalizeLot(g_lastLegLot * InpMartingaleMultiplier);
   bool   ok;

   if(dir == POSITION_TYPE_SELL)
   {
      double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      ok = trade.Sell(lot, _Symbol, price, 0, 0, StringFormat("EnvMartingale Sell #%d", g_martingaleStep + 1));
   }
   else
   {
      double price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      ok = trade.Buy(lot, _Symbol, price, 0, 0, StringFormat("EnvMartingale Buy #%d", g_martingaleStep + 1));
   }

   if(!ok) return;

   g_lastLegTicket    = trade.ResultOrder();
   g_lastLegLot       = lot;
   g_martingaleStep++;
   g_martingaleActive = true;

   Print("MARTINGALE: lance #", g_martingaleStep, " aberto, lote ", DoubleToString(lot, 2));
}

//+------------------------------------------------------------------+
//| A cada tick, olha a ULTIMA posicao aberta do ciclo. Se o preco    |
//| andou contra ela ate seu preco de entrada +/- offset (multipli-   |
//| cador x delta atual), abre mais um lance na mesma direcao com     |
//| lote maior - ate o limite InpMaxMartingaleSteps.                  |
//+------------------------------------------------------------------+
void CheckMartingaleTrigger()
{
   if(g_lastDelta <= 0) return;
   if(g_lastLegTicket == 0) return;
   if(!PositionSelectByTicket(g_lastLegTicket)) { g_lastLegTicket = 0; g_lastLegLot = 0.0; return; }

   long   type       = PositionGetInteger(POSITION_TYPE);
   double entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   double offsetUnit = InpOffsetMultiplier * g_lastDelta;
   bool   breached    = false;

   if(type == POSITION_TYPE_SELL)
   {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      breached = (bid >= entryPrice + offsetUnit);
   }
   else
   {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      breached = (ask <= entryPrice - offsetUnit);
   }

   if(!breached) return;

   if(g_martingaleStep >= InpMaxMartingaleSteps)
      return; // limite de lances atingido - nao abre mais, so aguarda a meta do grupo (ou reversao)

   OpenNextLeg((ENUM_POSITION_TYPE)type);
}

//+------------------------------------------------------------------+
//| Enquanto o martingale estiver ativo, soma o resultado flutuante   |
//| (lucro + swap - comissao estimada) de TODAS as posicoes do grupo. |
//| Quando atingir InpMartingaleCloseProfit, fecha tudo de uma vez e   |
//| libera o EA para iniciar um novo ciclo normal.                    |
//+------------------------------------------------------------------+
void CheckGroupExit()
{
   if(!g_martingaleActive) return;

   double total     = 0.0;
   double totalLots = 0.0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;

      total     += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      totalLots += PositionGetDouble(POSITION_VOLUME);
   }

   total -= totalLots * InpCommissionPerLotRoundTurn;

   if(total >= InpMartingaleCloseProfit)
      CloseGroup();
}

//+------------------------------------------------------------------+
//| Fecha todas as posicoes do ciclo atual (grupo martingale) e reseta|
//| o estado, liberando o EA para um novo ciclo pelo metodo normal    |
//+------------------------------------------------------------------+
void CloseGroup()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;

      trade.PositionClose(ticket);
   }

   g_martingaleActive = false;
   g_martingaleStep   = 0;
   g_lastLegTicket    = 0;
   g_lastLegLot       = 0.0;

   Print("MARTINGALE: meta atingida -> grupo inteiro fechado");
}

//+------------------------------------------------------------------+
//| Monta e exibe o painel de status no grafico                       |
//+------------------------------------------------------------------+
void UpdatePanel()
{
   int    posCount   = 0;
   double totalFloat = 0.0;
   double totalLots  = 0.0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;

      posCount++;
      totalFloat += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      totalLots  += PositionGetDouble(POSITION_VOLUME);
   }

   double totalNet = totalFloat - totalLots * InpCommissionPerLotRoundTurn;

   string txt = "\n\n"; // espaco para nao sobrepor a barra de cotacao nativa do MT5 (topo do grafico)
   txt += "=== Envelope Martingale EA ===\n";
   txt += "Modo Martingale: " + (g_martingaleActive ? "ATIVO" : "inativo") + "\n";
   txt += "Lances: " + IntegerToString(g_martingaleStep) + " / " + IntegerToString(InpMaxMartingaleSteps) + "\n";
   txt += "Posicoes no ciclo: " + IntegerToString(posCount) + "\n";
   txt += "Lote do ultimo lance: " + DoubleToString(g_lastLegLot, 2) + "\n";
   txt += "Valor flutuante bruto: " + DoubleToString(totalFloat, 2) + "\n";
   txt += "Valor flutuante liquido (c/ custo estimado): " + DoubleToString(totalNet, 2) + "\n";
   if(g_martingaleActive)
      txt += "Meta para fechar o grupo: " + DoubleToString(InpMartingaleCloseProfit, 2) + "\n";

   if(g_lastLegTicket != 0 && PositionSelectByTicket(g_lastLegTicket))
   {
      double entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      long   type       = PositionGetInteger(POSITION_TYPE);
      double offsetUnit = InpOffsetMultiplier * g_lastDelta;
      double nextLevel  = (type == POSITION_TYPE_SELL) ? entryPrice + offsetUnit : entryPrice - offsetUnit;

      if(g_martingaleStep < InpMaxMartingaleSteps)
         txt += "Proximo lance em: " + DoubleToString(nextLevel, _Digits) + "\n";
      else
         txt += "Limite de lances atingido - aguardando meta ou reversao\n";
   }

   Comment(txt);
}

//+------------------------------------------------------------------+
void OnTick()
{
   if(IsNewBar())
      ProcessNewBar();

   CheckNormalExit();
   CheckMartingaleTrigger();
   CheckGroupExit();

   UpdatePanel();
}
//+------------------------------------------------------------------+
