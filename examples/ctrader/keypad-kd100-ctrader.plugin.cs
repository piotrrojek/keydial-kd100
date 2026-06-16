// keypad-kd100-ctrader — a cTrader Automate *Plugin* that exposes a small,
// token-authenticated local HTTP API so the Huion KD100 keypad (driven by the
// macOS `kd100` tray app, github.com/piotrrojek/keydial-kd100) can control cTrader
// directly: switch chart timeframe/symbol, scroll/zoom, place/close/modify trades,
// and read live account state.
//
// Why a Plugin (not a cBot): a Plugin is always-on (runs the whole time cTrader is
// open, no chart attachment needed) and — confirmed against the Automate API
// reference — has the full trading surface (ExecuteMarketOrder/ClosePosition/
// ModifyPosition), Account/Positions/Symbols/MarketData, the ChartManager, and
// BeginInvokeOnMainThread. So one extension can be the KD100's whole cTrader bridge.
//
// Why HTTP and not keystrokes/JSON files: the KD100 app maps each key to a shell
// command. Those commands `curl` this API. That's a real local RPC into cTrader's
// own trading engine — no synthetic keystrokes (no Accessibility grant), and it
// replaces the OtherlandSketchybarExporter disk-file export with a live `/state`
// endpoint.
//
// SECURITY (this places real orders):
//  * Binds to 127.0.0.1 only (loopback) — never reachable off the machine.
//  * Every endpoint except /ping requires the header `X-KD100-Token: <token>`.
//    The token is generated once and written to
//      ~/cAlgo/LocalStorage/keypad-kd100/token
//    (mode 600), which the KD100 shell commands read. A browser cannot set a custom
//    header on a cross-origin request without a CORS preflight (which we never
//    answer), so this also blocks local CSRF from a malicious web page.
//  * Hard MaxLot cap and one-order-per-call — a stuck key can't run away.
//  * TradingEnabled=false turns it into a read-only / chart-only pad.
//
// Endpoints (all POST unless noted; path-style so the KD100 mappings need no ?&):
//   GET  /ping                      -> {"ok":true,...}                 (no auth)
//   GET  /state                     -> full account+positions+quotes JSON
//        /chart/tf/{M1|M5|M15|M30|H1|H4|D1}
//        /chart/symbol/{NAME}
//        /chart/zoom/{in|out}
//        /chart/scroll/{back|fwd|now}
//        /order/buy[/{lots}]   ?symbol=XAUUSD&slPips=&tpPips=
//        /order/sell[/{lots}]  ?symbol=XAUUSD&slPips=&tpPips=
//        /position/flat[/{SYMBOL}]        close all (optionally filtered by symbol)
//        /position/close-last[/{SYMBOL}]  close the newest position
//        /position/breakeven[/{SYMBOL}]   move every position's SL to its entry
//
// Build/run (one-time, in the cTrader UI — cTrader compiles it itself):
//   cTrader → Automate → open this Plugin → Build → add the Plugin and Start it.
//   It logs the listen URL + token path to the Automate log on start.

using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net;
using System.Text;
using System.Threading;
using cAlgo.API;
using cAlgo.API.Internals;
// cAlgo.API also defines a `File` type that collides with System.IO.File.
using File = System.IO.File;

namespace cAlgo.Plugins
{
    [Plugin(AccessRights = AccessRights.FullAccess)]
    public class keypadkd100ctrader : Plugin
    {
        // ---- config (constants; edit + rebuild in cTrader to change) -------------
        private const string ListenPrefix   = "http://127.0.0.1:9100/";
        private const string DefaultSymbol  = "XAUUSD";
        private const double DefaultLot     = 0.01;   // lot used when /order/* gets no lot
        private const double MaxLot         = 1.0;    // hard cap: refuse any single order above this
        private const bool   TradingEnabled = true;   // false => read-only + chart-only (no orders/closes)
        private const string OrderLabel     = "kd100";

        private HttpListener _http;
        private Thread _thread;
        private string _token;
        private volatile bool _running;
        private readonly Dictionary<string, Bars> _daily = new Dictionary<string, Bars>();

        protected override void OnStart()
        {
            var dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                                   "cAlgo", "LocalStorage", "keypad-kd100");
            Directory.CreateDirectory(dir);
            var tokenPath = Path.Combine(dir, "token");
            try { if (File.Exists(tokenPath)) _token = File.ReadAllText(tokenPath).Trim(); } catch { }
            if (string.IsNullOrEmpty(_token))
            {
                _token = Guid.NewGuid().ToString("N");
                try { File.WriteAllText(tokenPath, _token); } catch (Exception e) { Print("kd100: token write failed: {0}", e.Message); }
            }

