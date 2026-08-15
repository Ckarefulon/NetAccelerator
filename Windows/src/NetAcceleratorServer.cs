using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Net.Http;
using System.Net.NetworkInformation;
using System.Security.Authentication;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Win32;

namespace NetAccelerator
{
    internal static class Program
    {
        private const int HttpPort = 80;
        private const int HttpsPort = 443;
        private const string HostsStart = "# NetAccelerator Start";
        private const string HostsEnd = "# NetAccelerator End";
        private static readonly string BaseDir = AppDomain.CurrentDomain.BaseDirectory;
        private static readonly string ProjectDir = Path.GetFullPath(Path.Combine(BaseDir, ".."));
        private static readonly string ConfigDir = Path.Combine(ProjectDir, "config");
        private static readonly string RuntimeDir = Path.Combine(ProjectDir, "runtime");
        private static readonly string StatusPath = Path.Combine(RuntimeDir, "proxy-status.json");
        private static readonly string StopPath = Path.Combine(RuntimeDir, "stop.flag");
        private static readonly string DomainsPath = Path.Combine(ConfigDir, "domains.txt");
        private static readonly string RulesPath = Path.Combine(ConfigDir, "watt-rules.tsv");
        private static readonly string TransportProxyPath = Path.Combine(ConfigDir, "transport-proxy.txt");
        private static readonly string CertInfoPath = Path.Combine(ConfigDir, "certificate-info.json");
        private static readonly string HostsPath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"drivers\etc\hosts");
        private static readonly string HostsBackupPath = Path.Combine(RuntimeDir, "hosts-backup.txt");
        private static readonly string LogPath = Path.Combine(RuntimeDir, "proxy.log");
        private static readonly string[] DnsServers = { "223.5.5.5", "119.29.29.29", "114.114.114.114", "1.1.1.1" };
        private static readonly object LogLock = new object();
        private static readonly object DnsLock = new object();
        private static readonly object BackoffLock = new object();
        private static readonly object HttpClientLock = new object();
        private static readonly Dictionary<string, DnsCacheEntry> DnsCache = new Dictionary<string, DnsCacheEntry>(StringComparer.OrdinalIgnoreCase);
        private static readonly Dictionary<string, DateTime> UpstreamBackoff = new Dictionary<string, DateTime>(StringComparer.OrdinalIgnoreCase);
        private static readonly Dictionary<string, ManagedClientEntry> HttpClients = new Dictionary<string, ManagedClientEntry>(StringComparer.OrdinalIgnoreCase);
        private static volatile bool stopping;
        private static TcpListener httpListener;
        private static TcpListener httpsListener;
        private static HashSet<string> domains;
        private static X509Certificate2 serverCertificate;
        private static List<ProxyRule> rules;

        private sealed class DnsCacheEntry
        {
            public DateTime ExpiresUtc;
            public IPAddress[] Addresses;
        }

        private sealed class ProxyRule
        {
            public string[] Domains;
            public string Forward;
            public string Mode;
            public bool IgnoreNameMismatch;
            public string PathToken;
        }

        public static int Main(string[] args)
        {
            Console.OutputEncoding = Encoding.UTF8;
            try
            {
                Directory.CreateDirectory(RuntimeDir);
                domains = LoadDomains();
                rules = LoadRules();
                File.Delete(StopPath);

                httpListener = Bind(HttpPort);
                httpsListener = Bind(HttpsPort);
                if (httpListener == null || httpsListener == null)
                {
                    StopListeners();
                    WriteStatus("conflict", "80 或 443 端口已被占用。若 Watt Toolkit 正在加速，请由用户先手动停止 Watt 加速；不要关闭 Clash。");
                    return 2;
                }

                serverCertificate = LoadServerCertificate();
                StartAcceptLoop(httpListener, false);
                StartAcceptLoop(httpsListener, true);

                string selfTestError;
                if (!SelfTest(out selfTestError))
                {
                    StopListeners();
                    WriteStatus("error", "真实反向代理自检失败：" + selfTestError);
                    return 3;
                }

                ApplyHosts();
                WriteStatus("ready", "Watt Hosts 模式已就绪：GitHub、国外验证码平台");
                Log("READY domains=" + domains.Count);

                while (!stopping)
                {
                    if (File.Exists(StopPath)) break;
                    Thread.Sleep(300);
                }

                return 0;
            }
            catch (Exception ex)
            {
                Log("FATAL " + ex);
                WriteStatus("error", ex.Message);
                return 1;
            }
            finally
            {
                stopping = true;
                StopListeners();
                try { RestoreHosts(); } catch (Exception ex) { Log("HOSTS-RESTORE " + ex.Message); }
                try { File.Delete(StopPath); } catch { }
                if (File.Exists(StatusPath) && ReadStatusState() == "ready")
                    WriteStatus("stopped", "服务已停止，目标域名 Hosts 已恢复；系统代理从未改动");
            }
        }

