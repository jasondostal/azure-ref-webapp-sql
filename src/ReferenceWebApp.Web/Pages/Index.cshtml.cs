using Microsoft.AspNetCore.Mvc.RazorPages;

namespace ReferenceWebApp.Web.Pages;

public class IndexModel(SqlConnectionFactory factory) : PageModel
{
    public string SqlStatus { get; private set; } = "unknown";
    public string? ServerName { get; private set; }
    public string? Error { get; private set; }

    public async Task OnGetAsync()
    {
        try
        {
            await using var conn = factory.Create();
            await conn.OpenAsync();
            await using var cmd = conn.CreateCommand();
            // @@SERVERNAME confirms WHICH server we reached over the private path.
            cmd.CommandText = "SELECT @@SERVERNAME";
            ServerName = (await cmd.ExecuteScalarAsync())?.ToString();
            SqlStatus = "connected";
        }
        catch (Exception ex)
        {
            SqlStatus = "unreachable";
            Error = ex.Message;
        }
    }
}
