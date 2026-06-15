using Microsoft.Data.SqlClient;
using ReferenceWebApp.Web;

var builder = WebApplication.CreateBuilder(args);

builder.Services.AddRazorPages();

// The connection string is injected by App Service as
// ConnectionStrings__DefaultConnection (set in Bicep). It uses
// Authentication=Active Directory Managed Identity — no secret here.
builder.Services.AddSingleton(sp =>
{
    var cs = builder.Configuration.GetConnectionString("DefaultConnection")
             ?? throw new InvalidOperationException("DefaultConnection is not configured.");
    return new SqlConnectionFactory(cs);
});

var app = builder.Build();

if (!app.Environment.IsDevelopment())
{
    app.UseExceptionHandler("/Error");
    app.UseHsts();
}

app.UseHttpsRedirection();
app.UseStaticFiles();
app.UseRouting();
app.MapRazorPages();

// Liveness — never touches SQL, so the platform can probe the app independently
// of the data tier.
app.MapGet("/healthz", () => Results.Ok("ok"));

// Readiness — proves the private path App Service → (VNet) → private endpoint →
// SQL works end to end with the managed identity.
app.MapGet("/readyz", async (SqlConnectionFactory factory) =>
{
    try
    {
        await using var conn = factory.Create();
        await conn.OpenAsync();
        await using var cmd = conn.CreateCommand();
        cmd.CommandText = "SELECT 1";
        await cmd.ExecuteScalarAsync();
        return Results.Ok("ready");
    }
    catch (Exception ex)
    {
        return Results.Problem($"SQL not reachable: {ex.Message}", statusCode: 503);
    }
});

app.Run();
