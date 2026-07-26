//+------------------------------------------------------------------+
//|                                         EnvelopeBreakout_EA.mq5   |
//|  EA de rompimento de bandas do indicador Envelopes                |
//|                                                                    |
//|  LOGICA:                                                          |
//|  - Quando o candle FECHA acima da banda superior -> abre VENDA     |
//|  - Quando o candle FECHA abaixo da banda inferior -> abre COMPRA   |
//|                                                                    |
//|  - O alvo de saida e X% da distancia DELTA (banda sup - banda inf) |
//|    Ex: TargetPercent = 85 -> fecha quando o preco percorrer 85%    |
//|    do caminho da banda de entrada ate a banda oposta.              |
//|    Se TargetPercent = 100 -> fecha exatamente na banda oposta.     |
//|                                                                    |
//|  - O alvo e DINAMICO: recalculado a cada novo candle, conforme as  |
//|    bandas do Envelope se movem (nao fica travado no valor de       |
//|    entrada).                                                       |
//|                                                                    |
//|  - Sem Stop Loss.                                                  |
//|  - Lote fixo (input).                                              |
//|  - Apenas 1 ordem aberta por vez (novo sinal e ignorado enquanto   |
//|    ja houver posicao aberta).                                      |
//|                                                                    |
//|  MODO SEGURANCA (hedge de recuperacao, por CONJUNTOS independentes)|
//|  - Toda vez que a posicao normal ATIVA no momento (a que nao foi   |
//|    absorvida ainda) tiver o preco andando contra ela ate seu       |
//|    preco de entrada +/- (OffsetMultiplier x delta_atual), ela e    |
//|    ABSORVIDA para dentro de um novo conjunto de seguranca: sai da  |
//|    rotina normal (nao fecha mais pelo alvo nem pela banda) e uma   |
//|    posicao de defesa (oposta) e aberta para formar o par daquele   |
//|    conjunto.                                                       |
//|  - Um novo ciclo normal de compra/venda comeca em seguida. Se essa |
//|    nova posicao tambem escapar do offset, forma-se OUTRO conjunto  |
//|    de seguranca independente (novo par absorvida+defesa) - podem   |
//|    existir varios conjuntos simultaneos.                           |
//|  - Posicoes absorvidas e de defesa NUNCA sao fechadas individual-  |
//|    mente - ficam abertas protegendo o valor em aberto.             |
//|  - A cada tick soma-se o resultado flutuante (lucro + swap -       |
//|    comissao estimada) de TODAS as posicoes do EA (normais, ativas  |
//|    ou absorvidas, + defesa). Quando essa soma atingir o valor      |
//|    InpSafetyCloseProfit (definido pelo usuario, em moeda da        |
//|    conta), fecha TUDO de uma vez e desativa o modo seguranca.       |
//|                                                                    |
//|  BACKSTOP DE BANDA (rotina normal):                                |
//|  - Uma venda ativa (nao absorvida) fecha se o preco tocar a banda  |
//|    inferior atual, mesmo que de prejuizo (as bandas sao dinamicas  |
//|    e podem ter se deslocado desde a entrada). Idem para compra     |
//|    tocando a banda superior.                                       |
//|                                                                    |
//|  - Um painel no grafico mostra o status do modo seguranca.         |
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

input group "=== Regras de Saida ==="
input double InpTargetPercent = 85.0;   // % do DELTA para fechar a operacao (100 = banda oposta)

input group "=== Gerenciamento ==="
input double InpLotSize      = 0.10;    // Lote fixo
input ulong  InpMagicNumber  = 20260725; // Numero magico
input int    InpSlippagePts  = 10;      // Slippage em pontos

input group "=== Modo Seguranca (Hedge) ==="
input double InpOffsetMultiplier = 1.35;   // Offset = InpOffsetMultiplier x delta atual
input double InpHedgeLot          = 0.10;  // Lote da posicao de defesa
input ulong  InpHedgeMagicNumber  = 20260726; // Numero magico da posicao de defesa
input double InpCommissionPerLotRoundTurn = 0.0; // Custo estimado (comissao ida+volta) por lote, em moeda da conta
input double InpSafetyCloseProfit = 50.0;  // Valor (moeda da conta) para fechar TUDO quando o modo seguranca estiver ativo

