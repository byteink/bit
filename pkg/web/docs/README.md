# pkg/web docs

The chapters below, in reading order. This table is the order the website
reads them; a chapter not listed here would be appended alphabetically
instead of dropped, so keeping it current is part of writing a chapter.

| Chapter | Covers |
| ------- | ------ |
| [Getting started](getting-started.md) | Install, build an `App`, and answer your first request. |
| [Routing](routing.md) | Register routes on the trie, capture params and wildcards, and name a route to link to it. |
| [The request](request.md) | The client address, reading `Ctx`, and binding and validating the body. |
| [The response](response.md) | Building a `Res`, the `Node` HTML tree, and escaping. |
| [Middleware](middleware.md) | `app.use`/`group.use`, how far each one's scope reaches, and error handlers. |
| [Sessions, CSRF and security](security.md) | Server-side sessions, the CSRF token that binds to one, CORS and the standard security headers. |
| [Operational middleware](operations.md) | Rate limiting, serving static files, gzip, request logging, tracing and panic recovery. |
| [Errors](errors.md) | The `HttpError` opt-in that decides what a client is allowed to read. |
| [Configuration](configuration.md) | Every `Config` field, what has no default, and why. |

For install and a minimal example, see [`pkg/web/README.md`](../README.md).