            try
            {
                _http = new HttpListener();
                _http.Prefixes.Add(ListenPrefix);
                _http.Start();
            }
            catch (Exception e)
            {
                Print("kd100: HTTP listener failed to start on {0}: {1}", ListenPrefix, e.Message);
                return;
            }

            _running = true;
            _thread = new Thread(ListenLoop) { IsBackground = true, Name = "kd100-http" };
            _thread.Start();
            Print("keypad-kd100 listening on {0}  token={1}  trading={2}", ListenPrefix, tokenPath, TradingEnabled);
        }

        protected override void OnStop()
        {
            _running = false;
            try { _http?.Stop(); _http?.Close(); } catch { }
        }

        // ---- HTTP plumbing --------------------------------------------------------

        private void ListenLoop()
        {
            while (_running)
            {
                HttpListenerContext ctx = null;
                try { ctx = _http.GetContext(); }
                catch { if (!_running) break; else continue; }
                try { Handle(ctx); }
                catch (Exception e)
                {
                    try { WriteJson(ctx, 500, Err(e.Message)); } catch { }
                }
            }
        }

        private void Handle(HttpListenerContext ctx)
        {
            var req = ctx.Request;
            var path = (req.Url.AbsolutePath ?? "/").TrimEnd('/');
            var segs = path.Split(new[] { '/' }, StringSplitOptions.RemoveEmptyEntries);

            // /ping is unauthenticated so the KD100 side can probe reachability cheaply.
            if (segs.Length == 1 && segs[0] == "ping")
            {
                WriteJson(ctx, 200, "{\"ok\":true,\"plugin\":\"keypad-kd100-ctrader\",\"trading\":" + (TradingEnabled ? "true" : "false") + "}");
                return;
            }

            // Everything else requires the shared token (see SECURITY note up top).
            var tok = req.Headers["X-KD100-Token"];
            if (string.IsNullOrEmpty(tok) || tok != _token)
            {
                WriteJson(ctx, 401, Err("bad or missing X-KD100-Token"));
                return;
            }

            if (segs.Length == 1 && segs[0] == "state")
            {
                WriteJson(ctx, 200, RunOnMain(BuildStateJson));
                return;
            }

            if (segs.Length >= 2 && segs[0] == "chart")
            {
                bool ok = RunOnMain(() => DoChart(segs[1], segs.Length >= 3 ? segs[2] : null));
                WriteJson(ctx, ok ? 200 : 400, "{\"ok\":" + (ok ? "true" : "false") + "}");
                return;
            }

            if (segs.Length >= 1 && (segs[0] == "order" || segs[0] == "position"))
            {
                if (!TradingEnabled) { WriteJson(ctx, 403, Err("trading disabled in plugin config")); return; }
                string body = RunOnMain(() => DoTrade(segs, req));
                WriteJson(ctx, body.Contains("\"ok\":true") ? 200 : 400, body);
                return;
            }

            WriteJson(ctx, 404, Err("unknown endpoint " + path));
        }

        // ---- chart actions (run on the main thread) -------------------------------

        private bool DoChart(string action, string arg)
        {
            if (!(ChartManager.ActiveFrame is ChartFrame frame)) return false;
            var chart = frame.Chart;
            switch (action)
            {
                case "tf":
                    var tf = ParseTimeFrame(arg);
                    return tf != null && chart.TryChangeTimeFrame(tf);
                case "symbol":
                    return !string.IsNullOrEmpty(arg) && chart.TryChangeTimeFrameAndSymbol(chart.TimeFrame, arg.ToUpperInvariant());
                case "zoom":
                    if (arg == "in")  { chart.ZoomLevel = Math.Min(500, chart.ZoomLevel + 5); return true; }
                    if (arg == "out") { chart.ZoomLevel = Math.Max(5,   chart.ZoomLevel - 5); return true; }
                    return false;
                case "scroll":
                    if (arg == "back") { chart.ScrollXBy(-30);   return true; }
                    if (arg == "fwd")  { chart.ScrollXBy(30);    return true; }
                    if (arg == "now")  { chart.ScrollXBy(100000); return true; } // cTrader clamps to the latest bar
                    return false;
                default:
                    return false;
            }
        }

        private static TimeFrame ParseTimeFrame(string s)
        {
            switch ((s ?? "").ToUpperInvariant())
            {
                case "M1":  return TimeFrame.Minute;
                case "M5":  return TimeFrame.Minute5;
                case "M15": return TimeFrame.Minute15;
                case "M30": return TimeFrame.Minute30;
                case "H1":  return TimeFrame.Hour;
                case "H4":  return TimeFrame.Hour4;
                case "D1":  return TimeFrame.Daily;
                default:    return null;
            }
        }