input group "=== Protecao / Limites (anti-blowup) ==="
input int    InpMaxSafetySets    = 2;      // Maximo de conjuntos de seguranca simultaneos permitidos
input double InpMaxFloatingLoss  = 200.0;  // Perda maxima total (moeda da conta) -> fecha TUDO em emergencia (0 = desativado)

//--- GLOBAIS ------------------------------------------------------------
CTrade   trade;
int      envHandle = INVALID_HANDLE;
datetime lastBarTime = 0;

double   g_targetSell = 0.0;   // alvo dinamico para fechar vendas
double   g_targetBuy  = 0.0;   // alvo dinamico para fechar compras
bool     g_targetsReady = false;

double   g_lastDelta = 0.0;    // delta (banda sup - banda inf) do ultimo candle fechado
double   g_lastUpper = 0.0;    // banda superior do ultimo candle fechado
double   g_lastLower = 0.0;    // banda inferior do ultimo candle fechado
bool     g_safetyActive = false; // modo seguranca ativo? (existe pelo menos 1 conjunto aberto)

int      g_setCount = 0;             // quantos conjuntos de seguranca (par absorvida+defesa) ja foram formados
ulong    g_absorbedTickets[];        // tickets de posicoes normais absorvidas pelo modo seguranca

double   g_safetyRealizedProfit = 0.0; // lucro liquido ja realizado (fechamentos normais) durante o modo seguranca ativo

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

   g_safetyActive = false;
   g_setCount = 0;
   g_safetyRealizedProfit = 0.0;
   ArrayResize(g_absorbedTickets, 0);

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
//| Recalcula bandas do ultimo candle fechado, atualiza alvos         |
//| dinamicos e verifica sinais de entrada                            |
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

   g_lastDelta = delta; // usado tambem pelo modo seguranca (offset = multiplicador x delta)
   g_lastUpper = upper1;
   g_lastLower = lower1;

   // --- atualiza alvos dinamicos (recalculados a cada novo candle) ---
   g_targetSell = upper1 - (InpTargetPercent / 100.0) * delta;
   g_targetBuy  = lower1 + (InpTargetPercent / 100.0) * delta;
   g_targetsReady = true;

   // --- sinais de entrada baseados no fechamento do candle anterior ---
   if(HasOpenPosition()) return; // apenas 1 ordem por vez (posicoes normais)

   // trava anti-blowup: ja atingiu o teto de conjuntos de seguranca simultaneos?
   // nao abre novo ciclo normal ate o modo seguranca ser resolvido (fechar tudo)
   if(g_safetyActive && g_setCount >= InpMaxSafetySets) return;

   if(close1 > upper1)
   {
      OpenSell();
   }
   else if(close1 < lower1)
   {
      OpenBuy();
   }
}

//+------------------------------------------------------------------+
//| Controle de posicoes normais absorvidas pelo modo seguranca       |
//+------------------------------------------------------------------+
bool IsAbsorbed(ulong ticket)
{
   int n = ArraySize(g_absorbedTickets);
   for(int i = 0; i < n; i++)
      if(g_absorbedTickets[i] == ticket) return(true);
   return(false);
}

void AddAbsorbed(ulong ticket)
{
   int n = ArraySize(g_absorbedTickets);
   ArrayResize(g_absorbedTickets, n + 1);
   g_absorbedTickets[n] = ticket;
}

void ClearAbsorbed()
{
   ArrayResize(g_absorbedTickets, 0);
}

//+------------------------------------------------------------------+
//| Verifica se ja existe alguma posicao normal ATIVA (nao absorvida) |
//| aberta por este EA - usada para a regra de 1 ordem por vez        |
//+------------------------------------------------------------------+
bool HasOpenPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      if(IsAbsorbed(ticket)) continue; // posicao absorvida nao conta mais como "em aberto" pro ciclo normal
      return(true);
   }
   return(false);
}

//+------------------------------------------------------------------+
void OpenSell()
{
   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   trade.Sell(InpLotSize, _Symbol, price, 0, 0, "EnvBreakout Sell");
}

