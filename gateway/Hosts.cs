using System.Globalization;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

// Host capacity (docs/design/plant-manager.md 4a): several worker sessions on one computer share its memory and CPU. A worker declares its host at
// registration (host=, the client's --host, default the computer's name); the plant then limits, per host, the items owned there and the private
// builds that run at once. A session that registers with effort "low" gets capacity schedule.lowEffortCapacity (1) unless the operator set its
// capacity. All of it is in memory, like the rest of the plant: a restart starts with no build slot held.
sealed class HostSettings
{
    public int DefaultOwned;                 // items owned at once per host; 0 = no host limit (each worker's own capacity still applies)
    public int DefaultBuilds = 1;            // private builds at once per host
    public int LowEffortCapacity = 1;        // the capacity of a session that registers with effort "low" (0 = no such rule)
    public double BuildSlotTtlSeconds = 1800, BuildSlotMaxTtlSeconds = 7200;
    public double BuildSlotDisconnectSeconds = 120;   // a session disconnected this long gives its build slots up (it is gone, not reconnecting)
    public Dictionary<string, (int Owned, int Builds)> Limits = new(StringComparer.OrdinalIgnoreCase);

    public static HostSettings Load(string scriptsDir)
    {
        var path = Environment.GetEnvironmentVariable("FACTORY_CONFIG") ?? Path.Combine(scriptsDir, "..", "..", "config", "instance.json");
        JsonNode? root = null; try { root = JsonNode.Parse(File.ReadAllText(path)); } catch { }
        var s = root?["schedule"];
        static bool Num(string? text, out double v) => double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out v) && double.IsFinite(v) && v >= 0;
        double D(string k, double d) => Num(Environment.GetEnvironmentVariable("FACTORY_TIMING_" + k), out var e) ? e : Num(s?[k]?.ToString(), out var v) ? v : d;
        var h = new HostSettings
        {
            DefaultOwned = (int)Math.Min(D("hostOwnedDefault", 0), 10000), DefaultBuilds = Math.Max(1, (int)Math.Min(D("hostBuildsDefault", 1), 10000)), LowEffortCapacity = (int)Math.Min(D("lowEffortCapacity", 1), 20),
            BuildSlotTtlSeconds = Math.Max(1, D("buildSlotTtlSeconds", 1800)), BuildSlotMaxTtlSeconds = Math.Max(1, D("buildSlotMaxTtlSeconds", 7200)),
            BuildSlotDisconnectSeconds = Math.Max(1, D("buildSlotDisconnectSeconds", 120))
        };
        if (s?["hosts"] is JsonObject hosts)
            foreach (var kv in hosts)
                if (Plant.ValidHost(kv.Key) && kv.Value is JsonObject lim)
                    h.Limits[kv.Key] = (Num(lim["owned"]?.ToString(), out var o) ? (int)o : h.DefaultOwned, Num(lim["builds"]?.ToString(), out var b) ? Math.Max(1, (int)b) : h.DefaultBuilds);
        return h;
    }
    public int OwnedLimit(string host) => Limits.TryGetValue(host, out var l) ? l.Owned : DefaultOwned;
    public int BuildLimit(string host) => Limits.TryGetValue(host, out var l) ? l.Builds : DefaultBuilds;
}

sealed partial class Plant
{
    public HostSettings Hosts { get; set; } = new();
    static readonly Regex HostRx = new(@"^[A-Za-z0-9][A-Za-z0-9._-]{0,62}\z", RegexOptions.CultureInvariant);
    public static bool ValidHost(string? h) => h != null && HostRx.IsMatch(h);
    readonly Dictionary<string, string> hostOf = new(StringComparer.Ordinal);   // worker name -> declared host (lower case)
    sealed record BuildSlot(string Id, string Host, string Name, int Item, DateTime Since, DateTime Until);
    readonly List<BuildSlot> buildSlots = new();
    long buildGrants, buildBusy, buildFreed;

    // Issue 108: a slot is held for a piece of work that can end without the slot's release (the item taken back or released, the item done, the
    // owner dropped, the session ended, revoked or gone); its ttl (30 min) was the only other end, so the host's next build waited behind a slot
    // nobody used. These free it when that work ends. Under the gate.
    // holder: the owner that is let go (its slots for the item; another session that named the item for a slot keeps its own), or null for all
    void FreeItemSlots(int item, string? holder, string why) { if (item > 0) FreeSlots(buildSlots.Where(s => s.Item == item && (holder == null || s.Name == holder)).ToList(), why); }
    void FreeNameSlots(string name, string why) => FreeSlots(buildSlots.Where(s => s.Name == name).ToList(), why);
    void FreeSlots(List<BuildSlot> gone, string why)
    {
        if (gone.Count == 0) return;
        foreach (var s in gone) buildSlots.Remove(s);
        buildFreed += gone.Count;
        Console.WriteLine(new JsonObject { ["at"] = DateTime.UtcNow.ToString("o"), ["buildSlot"] = "freed", ["why"] = why,
            ["slots"] = new JsonArray(gone.Select(s => (JsonNode)new JsonObject { ["name"] = s.Name, ["item"] = s.Item, ["host"] = s.Host }).ToArray()) }.ToJsonString());
    }
    // From the tick: the slots of a session that has been disconnected for schedule.buildSlotDisconnectSeconds (a reconnect within that time keeps them).
    void FreeSlotsOfGoneSessions(DateTime now)
    {
        if (buildSlots.Count == 0) return;
        foreach (var w in workers.Values.Where(w => !w.Connected && w.DisconnectedAt is { } d && (now - d).TotalSeconds >= Hosts.BuildSlotDisconnectSeconds).ToList())
            if (buildSlots.Any(s => s.Name == w.Name)) FreeNameSlots(w.Name, "disconnected");
    }

