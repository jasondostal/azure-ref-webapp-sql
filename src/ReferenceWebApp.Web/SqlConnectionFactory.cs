using Microsoft.Data.SqlClient;

namespace ReferenceWebApp.Web;

/// <summary>Tiny factory so pages/endpoints get a fresh SqlConnection without
/// leaking the connection string around the app.</summary>
public sealed class SqlConnectionFactory(string connectionString)
{
    public SqlConnection Create() => new(connectionString);
}