//+------------------------------------------------------------------+
void OpenBuy()
{
   double price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   trade.Buy(InpLotSize, _Symbol, price, 0, 0, "EnvBreakout Buy");
}

//+------------------------------------------------------------------+
//| Fecha uma posicao normal e, se o modo seguranca estiver ativo no  |
//| momento, acumula o lucro liquido realizado (lucro + swap - custo  |
//| estimado) para que ele seja somado ao valor flutuante total ao    |
//| avaliar a meta InpSafetyCloseProfit - o lucro de ciclos normais   |
//| que vao fechando durante o modo seguranca nao pode "sumir" so     |
//| porque a posicao deixou de existir.                               |
//+------------------------------------------------------------------+
void CloseNormalPosition(ulong ticket)
{
   bool wasSafetyActive = g_safetyActive;

   if(!trade.PositionClose(ticket)) return;

   if(!wasSafetyActive) return;

   ulong dealTicket = trade.ResultDeal();
   if(dealTicket == 0 || !HistoryDealSelect(dealTicket)) return;

   double profit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
   double swap   = HistoryDealGetDouble(dealTicket, DEAL_SWAP);
   double volume = HistoryDealGetDouble(dealTicket, DEAL_VOLUME);

   g_safetyRealizedProfit += profit + swap - volume * InpCommissionPerLotRoundTurn;
}

//+------------------------------------------------------------------+
//| Verifica as posicoes normais ATIVAS (nao absorvidas) e fecha as   |
//| que atingiram o alvo dinamico, tocaram a banda oposta, OU cujo    |
//| preco de entrada foi "alcancado" pela banda (a banda se deslocou  |
//| ate ultrapassar o preco de entrada - pode fechar no prejuizo)     |
//+------------------------------------------------------------------+
void CheckExits()
{
   if(!g_targetsReady) return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      if(IsAbsorbed(ticket)) continue; // posicao absorvida pelo modo seguranca nao fecha aqui

      long   type       = PositionGetInteger(POSITION_TYPE);
      double entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);

      if(type == POSITION_TYPE_SELL)
      {
         // fecha se: alvo dinamico atingido, OU preco tocou a banda inferior atual,
         // OU a banda inferior subiu e alcancou/ultrapassou o preco de entrada da venda
         if(bid <= g_targetSell || bid <= g_lastLower || g_lastLower >= entryPrice)
            CloseNormalPosition(ticket);
      }
      else if(type == POSITION_TYPE_BUY)
      {
         // fecha se: alvo dinamico atingido, OU preco tocou a banda superior atual,
         // OU a banda superior desceu e alcancou/ultrapassou o preco de entrada da compra
         if(ask >= g_targetBuy || ask >= g_lastUpper || g_lastUpper <= entryPrice)
            CloseNormalPosition(ticket);
      }
   }
}

//+------------------------------------------------------------------+
//| Retorna a posicao normal ATIVA (nao absorvida) aberta no momento, |
//| se houver (so pode existir 1, pela regra de 1 ordem por vez)      |
//+------------------------------------------------------------------+
bool GetNormalPosition(ulong &ticketOut, double &entryPrice, ENUM_POSITION_TYPE &type)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      if(IsAbsorbed(ticket)) continue;

      ticketOut  = ticket;
      entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      type       = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      return(true);
   }
   return(false);
}

//+------------------------------------------------------------------+
//| Abre a posicao de defesa (oposta) de um novo conjunto de          |
//| seguranca. Esta posicao NUNCA e fechada individualmente.          |
//+------------------------------------------------------------------+
void OpenHedgePosition(ENUM_POSITION_TYPE hedgeType)
{
   trade.SetExpertMagicNumber(InpHedgeMagicNumber);

   string cmt = StringFormat("EnvBreakout Hedge Set #%d", g_setCount + 1);

   if(hedgeType == POSITION_TYPE_BUY)
   {
      double price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      trade.Buy(InpHedgeLot, _Symbol, price, 0, 0, cmt);
   }
   else
   {
      double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      trade.Sell(InpHedgeLot, _Symbol, price, 0, 0, cmt);
   }

   trade.SetExpertMagicNumber(InpMagicNumber);
}

void CloseAllSafetyPositions(); // forward declaration (definida mais abaixo)

