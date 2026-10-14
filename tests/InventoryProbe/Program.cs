// Drives the real scripts/redis/reserve.lua against a Redis instance and checks
// the per-product invariants in docs/inventory.md. Used by verify-inventory.ps1.
//   dotnet run --project tests/InventoryProbe -- <redis host:port> not-open <productId>
//   dotnet run --project tests/InventoryProbe -- <redis host:port> burst <productId>=<stock>[,...] <distinctOrders> <repeats> [weights]
using StackExchange.Redis;

var failures = 0;
void Check(string name, bool ok, string detail = "")
{
    Console.WriteLine((ok ? "PASS  " : "FAIL  ") + name + (ok || detail == "" ? "" : " -- " + detail));
    if (!ok) failures++;
}

var root = AppContext.BaseDirectory;
while (!File.Exists(Path.Combine(root, "scripts", "redis", "reserve.lua"))) root = Path.GetDirectoryName(root)!;
var script = File.ReadAllText(Path.Combine(root, "scripts", "redis", "reserve.lua"));
var mux = await ConnectionMultiplexer.ConnectAsync(args[0]);
var db = mux.GetDatabase();
Task<string> Reserve(string product, string order) =>
    db.ScriptEvaluateAsync(script, [$"inventory:{product}", $"processed:{product}", $"sale:open:{product}"], [order])
      .ContinueWith(t => (string)t.Result!);

switch (args[1])
{
    case "not-open":
    {
        var p = args[2];
        await db.StringSetAsync($"inventory:{p}", 5); // stock present, but no confirmed warm-up
        var r = await Reserve(p, "early-order");
        Check($"{p}: reservation before warm-up answers NOT_OPEN", r == "NOT_OPEN", r);
        Check($"{p}: stock untouched (5) and nothing recorded", (int)await db.StringGetAsync($"inventory:{p}") == 5 && await db.SetLengthAsync($"processed:{p}") == 0);
        await db.KeyDeleteAsync($"inventory:{p}");
        break;
    }
    case "burst":
    {
        var stocks = args[2].Split(',').Select(x => x.Split('=')).ToDictionary(x => x[0], x => int.Parse(x[1]));
        var distinct = int.Parse(args[3]);
        var repeats = int.Parse(args[4]);
        var weights = args.Length > 5 ? args[5].Split(',').Select(double.Parse).ToArray() : stocks.Keys.Select(_ => 1.0).ToArray();
        var products = stocks.Keys.ToArray();
        var rng = new Random(20261001);
        // Distinct orders spread over the products by weight (skew), then repeats of random earlier orders.
        var requests = new List<(string Product, string Order)>();
        for (var i = 0; i < distinct; i++)
        {
            var x = rng.NextDouble() * weights.Sum(); var k = 0;
            while (x > weights[k]) { x -= weights[k]; k++; }
            requests.Add((products[k], $"order-{i}"));
        }
        for (var i = 0; i < repeats; i++) requests.Add(requests[rng.Next(distinct)]);
        requests = requests.OrderBy(_ => rng.Next()).ToList();

        var results = await Task.WhenAll(requests.Select(r => Reserve(r.Product, r.Order)));
        Console.WriteLine($"INFO  {requests.Count} concurrent EVALs: " + string.Join(", ", results.GroupBy(x => x).Select(g => $"{g.Key}={g.Count()}")));
        Check("only RESERVED / DUPLICATE / REJECTED outcomes (sale open)", results.All(r => r is "RESERVED" or "DUPLICATE" or "REJECTED"));

        foreach (var p in products)
        {
            var initial = stocks[p];
            var demand = requests.Where(r => r.Product == p).Select(r => r.Order).Distinct().Count();
            var reserved = results.Where((r, i) => requests[i].Product == p && r == "RESERVED").Count();
            var inventory = (long)await db.StringGetAsync($"inventory:{p}");
            var processed = await db.SetLengthAsync($"processed:{p}");
            Check($"{p}: inventory >= 0 ({inventory})", inventory >= 0);
            Check($"{p}: reservations <= initial ({processed} <= {initial})", processed <= initial);
            Check($"{p}: stock conserved (inventory {inventory} + reservations {processed} = {initial})", inventory + processed == initial);
            Check($"{p}: RESERVED answers = recorded reservations = min(distinct demand {demand}, stock {initial})", reserved == processed && processed == Math.Min(demand, initial), $"reserved {reserved}, recorded {processed}");
        }
        // A repeat is DUPLICATE iff that order already held a unit when the repeat ran; never a second unit.
        var perOrder = requests.Select((r, i) => (r, res: results[i])).GroupBy(x => x.r).ToList();
        Check("no order id received RESERVED more than once", perOrder.All(g => g.Count(x => x.res == "RESERVED") <= 1));
        Check("every order that received DUPLICATE also holds a reservation", perOrder.Where(g => g.Any(x => x.res == "DUPLICATE")).All(g => g.Any(x => x.res == "RESERVED")));
        break;
    }
}
return failures == 0 ? 0 : 1;
