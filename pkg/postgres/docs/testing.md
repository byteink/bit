# Testing

`./make test-package-postgres` runs everything that needs no server: the URI
parser, the startup exchange against an in-process fake backend that is a
real SCRAM server side (it derives `StoredKey`/`ServerKey` and verifies the
client's proof), so a forged server signature, a replayed nonce, a weak
iteration count and a missing server proof each fail - and the query layer
against a backend that decodes each frontend frame and answers it, which is
where "no named Parse across a hundred executions" is asserted against the
bytes that were sent.

`live.test.bit` adds the cases that need a real server. Each is skipped, out
loud, when its URI is unset:

```sh
docker run --rm -d --name pg-trust -e POSTGRES_HOST_AUTH_METHOD=trust \
  -p 127.0.0.1:5432:5432 postgres:16-alpine
docker run --rm -d --name pg-scram -e POSTGRES_PASSWORD=pw \
  -e POSTGRES_INITDB_ARGS="--auth-host=scram-sha-256" -p 127.0.0.1:55000:5432 postgres:16-alpine
# --auth-host=md5 matters: it makes initdb store the superuser's password as
# md5. With the default password_encryption=scram-sha-256, Postgres 14+
# answers an md5 line in pg_hba.conf with SASL anyway, and the md5 path is
# never taken.
docker run --rm -d --name pg-md5 -e POSTGRES_PASSWORD=pw \
  -e POSTGRES_HOST_AUTH_METHOD=md5 -e POSTGRES_INITDB_ARGS="--auth-host=md5" \
  -p 127.0.0.1:55001:5432 postgres:16-alpine
docker run --rm -d --name pg-password -e POSTGRES_PASSWORD=pw \
  -e POSTGRES_HOST_AUTH_METHOD=password -p 127.0.0.1:55003:5432 postgres:16-alpine

PG_TEST_TRUST_URI=postgres://postgres@127.0.0.1:5432/postgres \
PG_TEST_SCRAM_URI=postgres://postgres:pw@127.0.0.1:55000/postgres \
PG_TEST_MD5_URI=postgres://postgres:pw@127.0.0.1:55001/postgres \
PG_TEST_PASSWORD_URI=postgres://postgres:pw@127.0.0.1:55003/postgres \
  bit test pkg/postgres
```

`PG_TEST_TRUST_URI` alone covers the query layer: the parameter round trip
and its OIDs, the SQLSTATEs, the mid-result-set failure, and the cache,
which is counted from the server's own `pg_prepared_statements`. Any port
works - the one field-form test that needs 5432 skips out loud elsewhere:

```sh
docker run --rm -d --name pg-3988 -e POSTGRES_HOST_AUTH_METHOD=trust \
  -p 127.0.0.1:55010:5432 postgres:16-alpine
PG_TEST_TRUST_URI=postgres://postgres@127.0.0.1:55010/postgres ./make test-package-postgres
docker rm -f pg-3988
```

For `PG_TEST_TLS_URI`, turn `ssl` on in a container with a self-signed
certificate: generate `server.crt`/`server.key` into the data directory
(`openssl req -new -x509 -nodes -subj /CN=localhost`), `chmod 600` the key,
`chown postgres`, then `ALTER SYSTEM SET ssl='on'` and `SELECT
pg_reload_conf()`.