//+------------------------------------------------------------------+
//| A cada tick, olha a posicao normal ATIVA no momento (se houver).  |
//| Se o preco andou contra ela ate seu preco de entrada +/- offset   |
//| (multiplicador x delta atual), ela e ABSORVIDA (sai da rotina     |
//| normal definitivamente) e forma-se um NOVO conjunto de seguranca: |
//| a posicao absorvida + uma posicao de defesa recem-aberta.         |
//| Isso pode se repetir varias vezes, cada vez formando um conjunto  |
//| independente, ate o limite InpMaxSafetySets.                      |
//+------------------------------------------------------------------+
void CheckSafetyTrigger()
{
   if(g_lastDelta <= 0) return;

   ulong ticket;
   double entryPrice;
   ENUM_POSITION_TYPE type;
   if(!GetNormalPosition(ticket, entryPrice, type)) return; // nenhuma posicao normal ativa no momento

   double offsetUnit = InpOffsetMultiplier * g_lastDelta;
   bool   breached = false;

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

   // trava anti-blowup: essa posicao normal (aberta antes da pausa de novas entradas
   // valer) tambem rompeu o offset, mas o teto de conjuntos ja foi atingido - em vez
   // de formar mais um conjunto sem controle, fecha TUDO agora (de-risk imediato)
   if(g_setCount >= InpMaxSafetySets)
   {
      Print("MODO SEGURANCA: limite de ", InpMaxSafetySets, " conjunto(s) atingido -> fechando tudo para nao formar novo conjunto");
      CloseAllSafetyPositions();
      return;
   }

   // absorve a posicao normal atual para dentro de um novo conjunto de seguranca
   AddAbsorbed(ticket);

   ENUM_POSITION_TYPE hedgeType = (type == POSITION_TYPE_SELL) ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
   OpenHedgePosition(hedgeType);

   g_setCount++;
   g_safetyActive = true;

   Print("MODO SEGURANCA: novo conjunto #", g_setCount, " formado (posicao #", ticket, " absorvida + defesa aberta)");
}

//+------------------------------------------------------------------+
//| Fecha todas as posicoes do EA (normal + hedge) e desativa o modo  |
//+------------------------------------------------------------------+
void CloseAllSafetyPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      ulong magic = (ulong)PositionGetInteger(POSITION_MAGIC);
      if(magic != InpMagicNumber && magic != InpHedgeMagicNumber) continue;

      trade.PositionClose(ticket);
   }

   g_safetyActive = false;
   g_setCount     = 0;
   g_safetyRealizedProfit = 0.0;
   ClearAbsorbed();
   Print("MODO SEGURANCA: meta atingida -> todas as posicoes fechadas");
}

//+------------------------------------------------------------------+
//| Enquanto o modo seguranca estiver ativo, soma o resultado         |
//| flutuante (lucro + swap - comissao estimada) de todas as          |
//| posicoes do EA (normais, absorvidas ou nao, + defesa). Quando     |
//| atingir InpSafetyCloseProfit, fecha tudo.                         |
//+------------------------------------------------------------------+
void CheckSafetyExit()
{
   if(!g_safetyActive) return;

   double total = 0.0;
   double totalLots = 0.0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      ulong magic = (ulong)PositionGetInteger(POSITION_MAGIC);
      if(magic != InpMagicNumber && magic != InpHedgeMagicNumber) continue;

      total     += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      totalLots += PositionGetDouble(POSITION_VOLUME);
   }

   // custo estimado de comissao (ida+volta) de todas as posicoes envolvidas
   total -= totalLots * InpCommissionPerLotRoundTurn;

   // soma o lucro liquido ja realizado por ciclos normais fechados durante o modo seguranca -
   // esse valor nao pode ser perdido so porque a posicao que o gerou ja foi encerrada
   total += g_safetyRealizedProfit;

   if(total >= InpSafetyCloseProfit)
   {
      CloseAllSafetyPositions();
      return;
   }

   // circuit breaker: perda maxima total atingida -> fecha tudo em emergencia,
   // mesmo sem bater a meta de lucro (protege a conta de um blowup)
   if(InpMaxFloatingLoss > 0.0 && total <= -InpMaxFloatingLoss)
   {
      Print("MODO SEGURANCA: perda maxima de ", DoubleToString(InpMaxFloatingLoss, 2), " atingida -> fechando tudo em emergencia");
      CloseAllSafetyPositions();
   }
}