        private static void ProxyManagedHttp(Stream downstream, byte[] rawHeader, string host, string requestTarget, ProxyRule rule)
        {
            string headerText = Encoding.ASCII.GetString(rawHeader);
            Match requestLine = Regex.Match(headerText, @"^(\S+)\s+(\S+)\s+HTTP/\d(?:\.\d)?");
            if (!requestLine.Success) { WriteResponse(downstream, "400 Bad Request", "Invalid HTTP request."); return; }
            string method = requestLine.Groups[1].Value.ToUpperInvariant();
            long contentLength = ReadContentLength(headerText);
            bool chunked = Regex.IsMatch(headerText, @"(?im)^Transfer-Encoding:\s*.*chunked");
            bool replayable = method == "GET" || method == "HEAD" || method == "OPTIONS";

            ManagedTarget primary = SelectManagedTarget(host, requestTarget, rule, false);
            try
            {
                SendManagedRequest(downstream, rawHeader, method, host, primary, rule, contentLength, chunked);
                Log("HTTP-POOL " + host + " -> " + primary.Destination + (primary.Proxy == null ? " direct" : " via existing system proxy"));
            }
            catch (Exception first)
            {
                Log("HTTP-POOL-FAIL host=" + host + " target=" + primary.Destination + " " + UnwrapMessage(first));
                if (!replayable)
                {
                    WriteResponse(downstream, "502 Bad Gateway", "Upstream request failed for " + host + ".");
                    return;
                }
                try
                {
                    ManagedTarget fallback = SelectManagedTarget(host, requestTarget, rule, true);
                    SendManagedRequest(downstream, rawHeader, method, host, fallback, rule, 0, false);
                    Log("HTTP-POOL " + host + " -> " + fallback.Destination +
                        (fallback.Proxy == null ? " direct fallback" : " via existing system proxy fallback"));
                }
                catch (Exception second)
                {
                    Log("HTTP-POOL-FALLBACK-FAIL host=" + host + " " + UnwrapMessage(second));
                    WriteResponse(downstream, "502 Bad Gateway", "Upstream request failed for " + host + ".");
                }
            }
        }

        private static ManagedTarget SelectManagedTarget(string host, string requestTarget, ProxyRule rule, bool fallback)
        {
            Uri proxy = ReadSystemProxy();
            bool vendorMode = rule != null && rule.Mode == "server-accelerate";
            bool primaryUsesProxy = proxy != null && vendorMode;
            bool useProxy = fallback ? (primaryUsesProxy ? false : proxy != null) : primaryUsesProxy;

            string path = String.IsNullOrEmpty(requestTarget) ? "/" : requestTarget;
            if (!path.StartsWith("/")) path = "/";
            Uri destination = new Uri(new Uri("https://" + host + "/"), path);
            return new ManagedTarget { Destination = destination, Proxy = useProxy ? proxy : null,
                IgnoreNameMismatch = rule != null && rule.IgnoreNameMismatch, Rule = rule, OriginalHost = host };
        }

