# pkg/webredis docs

The chapters below, in reading order. This table is the order the website
reads them; a chapter not listed here would be appended alphabetically
instead of dropped, so keeping it current is part of writing a chapter.

| Chapter | Covers |
| ------- | ------ |
| [Idempotency keys across servers](idempotency.md) | `RedisIdempotencyStore`: `web`'s `idempotency` middleware over Redis, the atomic `SET ... NX GET`, what is stored, whose reservation is whose, failures. |

For install and a minimal example, see [`pkg/webredis/README.md`](../README.md).