        // ---- trade actions (run on the main thread) -------------------------------

        private string DoTrade(string[] segs, HttpListenerRequest req)
        {
            var symbolName = (req.QueryString["symbol"] ?? DefaultSymbol).ToUpperInvariant();

            // /order/buy[/{lots}] | /order/sell[/{lots}]
            if (segs[0] == "order" && segs.Length >= 2 && (segs[1] == "buy" || segs[1] == "sell"))
            {
                double lots = DefaultLot;
                if (segs.Length >= 3) double.TryParse(segs[2], NumberStyles.Float, CultureInfo.InvariantCulture, out lots);
                else if (req.QueryString["lots"] != null) double.TryParse(req.QueryString["lots"], NumberStyles.Float, CultureInfo.InvariantCulture, out lots);
                if (lots <= 0 || lots > MaxLot) return Err("lots " + Num(lots) + " outside (0, " + Num(MaxLot) + "]");

                var symbol = Symbols.GetSymbol(symbolName);
                if (symbol == null) return Err("unknown symbol " + symbolName);

                double? slPips = TryPips(req.QueryString["slPips"]);
                double? tpPips = TryPips(req.QueryString["tpPips"]);
                var side = segs[1] == "buy" ? TradeType.Buy : TradeType.Sell;
                double units = symbol.NormalizeVolumeInUnits(symbol.QuantityToVolumeInUnits(lots), RoundingMode.ToNearest);

                var r = ExecuteMarketOrder(side, symbolName, units, OrderLabel, slPips, tpPips);
                if (r.IsSuccessful && r.Position != null)
                    return "{\"ok\":true,\"side\":\"" + side + "\",\"lots\":" + Num(lots)
                         + ",\"entry\":" + Num(r.Position.EntryPrice) + ",\"id\":" + r.Position.Id + "}";
                return Err("order rejected: " + r.Error);
            }

            // /position/{flat|close-last|breakeven}[/{SYMBOL}]
            if (segs[0] == "position" && segs.Length >= 2)
            {
                var what = segs[1];
                string filter = segs.Length >= 3 ? segs[2].ToUpperInvariant()
                                                 : (req.QueryString["symbol"] != null ? symbolName : null);
                var targets = Positions.Where(p => filter == null || p.SymbolName == filter).ToList();

                if (what == "flat")
                {
                    int n = 0;
                    foreach (var p in targets) { if (ClosePosition(p).IsSuccessful) n++; }
                    return "{\"ok\":true,\"closed\":" + n + "}";
                }
                if (what == "close-last")
                {
                    var last = targets.OrderByDescending(p => p.EntryTime).FirstOrDefault();
                    if (last == null) return Err("no open position" + (filter != null ? " for " + filter : ""));
                    var r = ClosePosition(last);
                    return r.IsSuccessful ? "{\"ok\":true,\"closed\":1}" : Err("close rejected: " + r.Error);
                }
                if (what == "breakeven")
                {
                    int n = 0;
                    foreach (var p in targets) { if (ModifyPosition(p, p.EntryPrice, p.TakeProfit).IsSuccessful) n++; }
                    return "{\"ok\":true,\"moved\":" + n + "}";
                }
                return Err("unknown position action " + what);
            }

            return Err("unknown trade endpoint");
        }