        private static void SendManagedRequest(Stream downstream, byte[] rawHeader, string method, string host, ManagedTarget target, ProxyRule rule, long contentLength, bool chunked)
        {
            HttpClient http = GetHttpClient(target);
            using (var request = new HttpRequestMessage(new HttpMethod(method), target.Destination))
            {
                request.Version = new Version(2, 0);
                request.VersionPolicy = HttpVersionPolicy.RequestVersionOrLower;
                bool hasBody = chunked || contentLength > 0 || method == "POST" || method == "PUT" || method == "PATCH";
                if (hasBody) request.Content = new DownstreamContent(downstream, contentLength, chunked);
                request.Headers.Host = host;
                CopyRequestHeaders(rawHeader, request);
                using (var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(30)))
                using (HttpResponseMessage response = http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, timeout.Token).GetAwaiter().GetResult())
                {
                    WriteManagedResponse(downstream, method, response);
                }
            }
        }

        private static HttpClient GetHttpClient(ManagedTarget target)
        {
            string key = target.Destination.Scheme + "://" + target.Destination.Authority + "|" +
                (target.Proxy == null ? "direct" : target.Proxy.AbsoluteUri) + "|" + target.IgnoreNameMismatch + "|" +
                (target.Rule == null ? "none" : target.Rule.Mode + ":" + target.Rule.Forward);
            lock (HttpClientLock)
            {
                ManagedClientEntry existing;
                if (HttpClients.TryGetValue(key, out existing) && existing.ExpiresUtc > DateTime.UtcNow) return existing.Client;
                var handler = new SocketsHttpHandler();
                handler.AllowAutoRedirect = false;
                handler.AutomaticDecompression = DecompressionMethods.None;
                handler.UseCookies = false;
                handler.MaxConnectionsPerServer = 64;
                handler.EnableMultipleHttp2Connections = true;
                handler.PooledConnectionLifetime = TimeSpan.FromSeconds(100);
                handler.PooledConnectionIdleTimeout = TimeSpan.FromSeconds(30);
                handler.UseProxy = target.Proxy != null;
                if (target.Proxy != null) handler.Proxy = new WebProxy(target.Proxy);
                if (target.Proxy == null)
                {
                    ManagedTarget captured = target;
                    bool allowMismatch = target.IgnoreNameMismatch;
                    handler.SslOptions = new SslClientAuthenticationOptions
                    {
                        RemoteCertificateValidationCallback = delegate(object sender, X509Certificate cert, X509Chain chain, SslPolicyErrors errors)
                        {
                            if (errors == SslPolicyErrors.None) return true;
                            return allowMismatch && errors == SslPolicyErrors.RemoteCertificateNameMismatch;
                        }
                    };
                    handler.ConnectCallback = delegate(SocketsHttpConnectionContext context, CancellationToken token)
                    { return new ValueTask<Stream>(ConnectManagedCoreAsync(context, token, captured)); };
                }
                var client = new HttpClient(handler, true);
                client.Timeout = Timeout.InfiniteTimeSpan;
                if (existing != null)
                {
                    HttpClient retired = existing.Client;
                    Task.Delay(TimeSpan.FromSeconds(30)).ContinueWith(delegate { retired.Dispose(); });
                }
                HttpClients[key] = new ManagedClientEntry { Client = client,
                    ExpiresUtc = DateTime.UtcNow.AddSeconds(existing == null ? 10 : 100) };
                return client;
            }
        }

        private static async Task<Stream> ConnectManagedCoreAsync(SocketsHttpConnectionContext context, CancellationToken cancellationToken, ManagedTarget target)
        {
            var addresses = new List<IPAddress>();
            ProxyRule rule = target.Rule;
            if (rule != null && rule.Mode != "server-accelerate")
            {
                Uri absolute;
                string forward = rule.Forward;
                if (Uri.TryCreate(forward, UriKind.Absolute, out absolute)) forward = absolute.Host;
                IPAddress literal;
                if (IPAddress.TryParse(forward, out literal)) addresses.Add(literal);
                else if (!String.Equals(forward, target.OriginalHost, StringComparison.OrdinalIgnoreCase))
                    addresses.AddRange(ResolveTrusted(forward));
            }
            addresses.AddRange(ResolveTrusted(target.OriginalHost));
            addresses = addresses.GroupBy(x => x.ToString()).Select(x => x.First()).ToList();
            var failures = new List<Exception>();
            foreach (IPAddress address in addresses)
            {
                Socket socket = null;
                try
                {
                    socket = new Socket(address.AddressFamily, SocketType.Stream, ProtocolType.Tcp);
                    socket.NoDelay = true;
                    using (var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken))
                    {
                        timeout.CancelAfter(TimeSpan.FromSeconds(10));
                        await socket.ConnectAsync(new IPEndPoint(address, context.DnsEndPoint.Port), timeout.Token).AsTask();
                        var network = new NetworkStream(socket, true);
                        socket = null;
                        Log("CONNECT-CALLBACK " + target.OriginalHost + " -> " + address);
                        return network;
                    }
                }
                catch (Exception ex)
                {
                    failures.Add(ex);
                    if (socket != null) try { socket.Dispose(); } catch { }
                }
            }
            throw new AggregateException("Could not connect using configured IP, forward DNS, or original DNS.", failures);
        }

        private static void CopyRequestHeaders(byte[] rawHeader, HttpRequestMessage request)
        {
            string[] lines = Encoding.ASCII.GetString(rawHeader).Split(new[] { "\r\n" }, StringSplitOptions.None);
            for (int i = 1; i < lines.Length; i++)
            {
                int colon = lines[i].IndexOf(':');
                if (colon <= 0) continue;
                string name = lines[i].Substring(0, colon).Trim();
                string value = lines[i].Substring(colon + 1).Trim();
                if (IsHopHeader(name) || name.Equals("Host", StringComparison.OrdinalIgnoreCase) || name.Equals("Content-Length", StringComparison.OrdinalIgnoreCase)) continue;
                if (!request.Headers.TryAddWithoutValidation(name, value) && request.Content != null)
                    request.Content.Headers.TryAddWithoutValidation(name, value);
            }
        }

        private static void WriteManagedResponse(Stream downstream, string method, HttpResponseMessage response)
        {
            var header = new StringBuilder();
            header.Append("HTTP/1.1 ").Append((int)response.StatusCode).Append(' ').Append(response.ReasonPhrase).Append("\r\n");
            foreach (var pair in response.Headers)
                if (!IsHopHeader(pair.Key)) header.Append(pair.Key).Append(": ").Append(String.Join(", ", pair.Value)).Append("\r\n");
            foreach (var pair in response.Content.Headers)
                if (!IsHopHeader(pair.Key)) header.Append(pair.Key).Append(": ").Append(String.Join(", ", pair.Value)).Append("\r\n");
            header.Append("Connection: close\r\n\r\n");
            byte[] bytes = Encoding.ASCII.GetBytes(header.ToString());
            downstream.Write(bytes, 0, bytes.Length);
            int code = (int)response.StatusCode;
            if (method != "HEAD" && code != 204 && code != 304)
            {
                using (Stream body = response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()) body.CopyTo(downstream, 32768);
            }
            downstream.Flush();
        }

        private static long ReadContentLength(string header)
        {
            Match match = Regex.Match(header, @"(?im)^Content-Length:\s*(\d+)");
            long value;
            return match.Success && Int64.TryParse(match.Groups[1].Value, out value) ? value : 0;
        }

        private static bool IsHopHeader(string name)
        {
            return Regex.IsMatch(name, @"^(Connection|Proxy-Connection|Keep-Alive|TE|Trailer|Transfer-Encoding|Upgrade)$", RegexOptions.IgnoreCase);
        }

        private static string UnwrapMessage(Exception ex)
        {
            while (ex.InnerException != null) ex = ex.InnerException;
            return ex.GetType().Name + " " + ex.Message;
        }

        private sealed class ManagedTarget
        {
            public Uri Destination;
            public Uri Proxy;
            public bool IgnoreNameMismatch;
            public ProxyRule Rule;
            public string OriginalHost;
        }

        private sealed class ManagedClientEntry
        {
            public HttpClient Client;
            public DateTime ExpiresUtc;
        }

        private sealed class DownstreamContent : HttpContent
        {
            private readonly Stream source;
            private readonly long length;
            private readonly bool chunked;
            public DownstreamContent(Stream source, long length, bool chunked)
            {
                this.source = source; this.length = length; this.chunked = chunked;
                if (!chunked) Headers.ContentLength = length;
            }
            protected override Task SerializeToStreamAsync(Stream target, TransportContext context)
            {
                return Task.Run(delegate { if (chunked) CopyDecodedChunks(source, target); else CopyExact(source, target, length); });
            }
            protected override bool TryComputeLength(out long computedLength)
            {
                computedLength = length; return !chunked;
            }
        }

        private static void CopyExact(Stream source, Stream target, long remaining)
        {
            byte[] buffer = new byte[32768];
            while (remaining > 0)
            {
                int count = source.Read(buffer, 0, (int)Math.Min(buffer.Length, remaining));
                if (count <= 0) throw new EndOfStreamException("Request body ended early");
                target.Write(buffer, 0, count); remaining -= count;
            }
        }

        private static void CopyDecodedChunks(Stream source, Stream target)
        {
            while (true)
            {
                string line = ReadAsciiLine(source);
                int semi = line.IndexOf(';');
                if (semi >= 0) line = line.Substring(0, semi);
                long size = Convert.ToInt64(line.Trim(), 16);
                if (size == 0)
                {
                    while (ReadAsciiLine(source).Length > 0) { }
                    return;
                }
                CopyExact(source, target, size);
                if (source.ReadByte() != 13 || source.ReadByte() != 10) throw new InvalidDataException("Invalid chunk terminator");
            }
        }

        private static string ReadAsciiLine(Stream stream)
        {
            var bytes = new List<byte>();
            int previous = -1;
            while (true)
            {
                int current = stream.ReadByte();
                if (current < 0) throw new EndOfStreamException();
                if (previous == 13 && current == 10)
                {
                    if (bytes.Count > 0) bytes.RemoveAt(bytes.Count - 1);
                    return Encoding.ASCII.GetString(bytes.ToArray());
                }
                bytes.Add((byte)current); previous = current;
            }
        }

        private static TcpListener Bind(int port)
        {
            try
            {
                var listener = new TcpListener(IPAddress.Loopback, port);
                listener.Server.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, false);
                listener.Start(256);
                return listener;
            }
            catch (SocketException ex)
            {
                Log("BIND " + port + " " + ex.SocketErrorCode);
                return null;
            }
        }

        private static void StartAcceptLoop(TcpListener listener, bool tls)
        {
            var thread = new Thread(delegate()
            {
                while (!stopping)
                {
                    try
                    {
                        TcpClient client = listener.AcceptTcpClient();
                        client.NoDelay = true;
                        var worker = new Thread(() => HandleClient(client, tls));
                        worker.IsBackground = true;
                        worker.Start();
                    }
                    catch { if (!stopping) Thread.Sleep(100); }
                }
            });
            thread.IsBackground = true;
            thread.Start();
        }

        private static void HandleClient(TcpClient client, bool tls)
        {
            Stream downstream = null;
            TcpClient upstreamClient = null;
            Stream upstream = null;
            try
            {
                client.ReceiveTimeout = 20000;
                client.SendTimeout = 20000;
                downstream = client.GetStream();
                if (tls)
                {
                    var ssl = new SslStream(downstream, false);
                    ssl.AuthenticateAsServer(serverCertificate, false, SslProtocols.Tls12, false);
                    downstream = ssl;
                }

                byte[] header = ReadHeader(downstream, 65536);
                if (header == null) return;
                string host = ReadHost(header);
                if (String.IsNullOrEmpty(host) || !IsAccelerated(host))
                {
                    WriteResponse(downstream, "421 Misdirected Request", "Domain is not enabled in NetAccelerator.");
                    return;
                }

                string requestTarget = ReadRequestTarget(header);
                if (!tls)
                {
                    WriteRedirect(downstream, host, requestTarget);
                    return;
                }

                ProxyRule rule = FindRule(host, requestTarget);
                ProxyManagedHttp(downstream, header, host, requestTarget, rule);
            }
            catch (Exception ex) { Log("REQUEST " + ex.GetType().Name + " " + ex.Message); }
            finally
            {
                try { if (upstream != null) upstream.Dispose(); } catch { }
                try { if (upstreamClient != null) upstreamClient.Close(); } catch { }
                try { if (downstream != null) downstream.Dispose(); } catch { }
                try { client.Close(); } catch { }
            }
        }

        private static byte[] ReadHeader(Stream stream, int maxBytes)
        {
            var data = new MemoryStream();
            int state = 0;
            while (data.Length < maxBytes)
            {
                int value = stream.ReadByte();
                if (value < 0) return null;
                data.WriteByte((byte)value);
                if ((state == 0 || state == 2) && value == 13) state++;
                else if ((state == 1 || state == 3) && value == 10) state++;
                else state = value == 13 ? 1 : 0;
                if (state == 4) return data.ToArray();
            }
            return null;
        }

        private static string ReadHost(byte[] header)
        {
            string text = Encoding.ASCII.GetString(header);
            Match match = Regex.Match(text, @"(?im)^Host:\s*([^:\s]+)");
            return match.Success ? match.Groups[1].Value.Trim().TrimEnd('.').ToLowerInvariant() : null;
        }

        private static string ReadRequestTarget(byte[] header)
        {
            Match match = Regex.Match(Encoding.ASCII.GetString(header), @"^\S+\s+(\S+)");
            return match.Success ? match.Groups[1].Value : "/";
        }

        private static bool IsAccelerated(string host)
        {
            if (domains.Contains(host)) return true;
            return domains.Any(d => host.EndsWith("." + d, StringComparison.OrdinalIgnoreCase));
        }

        private static ProxyRule FindRule(string host, string requestTarget)
        {
            ProxyRule fallback = null;
            foreach (ProxyRule rule in rules)
            {
                if (!rule.Domains.Contains(host, StringComparer.OrdinalIgnoreCase)) continue;
                if (String.IsNullOrEmpty(rule.PathToken) || requestTarget.IndexOf(rule.PathToken, StringComparison.OrdinalIgnoreCase) >= 0)
                    return rule;
                fallback = null;
            }
            return fallback;
        }

        private static TcpClient ConnectThroughHttpProxy(Uri proxy, string targetHost, int targetPort, out IPAddress selected)
        {
            TcpClient tcp = ConnectFastest(proxy.Host, proxy.Port, out selected);
            if (tcp == null) return null;
            try
            {
                NetworkStream stream = tcp.GetStream();
                stream.ReadTimeout = 8000;
                byte[] request = Encoding.ASCII.GetBytes("CONNECT " + targetHost + ":" + targetPort + " HTTP/1.1\r\nHost: " + targetHost + ":" + targetPort + "\r\nConnection: keep-alive\r\n\r\n");
                stream.Write(request, 0, request.Length); stream.Flush();
                byte[] response = ReadHeader(stream, 16384);
                if (response == null || !Regex.IsMatch(Encoding.ASCII.GetString(response), @"^HTTP/1\.[01] 200"))
                    throw new IOException("Watt server acceleration proxy rejected CONNECT");
                stream.ReadTimeout = Timeout.Infinite;
                return tcp;
            }
            catch (Exception ex)
            {
                Log("SYSTEM-PROXY-FAIL proxy=" + proxy.Host + ":" + proxy.Port + " target=" + targetHost + ":" + targetPort + " " + ex.GetType().Name + " " + ex.Message);
                tcp.Close(); selected = null; return null;
            }
        }

        private static TcpClient ConnectThroughHttpProxyWithRetry(Uri proxy, string targetHost, int targetPort, out IPAddress selected)
        {
            selected = null;
            for (int attempt = 0; attempt < 2; attempt++)
            {
                TcpClient tcp = ConnectThroughHttpProxy(proxy, targetHost, targetPort, out selected);
                if (tcp != null) return tcp;
                if (attempt == 0) Thread.Sleep(100);
            }
            return null;
        }

        private static bool IsBackedOff(string target)
        {
            lock (BackoffLock)
            {
                DateTime until;
                if (!UpstreamBackoff.TryGetValue(target, out until)) return false;
                if (until > DateTime.UtcNow) return true;
                UpstreamBackoff.Remove(target);
                return false;
            }
        }

        private static void MarkBackedOff(string target, string stage)
        {
            lock (BackoffLock) UpstreamBackoff[target] = DateTime.UtcNow.AddMinutes(5);
            Log("UPSTREAM-BACKOFF target=" + target + " stage=" + stage + " minutes=5");
        }

        private static Stream AuthenticateUpstream(TcpClient tcp, string host, ProxyRule rule)
        {
            tcp.ReceiveTimeout = 10000;
            tcp.SendTimeout = 10000;
            NetworkStream network = tcp.GetStream();
            network.ReadTimeout = 10000;
            network.WriteTimeout = 10000;
            var ssl = new SslStream(network, false, delegate(object sender, X509Certificate cert, X509Chain chain, SslPolicyErrors errors)
            {
                if (errors == SslPolicyErrors.None) return true;
                return rule != null && rule.IgnoreNameMismatch && errors == SslPolicyErrors.RemoteCertificateNameMismatch;
            });
            ssl.ReadTimeout = 10000;
            ssl.WriteTimeout = 10000;
            // Watt-style acceleration must not block on public CRL/OCSP endpoints.
            ssl.AuthenticateAsClient(host, null, SslProtocols.Tls12, false);
            return ssl;
        }

        private static Uri ReadSystemProxy()
        {
            try
            {
                if (File.Exists(TransportProxyPath))
                {
                    string configured = File.ReadAllText(TransportProxyPath, Encoding.UTF8).Trim();
                    Uri explicitProxy;
                    if (Uri.TryCreate(configured, UriKind.Absolute, out explicitProxy) &&
                        !(IPAddress.IsLoopback(Dns.GetHostAddresses(explicitProxy.Host).FirstOrDefault() ?? IPAddress.None) &&
                          (explicitProxy.Port == HttpPort || explicitProxy.Port == HttpsPort))) return explicitProxy;
                }
            }
            catch { }
            try
            {
                using (RegistryKey key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Internet Settings"))
                {
                    if (key != null && Convert.ToInt32(key.GetValue("ProxyEnable", 0)) == 1)
                    {
                        string value = Convert.ToString(key.GetValue("ProxyServer", ""));
                        if (!String.IsNullOrWhiteSpace(value))
                        {
                            if (value.IndexOf(';') >= 0)
                            {
                                string[] entries = value.Split(';');
                                string https = entries.FirstOrDefault(x => x.StartsWith("https=", StringComparison.OrdinalIgnoreCase));
                                value = https == null ? entries[0] : https.Substring(6);
                                int equals = value.IndexOf('=');
                                if (equals >= 0) value = value.Substring(equals + 1);
                            }
                            if (!value.Contains("://")) value = "http://" + value;
                            Uri proxy;
                            if (Uri.TryCreate(value, UriKind.Absolute, out proxy) &&
                                !(IPAddress.IsLoopback(Dns.GetHostAddresses(proxy.Host).FirstOrDefault() ?? IPAddress.None) &&
                                  (proxy.Port == HttpPort || proxy.Port == HttpsPort))) return proxy;
                        }
                    }
                }
            }
            catch { }
            try
            {
                bool clashReady = IPGlobalProperties.GetIPGlobalProperties().GetActiveTcpListeners()
                    .Any(x => x.Port == 7897 && IPAddress.IsLoopback(x.Address));
                if (clashReady) return new Uri("http://127.0.0.1:7897");
            }
            catch { }
            return null;
        }

        private static TcpClient ConnectFastest(string host, int port, out IPAddress selected)
        {
            selected = null;
            IPAddress literal;
            IPAddress[] addresses = IPAddress.TryParse(host, out literal)
                ? new[] { literal }
                : ResolveTrusted(host);
            for (int attempt = 0; attempt < 1; attempt++)
            {
                foreach (IPAddress address in addresses)
                {
                    TcpClient tcp = null;
                    try
                    {
                        tcp = new TcpClient(address.AddressFamily);
                        tcp.NoDelay = true;
                        IAsyncResult ar = tcp.BeginConnect(address, port, null, null);
                        if (ar.AsyncWaitHandle.WaitOne(2500) && tcp.Connected)
                        {
                            tcp.EndConnect(ar);
                            selected = address;
                            return tcp;
                        }
                    }
                    catch { }
                    if (tcp != null) try { tcp.Close(); } catch { }
                }
            }
            return null;
        }

        private static IPAddress[] ResolveTrusted(string host)
        {
            lock (DnsLock)
            {
                DnsCacheEntry cached;
                if (DnsCache.TryGetValue(host, out cached) && cached.ExpiresUtc > DateTime.UtcNow)
                    return cached.Addresses;
            }

            var result = new List<IPAddress>();
            foreach (string dns in DnsServers)
            {
                try
                {
                    result.AddRange(QueryDnsA(host, IPAddress.Parse(dns)));
                    if (result.Count > 0) break;
                }
                catch { }
            }
            IPAddress[] unique = result.Where(ip => !IPAddress.IsLoopback(ip)).Distinct().ToArray();
            lock (DnsLock)
                DnsCache[host] = new DnsCacheEntry { ExpiresUtc = DateTime.UtcNow.AddMinutes(5), Addresses = unique };
            return unique;
        }

        private static IEnumerable<IPAddress> QueryDnsA(string host, IPAddress dnsServer)
        {
            ushort id = (ushort)new Random(unchecked(Environment.TickCount ^ Thread.CurrentThread.ManagedThreadId)).Next(1, 65535);
            var query = new MemoryStream();
            WriteUInt16(query, id); WriteUInt16(query, 0x0100); WriteUInt16(query, 1);
            WriteUInt16(query, 0); WriteUInt16(query, 0); WriteUInt16(query, 0);
            foreach (string label in host.Split('.'))
            {
                byte[] bytes = Encoding.ASCII.GetBytes(label);
                query.WriteByte((byte)bytes.Length); query.Write(bytes, 0, bytes.Length);
            }
            query.WriteByte(0); WriteUInt16(query, 1); WriteUInt16(query, 1);

            using (var udp = new UdpClient(dnsServer.AddressFamily))
            {
                udp.Client.ReceiveTimeout = 2200;
                byte[] packet = query.ToArray();
                udp.Send(packet, packet.Length, new IPEndPoint(dnsServer, 53));
                IPEndPoint remote = null;
                byte[] response = udp.Receive(ref remote);
                return ParseDnsA(response, id);
            }
        }

        private static IEnumerable<IPAddress> ParseDnsA(byte[] data, ushort expectedId)
        {
            var result = new List<IPAddress>();
            if (data.Length < 12 || ReadUInt16(data, 0) != expectedId) return result;
            int questions = ReadUInt16(data, 4), answers = ReadUInt16(data, 6), offset = 12;
            for (int i = 0; i < questions; i++) { SkipDnsName(data, ref offset); offset += 4; }
            for (int i = 0; i < answers && offset + 12 <= data.Length; i++)
            {
                SkipDnsName(data, ref offset);
                int type = ReadUInt16(data, offset); offset += 2;
                int klass = ReadUInt16(data, offset); offset += 2;
                offset += 4;
                int length = ReadUInt16(data, offset); offset += 2;
                if (type == 1 && klass == 1 && length == 4 && offset + 4 <= data.Length)
                    result.Add(new IPAddress(new byte[] { data[offset], data[offset + 1], data[offset + 2], data[offset + 3] }));
                offset += length;
            }
            return result;
        }

        private static void SkipDnsName(byte[] data, ref int offset)
        {
            while (offset < data.Length)
            {
                int length = data[offset++];
                if (length == 0) return;
                if ((length & 0xC0) == 0xC0) { offset++; return; }
                offset += length;
            }
        }

        private static void WriteUInt16(Stream stream, int value)
        {
            stream.WriteByte((byte)(value >> 8)); stream.WriteByte((byte)value);
        }

        private static ushort ReadUInt16(byte[] data, int offset)
        {
            return (ushort)((data[offset] << 8) | data[offset + 1]);
        }

        private static void PumpBothWays(Stream client, Stream upstream)
        {
            var a = new Thread(() => Pump(client, upstream));
            var b = new Thread(() => Pump(upstream, client));
            a.IsBackground = true; b.IsBackground = true;
            a.Start(); b.Start();
            a.Join(); b.Join();
        }

        private static void Pump(Stream source, Stream destination)
        {
            try
            {
                byte[] buffer = new byte[32768];
                int count;
                while ((count = source.Read(buffer, 0, buffer.Length)) > 0)
                {
                    destination.Write(buffer, 0, count);
                    destination.Flush();
                }
            }
            catch { }
            try { destination.Dispose(); } catch { }
        }

        private static bool SelfTest(out string error)
        {
            error = null;
            try
            {
                using (var client = new TcpClient())
                {
                    client.Connect(IPAddress.Loopback, HttpsPort);
                    using (var ssl = new SslStream(client.GetStream(), false, delegate { return true; }))
                    {
                        ssl.ReadTimeout = 30000;
                        ssl.WriteTimeout = 30000;
                        ssl.AuthenticateAsClient("github.com", null, SslProtocols.Tls12, false);
                        byte[] request = Encoding.ASCII.GetBytes("HEAD / HTTP/1.1\r\nHost: github.com\r\nUser-Agent: NetAccelerator-SelfTest\r\nConnection: close\r\n\r\n");
                        ssl.Write(request, 0, request.Length); ssl.Flush();
                        byte[] header = ReadHeader(ssl, 32768);
                        if (header == null) { error = "GitHub 未返回 HTTP 响应"; return false; }
                        string first = Encoding.ASCII.GetString(header).Split('\n')[0].Trim();
                        if (!Regex.IsMatch(first, @"^HTTP/\d(?:\.\d)? [23]\d\d"))
                        { error = first; return false; }
                    }
                }
                return true;
            }
            catch (Exception ex) { error = ex.GetType().Name + ": " + ex.Message; return false; }
        }

        private static HashSet<string> LoadDomains()
        {
            if (!File.Exists(DomainsPath)) throw new FileNotFoundException("缺少 domains.txt", DomainsPath);
            var values = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (string raw in File.ReadAllLines(DomainsPath, Encoding.UTF8))
            {
                string value = raw.Trim().TrimEnd('.').ToLowerInvariant();
                if (value.Length > 0 && !value.StartsWith("#")) values.Add(value);
            }
            if (values.Count == 0) throw new InvalidDataException("domains.txt 中没有域名");
            return values;
        }

        private static List<ProxyRule> LoadRules()
        {
            if (!File.Exists(RulesPath)) throw new FileNotFoundException("缺少 watt-rules.tsv", RulesPath);
            var result = new List<ProxyRule>();
            foreach (string raw in File.ReadAllLines(RulesPath, Encoding.UTF8))
            {
                string line = raw.Trim();
                if (line.Length == 0 || line.StartsWith("#")) continue;
                string[] fields = line.Split('\t');
                if (fields.Length < 4) throw new InvalidDataException("watt-rules.tsv 格式错误：" + line);
                result.Add(new ProxyRule
                {
                    Domains = fields[0].Split(new[] { ';' }, StringSplitOptions.RemoveEmptyEntries),
                    Forward = fields[1],
                    Mode = fields[2],
                    IgnoreNameMismatch = String.Equals(fields[3], "true", StringComparison.OrdinalIgnoreCase),
                    PathToken = fields.Length > 4 ? fields[4] : ""
                });
            }
            return result;
        }

        private static X509Certificate2 LoadServerCertificate()
        {
            if (!File.Exists(CertInfoPath)) throw new FileNotFoundException("缺少证书配置，请先运行 setup_https.ps1", CertInfoPath);
            string json = File.ReadAllText(CertInfoPath, Encoding.UTF8);
            Match match = Regex.Match(json, "\\\"ServerThumbprint\\\"\\s*:\\s*\\\"([^\\\"]+)\\\"");
            if (!match.Success) throw new InvalidDataException("certificate-info.json 缺少 ServerThumbprint");
            string thumbprint = Regex.Replace(match.Groups[1].Value, "[^0-9A-Fa-f]", "").ToUpperInvariant();
            foreach (StoreLocation location in new[] { StoreLocation.CurrentUser, StoreLocation.LocalMachine })
            {
                using (var store = new X509Store(StoreName.My, location))
                {
                    store.Open(OpenFlags.ReadOnly);
                    X509Certificate2 cert = store.Certificates.Cast<X509Certificate2>().FirstOrDefault(c => c.Thumbprint == thumbprint && c.HasPrivateKey);
                    if (cert != null) return cert;
                }
            }
            throw new InvalidOperationException("找不到带私钥的 NetAccelerator 服务器证书");
        }

        private static void ApplyHosts()
        {
            string original = File.ReadAllText(HostsPath, Encoding.UTF8);
            if (!File.Exists(HostsBackupPath)) File.WriteAllText(HostsBackupPath, original, new UTF8Encoding(false));
            string clean = RemoveManagedHostsBlock(original).TrimEnd('\r', '\n');
            var block = new StringBuilder();
            block.AppendLine(); block.AppendLine(HostsStart);
            foreach (string domain in domains.OrderBy(x => x)) block.AppendLine("127.0.0.1 " + domain);
            block.AppendLine(HostsEnd);
            File.WriteAllText(HostsPath, clean + Environment.NewLine + block, new UTF8Encoding(false));
            FlushDns();
        }

        private static void RestoreHosts()
        {
            if (!File.Exists(HostsPath)) return;
            string current = File.ReadAllText(HostsPath, Encoding.UTF8);
            if (current.IndexOf(HostsStart, StringComparison.Ordinal) < 0) return;
            string clean = RemoveManagedHostsBlock(current).TrimEnd('\r', '\n') + Environment.NewLine;
            File.WriteAllText(HostsPath, clean, new UTF8Encoding(false));
            try { File.Delete(HostsBackupPath); } catch { }
            FlushDns();
        }

        private static string RemoveManagedHostsBlock(string text)
        {
            string pattern = @"(?ms)^\s*# NetAccelerator Start\s*$.*?^\s*# NetAccelerator End\s*$\r?\n?";
            return Regex.Replace(text, pattern, "");
        }

        private static void FlushDns()
        {
            try
            {
                var p = System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("ipconfig", "/flushdns")
                { CreateNoWindow = true, UseShellExecute = false });
                if (p != null) p.WaitForExit(5000);
            }
            catch { }
        }

        private static void StopListeners()
        {
            try { if (httpListener != null) httpListener.Stop(); } catch { }
            try { if (httpsListener != null) httpsListener.Stop(); } catch { }
        }

        private static void WriteResponse(Stream stream, string status, string body)
        {
            byte[] payload = Encoding.UTF8.GetBytes(body);
            byte[] header = Encoding.ASCII.GetBytes("HTTP/1.1 " + status + "\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: " + payload.Length + "\r\nConnection: close\r\n\r\n");
            stream.Write(header, 0, header.Length); stream.Write(payload, 0, payload.Length); stream.Flush();
        }

        private static void WriteRedirect(Stream stream, string host, string target)
        {
            string location = "https://" + host + (String.IsNullOrEmpty(target) ? "/" : target);
            byte[] response = Encoding.ASCII.GetBytes("HTTP/1.1 308 Permanent Redirect\r\nLocation: " + location + "\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
            stream.Write(response, 0, response.Length); stream.Flush();
        }

        private static void Log(string message)
        {
            lock (LogLock)
            {
                try { File.AppendAllText(LogPath, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff ") + message + Environment.NewLine, Encoding.UTF8); }
                catch { }
            }
        }

        private static void WriteStatus(string state, string message)
        {
            string json = "{\"State\":\"" + JsonEscape(state) + "\",\"Message\":\"" + JsonEscape(message) + "\",\"Time\":\"" + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "\"}";
            try { File.WriteAllText(StatusPath, json, new UTF8Encoding(false)); } catch { }
        }

        private static string ReadStatusState()
        {
            try
            {
                Match match = Regex.Match(File.ReadAllText(StatusPath, Encoding.UTF8), "\\\"State\\\"\\s*:\\s*\\\"([^\\\"]+)\\\"");
                return match.Success ? match.Groups[1].Value : null;
            }
            catch { return null; }
        }

        private static string JsonEscape(string value)
        {
            return (value ?? "").Replace("\\", "\\\\").Replace("\"", "\\\"").Replace("\r", "\\r").Replace("\n", "\\n");
        }
    }
}