    // Called right after Register: the declared host, and the capacity rule of a low-effort profile (the operator's capacity wins).
    public void SetHost(string name, string host, string effort)
    {
        lock (gate)
        {
            if (ValidHost(host)) hostOf[name] = host.ToLowerInvariant(); else hostOf.Remove(name);
            if (string.Equals(effort, "low", StringComparison.OrdinalIgnoreCase) && Hosts.LowEffortCapacity > 0 && !capOverride.ContainsKey(name) && workers.TryGetValue(name, out var w)) w.Capacity = Math.Min(w.Capacity, Hosts.LowEffortCapacity);
        }
    }

    string HostOf(string name) => hostOf.TryGetValue(name, out var h) ? h : "";
    // Room on the worker's host for one more owned item (an offer out counts, as in Owned). A worker that declared no host has no host limit.
    bool HostHasRoom(string name)
    {
        var host = HostOf(name); if (host == "") return true;
        var limit = Hosts.OwnedLimit(host); if (limit <= 0) return true;
        return workers.Keys.Where(n => HostOf(n) == host).Sum(Owned) < limit;
    }

    // POST /api/v1/build-slot: acquire (or extend) and release a private-build slot of the caller's host. The holder is the session name and the item.
    public JsonObject BuildSlotRequest(string name, int item, string action, double? ttlSeconds)
    {
        lock (gate)
        {
            var now = DateTime.UtcNow;
            buildSlots.RemoveAll(s => s.Until <= now);
            var host = HostOf(name); var key = host != "" ? host : "session:" + name;      // no host declared: the session is its own host
            var limit = host != "" ? Hosts.BuildLimit(host) : Hosts.DefaultBuilds;
            var mine = buildSlots.FirstOrDefault(s => s.Name == name && s.Item == item);
            if (action == "release")
            {
                if (mine != null) buildSlots.Remove(mine);
                return new JsonObject { ["ok"] = true, ["released"] = mine != null, ["host"] = host, ["exit"] = 0 };
            }
            var ttl = Math.Clamp(ttlSeconds ?? Hosts.BuildSlotTtlSeconds, 1, Hosts.BuildSlotMaxTtlSeconds);
            if (mine != null)
            {
                buildSlots.Remove(mine); mine = mine with { Until = now.AddSeconds(ttl) }; buildSlots.Add(mine);
                return Granted(mine, true);
            }
            var held = buildSlots.Where(s => s.Host == key).ToList();
            if (held.Count >= limit)
            {
                buildBusy++;
                var next = held.Min(s => s.Until);
                return new JsonObject
                {
                    ["ok"] = false, ["code"] = "build-slot-busy", ["host"] = host, ["limit"] = limit, ["held"] = held.Count,
                    ["holders"] = new JsonArray(held.Select(s => (JsonNode)new JsonObject { ["name"] = s.Name, ["item"] = s.Item, ["until"] = s.Until.ToString("o") }).ToArray()),
                    ["retryAfterSeconds"] = Math.Clamp((int)Math.Ceiling((next - now).TotalSeconds), 5, 120),
                    ["reason"] = $"the {limit} private-build slot(s) of this host are held; wait and ask again (the slot of a build that ended without release frees itself at its ttl, or when its item or session ends)", ["exit"] = 21
                };
            }
            var slot = new BuildSlot("b-" + Interlocked.Increment(ref counter).ToString("x"), key, name, item, now, now.AddSeconds(ttl));
            buildSlots.Add(slot); buildGrants++;
            return Granted(slot, false);
            JsonObject Granted(BuildSlot s, bool extended) => new() { ["ok"] = true, ["granted"] = true, ["extended"] = extended, ["slot"] = s.Id, ["host"] = host, ["until"] = s.Until.ToString("o"), ["ttlSeconds"] = (int)ttl, ["exit"] = 0 };
        }
    }

    // The block of /api/v1/status: every host with its sessions, items owned, and build slots held.
    public JsonObject HostStatus()
    {
        lock (gate)
        {
            var now = DateTime.UtcNow; buildSlots.RemoveAll(s => s.Until <= now);
            var hosts = new JsonArray();
            foreach (var g in workers.Keys.Where(n => HostOf(n) != "").GroupBy(HostOf).OrderBy(g => g.Key, StringComparer.Ordinal))
                hosts.Add(new JsonObject
                {
                    ["host"] = g.Key, ["workers"] = new JsonArray(g.OrderBy(n => n, StringComparer.Ordinal).Select(n => (JsonNode)n).ToArray()), ["owned"] = g.Sum(Owned),
                    ["ownedLimit"] = Hosts.OwnedLimit(g.Key), ["builds"] = buildSlots.Count(s => s.Host == g.Key), ["buildLimit"] = Hosts.BuildLimit(g.Key)
                });
            return new JsonObject { ["hosts"] = hosts, ["buildSlotsHeld"] = buildSlots.Count, ["buildGrants"] = buildGrants, ["buildBusy"] = buildBusy, ["buildFreed"] = buildFreed };
        }
    }
}
