# std/uuid

Universally unique identifiers, per RFC 9562. A `UUID` is a fixed 128-bit value
you generate, format to the canonical `8-4-4-4-12` hex text, and parse back.

Three generators cover the common cases: `uuidV4` for a purely random id,
`uuidV5` for a deterministic name-based id, and `uuidV7` for a time-ordered id
whose values sort by creation time. Compare two UUIDs with `equals` - a class
`==` in v0.1 tests reference identity, not the 128 bits.

<!-- doctest: per-block -->

## The UUID value

### `UUID`

The 128-bit value. Its fields are private; obtain one from a generator, `parse`,
or a well-known constructor below.

### `UUID.version(): int`

The version number (4, 5, or 7 for the generators here).

### `UUID.variant(): int`

The variant field. Every UUID this module builds reports `2`, the RFC 4122/9562
variant.

### `equals(a: UUID, b: UUID): bool`

Whether two UUIDs are the same 128-bit value. Use this instead of `==`.

```bit
import { uuidV4, equals } from "std/uuid"

fn sameId(): bool {
  let id = uuidV4()
  return equals(id, id) && id.version() == 4 && id.variant() == 2
}
```

## Text form

### `format(u: UUID): string`

The canonical `8-4-4-4-12` lowercase-hex text, e.g.
`2ed6657d-e927-568b-95e1-2665a8aea6a2`.

### `parse(s: string): UUID!`

The UUID that `s` spells in canonical hex, case-insensitive. Fails on a wrong
length, a misplaced hyphen, or a non-hex digit. Round-trips with `format`:
`equals(parse(format(u)), u)` holds for every `u`.

```bit
import { uuidV4, parse, format, equals } from "std/uuid"

fn roundTrips(): bool! {
  let id = uuidV4()
  let back = parse(format(id))?
  return equals(back, id)
}
```

## Generating

### `uuidV4(): UUID`

A random UUID: 122 bits from the OS CSPRNG, with the version and variant fixed.

### `uuidV5(namespace: UUID, name: string): UUID`

A deterministic name-based UUID: SHA-1 over the namespace's 16 octets followed
by `name`, truncated to 128 bits. The same inputs always yield the same UUID.

### `uuidV7(): UUID`

A time-ordered UUID: a 48-bit Unix-millisecond prefix, then random bits. Two
values made in order sort in order, so v7 keys keep database indexes tidy.

```bit
import { uuidV5, uuidV7, format, namespaceDNS } from "std/uuid"

fn idFor(host: string): string {
  return format(uuidV5(namespaceDNS(), host))
}

fn timeOrderedId(): string {
  return format(uuidV7())
}
```

## Well-known UUIDs

### `nilUUID(): UUID`

The all-zero UUID, `00000000-0000-0000-0000-000000000000`.

### `maxUUID(): UUID`

The all-ones UUID, `ffffffff-ffff-ffff-ffff-ffffffffffff`.

### `namespaceDNS(): UUID`

The RFC 9562 DNS namespace, for `uuidV5` over a domain name.

### `namespaceURL(): UUID`

The RFC 9562 URL namespace, for `uuidV5` over a URL.

### `namespaceOID(): UUID`

The RFC 9562 ISO OID namespace, for `uuidV5` over an object identifier.

### `namespaceX500(): UUID`

The RFC 9562 X.500 DN namespace, for `uuidV5` over a distinguished name.

```bit
import { UUID, uuidV5, format, equals, nilUUID, maxUUID, namespaceURL } from "std/uuid"

fn urlId(url: string): string {
  return format(uuidV5(namespaceURL(), url))
}

fn isSpecial(u: UUID): bool {
  return equals(u, nilUUID()) || equals(u, maxUUID())
}
```