//+------------------------------------------------------------------+
//| Monta e exibe o painel de status no grafico                       |
//+------------------------------------------------------------------+
void UpdatePanel()
{
   int    activeNormalCount   = 0; // posicoes normais ATIVAS (nao absorvidas)
   int    absorbedCount       = ArraySize(g_absorbedTickets);
   int    hedgeCount          = 0;
   double totalFloat          = 0.0;
   double totalLots           = 0.0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      ulong magic = (ulong)PositionGetInteger(POSITION_MAGIC);
      if(magic == InpMagicNumber)
      {
         if(!IsAbsorbed(ticket)) activeNormalCount++;
      }
      else if(magic == InpHedgeMagicNumber)
      {
         hedgeCount++;
      }
      else
      {
         continue;
      }

      totalFloat += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      totalLots  += PositionGetDouble(POSITION_VOLUME);
   }

   double totalNet     = totalFloat - totalLots * InpCommissionPerLotRoundTurn;
   double totalWithReal = totalNet + g_safetyRealizedProfit;

   string txt = "\n\n"; // espaco para nao sobrepor a barra de cotacao nativa do MT5 (topo do grafico)
   txt += "=== Envelope Breakout EA ===\n";
   txt += "Modo Seguranca: " + (g_safetyActive ? "ATIVO" : "inativo") + "\n";
   txt += "Conjuntos de seguranca: " + IntegerToString(g_setCount) + " / " + IntegerToString(InpMaxSafetySets) + "\n";
   txt += "Posicoes normais ativas: " + IntegerToString(activeNormalCount) + "\n";
   txt += "Posicoes absorvidas: " + IntegerToString(absorbedCount) + "\n";
   txt += "Posicoes de defesa abertas: " + IntegerToString(hedgeCount) + "\n";
   txt += "Valor flutuante bruto: " + DoubleToString(totalFloat, 2) + "\n";
   txt += "Valor flutuante liquido (c/ custo estimado): " + DoubleToString(totalNet, 2) + "\n";
   if(g_safetyActive)
   {
      txt += "Lucro ja realizado no modo seguranca: " + DoubleToString(g_safetyRealizedProfit, 2) + "\n";
      txt += "Total considerado para a meta: " + DoubleToString(totalWithReal, 2) + "\n";
      txt += "Meta para fechar tudo (lucro): " + DoubleToString(InpSafetyCloseProfit, 2) + "\n";
      if(InpMaxFloatingLoss > 0.0)
         txt += "Limite de perda (emergencia): -" + DoubleToString(InpMaxFloatingLoss, 2) + "\n";
      if(g_setCount >= InpMaxSafetySets)
         txt += "AVISO: teto de conjuntos atingido - novas entradas normais pausadas\n";
   }

   // mostra o proximo nivel de gatilho, se houver posicao normal ativa no momento
   ulong  watchTicket;
   double watchEntry;
   ENUM_POSITION_TYPE watchType;
   if(g_lastDelta > 0 && GetNormalPosition(watchTicket, watchEntry, watchType))
   {
      double offsetUnit = InpOffsetMultiplier * g_lastDelta;
      double nextLevel = (watchType == POSITION_TYPE_SELL) ? watchEntry + offsetUnit : watchEntry - offsetUnit;
      txt += "Posicao normal ativa: entrada " + DoubleToString(watchEntry, _Digits) +
             " | gatilho seguranca em " + DoubleToString(nextLevel, _Digits) + "\n";
   }

   Comment(txt);
}

//+------------------------------------------------------------------+
void OnTick()
{
   if(IsNewBar())
      ProcessNewBar();

   // saida verificada a cada tick, usando o alvo dinamico mais recente
   CheckExits();

   // modo seguranca: checa formacao de novos conjuntos + verificacao de saida geral
   CheckSafetyTrigger();
   CheckSafetyExit();

   UpdatePanel();
}
//+------------------------------------------------------------------+
