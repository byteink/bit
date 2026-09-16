// ASP.NET Core's side of the tier 1-2 comparison (#5418). ContentLength is set
// on both routes: without it Kestrel frames the response chunked, which is
// more wire bytes than the other five servers send for the same body.
using System.Text;
using System.Text.Json;

var builder = WebApplication.CreateBuilder(args);
builder.Logging.ClearProviders();
var app = builder.Build();

var plaintext = Encoding.UTF8.GetBytes("Hello, World!");

app.MapGet("/plaintext", async context =>
{
    context.Response.ContentType = "text/plain; charset=utf-8";
    context.Response.ContentLength = plaintext.Length;
    await context.Response.Body.WriteAsync(plaintext);
});

app.MapGet("/json", async context =>
{
    var body = JsonSerializer.SerializeToUtf8Bytes(new { message = "Hello, World!" });
    context.Response.ContentType = "application/json";
    context.Response.ContentLength = body.Length;
    await context.Response.Body.WriteAsync(body);
});

app.Run("http://0.0.0.0:8086");
