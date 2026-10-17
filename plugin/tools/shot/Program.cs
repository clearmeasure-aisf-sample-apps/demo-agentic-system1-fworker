// shot install                                                       download the Chromium browser (and the bundled ffmpeg) once
// shot --base http://localhost:5174 --out DIR [--paths "/,/other"] [--login USER] [--wait SECONDS] [--video] [--width 1280 --height 800]
//      opens each path in a headless browser, logs in as USER first when given (the work-orders login page: LoginLink, User, LoginButton),
//      writes DIR/shot-<n>.png for each path and, with --video, DIR/flow.webm (the context is closed so the file is complete).
// Prints one JSON line: {ok, shots:[{path, file, title, status, text}], video}. The page text (first 1500 characters) lets a model judge
// the page without looking at the image; open the PNG too when the evidence is visual.
using System.Text.Json;
using Microsoft.Playwright;

if (args.Length > 0 && args[0] == "install") return Microsoft.Playwright.Program.Main(new[] { "install", "chromium" });

var o = new Dictionary<string, string>();
for (var i = 0; i < args.Length; i++) if (args[i].StartsWith("--")) { o[args[i][2..]] = i + 1 < args.Length && !args[i + 1].StartsWith("--") ? args[++i] : "true"; }
string Opt(string k, string d) => o.TryGetValue(k, out var v) ? v : d;
var baseUrl = Opt("base", "http://localhost:5174").TrimEnd('/');
var outDir = Opt("out", Path.Combine(Path.GetTempPath(), "app-shots")); Directory.CreateDirectory(outDir);
var paths = Opt("paths", "/").Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
var width = int.Parse(Opt("width", "1280")); var height = int.Parse(Opt("height", "800"));
var wantVideo = o.ContainsKey("video"); var settle = int.Parse(Opt("wait", "2"));

var shots = new List<object>();
string? video = null;
try
{
    using var pw = await Playwright.CreateAsync();
    await using var browser = await pw.Chromium.LaunchAsync(new() { Headless = true, Args = new[] { "--disable-dev-shm-usage" } });
    var ctxOptions = new BrowserNewContextOptions { BaseURL = baseUrl, IgnoreHTTPSErrors = true, ViewportSize = new() { Width = width, Height = height } };
    if (wantVideo) { ctxOptions.RecordVideoDir = outDir; ctxOptions.RecordVideoSize = new() { Width = width, Height = height }; }
    await using var ctx = await browser.NewContextAsync(ctxOptions);
    ctx.SetDefaultTimeout(60_000);
    var page = await ctx.NewPageAsync();

    if (o.TryGetValue("login", out var user))
    {
        await page.GotoAsync("/");
        await page.GetByTestId("LoginLink").ClickAsync();
        await page.WaitForURLAsync("**/login");
        await page.GetByTestId("User").SelectOptionAsync(user);
        await page.GetByTestId("LoginButton").ClickAsync();
        await page.WaitForLoadStateAsync(LoadState.NetworkIdle);
    }

    var n = 0;
    foreach (var p in paths)
    {
        n++;
        var resp = await page.GotoAsync(p, new() { WaitUntil = WaitUntilState.NetworkIdle });
        await page.WaitForTimeoutAsync(settle * 1000);
        var file = Path.Combine(outDir, $"shot-{n}.png");
        await page.ScreenshotAsync(new() { Path = file, FullPage = true });
        var text = (await page.InnerTextAsync("body")) ?? "";
        shots.Add(new { path = p, file, title = await page.TitleAsync(), status = resp?.Status ?? 0, text = text.Length > 1500 ? text[..1500] : text });
    }
    if (wantVideo && page.Video is not null) { await page.CloseAsync(); video = await page.Video.PathAsync(); }
}
catch (Exception e)
{
    Console.WriteLine(JsonSerializer.Serialize(new { ok = false, code = "shot-failed", reason = e.Message.Split('\n')[0], shots }));
    return 20;
}
Console.WriteLine(JsonSerializer.Serialize(new { ok = true, shots, video }));
return 0;
