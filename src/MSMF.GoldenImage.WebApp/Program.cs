using System.Reflection;

var builder = WebApplication.CreateBuilder(args);
builder.Services.AddHealthChecks();

var app = builder.Build();

// Liveness/readiness endpoint used by boot diagnostics and Octopus health checks.
app.MapHealthChecks("/healthz");

app.MapGet("/", (IConfiguration config) =>
{
    var version = Assembly.GetExecutingAssembly().GetName().Version?.ToString() ?? "1.0.0";

    // "Msmf:Environment" is replaced in appsettings.json per environment by the
    // Octopus JSON-configuration-variables feature, so the page below shows the
    // config that travels with the release as it is promoted Dev -> Test -> Prod.
    var environment = config["Msmf:Environment"] ?? app.Environment.EnvironmentName;
    var machine = Environment.MachineName;

    var html = $$"""
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8" />
      <meta name="viewport" content="width=device-width, initial-scale=1" />
      <title>MSMF Golden Image App</title>
      <style>
        :root { color-scheme: light dark; }
        body { font-family: 'Segoe UI', system-ui, sans-serif; margin: 0; padding: 3rem;
               background: #0b1f33; color: #f4f7fb; }
        .card { max-width: 640px; margin: auto; background: #12283f; border-radius: 14px;
                padding: 2.5rem; box-shadow: 0 12px 40px rgba(0,0,0,.35); }
        h1 { margin: 0 0 .25rem; font-size: 1.6rem; }
        p  { color: #c6d5e6; }
        .badge { display: inline-block; padding: .2rem .7rem; border-radius: 999px;
                 background: #1d84ff; font-size: .8rem; font-weight: 600; letter-spacing: .02em; }
        dl { display: grid; grid-template-columns: auto 1fr; gap: .5rem 1rem; margin-top: 1.75rem; }
        dt { color: #9db4cc; } dd { margin: 0; font-variant-numeric: tabular-nums; }
        footer { margin-top: 2rem; color: #6f8bab; font-size: .8rem; }
      </style>
    </head>
    <body>
      <div class="card">
        <span class="badge">MS Migration Factory</span>
        <h1>Golden Image IIS Web App</h1>
        <p>Deployed to IIS by Octopus Deploy from a golden-image VM.</p>
        <dl>
          <dt>Environment</dt><dd>{{environment}}</dd>
          <dt>Machine</dt><dd>{{machine}}</dd>
          <dt>Version</dt><dd>{{version}}</dd>
          <dt>Served (UTC)</dt><dd>{{DateTime.UtcNow:yyyy-MM-dd HH:mm:ss}}</dd>
        </dl>
        <footer>project=msmf-golden-image &middot; IIS + Octopus Tentacle &middot; net8.0 / ANCM</footer>
      </div>
    </body>
    </html>
    """;

    return Results.Content(html, "text/html; charset=utf-8");
});

app.Run();