        private static double? TryPips(string s)
        {
            if (string.IsNullOrEmpty(s)) return null;
            return double.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out var v) ? (double?)v : null;
        }

        // ---- /state JSON (run on the main thread) ---------------------------------
        // Shape mirrors OtherlandSketchybarExporter's file so sketchybar can later
        // read this endpoint instead of the disk file with no shape change.

        private string BuildStateJson()
        {
            var groups = new Dictionary<string, SymAgg>();
            var order = new List<string>();
            foreach (var p in Positions)
            {
                var key = p.SymbolName + "|" + p.TradeType;
                if (!groups.TryGetValue(key, out var g))
                {
                    g = new SymAgg { Symbol = p.SymbolName, Side = p.TradeType.ToString() };
                    groups[key] = g; order.Add(key);
                }
                double lots = p.Quantity;
                g.Lots += lots;
                g.EntryWeighted += lots * p.EntryPrice;
                g.Pl += p.NetProfit;
                g.Count += 1;
            }

            var sym = new StringBuilder();
            bool first = true;
            foreach (var key in order)
            {
                var g = groups[key];
                double avgEntry = g.Lots > 0 ? g.EntryWeighted / g.Lots : 0;
                int digits = PriceDigits(g.Symbol);
                if (!first) sym.Append(',');
                first = false;
                sym.Append('{');
                sym.AppendFormat("\"symbol\":\"{0}\",", g.Symbol);
                sym.AppendFormat("\"side\":\"{0}\",", g.Side);
                sym.AppendFormat("\"lots\":{0},", Num(g.Lots));
                sym.AppendFormat("\"avg_entry\":{0},", avgEntry.ToString("F" + digits, CultureInfo.InvariantCulture));
                sym.AppendFormat("\"pl\":{0},", Num(g.Pl));
                sym.AppendFormat("\"positions\":{0}", g.Count);
                sym.Append('}');
            }

            var sb = new StringBuilder(512);
            sb.Append('{');
            sb.AppendFormat("\"ts\":{0},", DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
            sb.AppendFormat("\"currency\":\"{0}\",", Account.Asset.Name);
            sb.AppendFormat("\"balance\":{0},", Num(Account.Balance));
            sb.AppendFormat("\"equity\":{0},", Num(Account.Equity));
            sb.AppendFormat("\"unrealized\":{0},", Num(Account.UnrealizedNetProfit));
            sb.AppendFormat("\"margin_used\":{0},", Num(Account.Margin));
            sb.AppendFormat("\"free_margin\":{0},", Num(Account.FreeMargin));
            sb.AppendFormat("\"margin_level\":{0},", Account.MarginLevel.HasValue ? Num(Account.MarginLevel.Value) : "null");
            sb.AppendFormat("\"positions\":{0},", Positions.Count);
            sb.AppendFormat("\"symbols\":[{0}],", sym.ToString());

            sb.Append("\"quotes\":[");
            var q = Symbols.GetSymbol(DefaultSymbol);
            if (q != null)
            {
                var fmt = "F" + q.Digits;
                double dayOpen = DayOpen(DefaultSymbol);
                sb.Append('{');
                sb.AppendFormat("\"symbol\":\"{0}\",", q.Name);
                sb.AppendFormat("\"bid\":{0},", q.Bid.ToString(fmt, CultureInfo.InvariantCulture));
                sb.AppendFormat("\"ask\":{0},", q.Ask.ToString(fmt, CultureInfo.InvariantCulture));
                sb.AppendFormat("\"digits\":{0},", q.Digits);
                sb.AppendFormat("\"day_open\":{0}", dayOpen.ToString(fmt, CultureInfo.InvariantCulture));
                sb.Append('}');
            }
            sb.Append("]}");
            return sb.ToString();
        }

        private double DayOpen(string symbolName)
        {
            try
            {
                if (!_daily.TryGetValue(symbolName, out var bars))
                {
                    bars = MarketData.GetBars(TimeFrame.Daily, symbolName);
                    _daily[symbolName] = bars;
                }
                if (bars != null && bars.Count > 0) return bars.LastBar.Open;
            }
            catch { }
            return 0;
        }

        private int PriceDigits(string symbolName)
        {
            try { return Symbols.GetSymbol(symbolName).Digits; }
            catch { return 2; }
        }

        // ---- main-thread marshaling ----------------------------------------------
        // cTrader trading/chart/account calls must run on the plugin's main thread.
        // The HTTP worker thread hands work to it and blocks for the result.

        private T RunOnMain<T>(Func<T> f)
        {
            T result = default(T);
            Exception err = null;
            using (var done = new ManualResetEventSlim(false))
            {
                BeginInvokeOnMainThread(() =>
                {
                    try { result = f(); } catch (Exception e) { err = e; } finally { done.Set(); }
                });
                if (!done.Wait(TimeSpan.FromSeconds(10))) throw new TimeoutException("cTrader main-thread op timed out");
            }
            if (err != null) throw err;
            return result;
        }

        // ---- tiny JSON helpers ----------------------------------------------------

        private static void WriteJson(HttpListenerContext ctx, int status, string body)
        {
            var bytes = Encoding.UTF8.GetBytes(body);
            ctx.Response.StatusCode = status;
            ctx.Response.ContentType = "application/json";
            ctx.Response.ContentLength64 = bytes.Length;
            ctx.Response.OutputStream.Write(bytes, 0, bytes.Length);
            ctx.Response.OutputStream.Close();
        }

        private static string Esc(string s) => (s ?? "").Replace("\\", "\\\\").Replace("\"", "\\\"");
        private static string Num(double v) => v.ToString("0.######", CultureInfo.InvariantCulture);
        private static string Err(string msg) => "{\"ok\":false,\"error\":\"" + Esc(msg) + "\"}";

        private sealed class SymAgg
        {
            public string Symbol;
            public string Side;
            public double Lots;
            public double EntryWeighted;
            public double Pl;
            public int Count;
        }
    }
}
