# Listening for changes: LISTEN and NOTIFY

Inkwell runs on three servers, and each one keeps the list of published
articles in memory. An editor publishes an article through server A. Servers
B and C keep serving the old list until their cache expires. You want them to
drop it the moment the article is published, without polling the database
every second.

Postgres has this built in. A session runs `LISTEN article_published`, and
from then on the server pushes a message to it whenever anyone runs
`NOTIFY article_published, 'some text'`. This package gives you both halves:
`notify` sends, and a `Listener` receives.

## Sending: notify

`notify` takes anything you can run statements on, a pool or a transaction.
Inside a transaction the notification is held until the transaction commits,
so a listener never hears about an article whose publish was rolled back:

```bit
import { Pool, Value, tx } from "std/sql"
import { notify } from "postgres"

fn publish(db: Pool, slug: string): ()! {
  tx(db, (t) => {
    t.exec("update articles set published = true where slug = $1", []Value{ Value.Text(slug) })?
    notify(t, "article_published", slug)?
  })?
}
```

The channel and the payload travel as bound parameters of
`select pg_notify($1, $2)`, so neither can change the statement. The payload
is any text up to 7999 bytes. Send an id and let the listener load the row;
do not send the row.

## Receiving: listen and next

`listen` opens a connection of its own and runs `LISTEN` on every channel you
name. It does not borrow from your pool, because a notification belongs to the
session that listened and a pooled connection is handed to someone else a
moment later. `next` waits up to the number of milliseconds you give it and
returns one event, or `None` if nothing came:

```bit
import { Event, Listener, listen } from "postgres"

fn onEvent(ev: Event) {
  match (ev) {
    Notify(n) => print("article ${n.payload} was published on ${n.channel} by backend ${n.pid}")
    Reconnected => print("connection was lost and restored")
  }
}

fn watch(uri: string, stop: () => bool): ()! {
  let l: Listener = listen(uri, ["article_published"])?
  while (!stop()) {
    let got = l.next(1000)?
    match (got) {
      None => continue
      Some(ev) => onEvent(ev)
    }
  }
  l.close()
}
```

The loop wakes once a second to check `stop`. That is how you shut a
listener down: `close` is for the thread that calls `next`, and a thread
blocked in `next` is not woken by another thread closing the listener.
`pid` is the backend that sent the notification. If the same program also
sends, compare it with `select pg_backend_pid()` on the sending connection to
skip your own messages.

Notifications are delivered in the order the server sent them, including ones
that arrive while `listen` is still running its `LISTEN` statements. A
duplicate `NOTIFY` of the same channel and payload in one transaction is
delivered once, which is the server's rule, not this package's.

## When the connection drops

A restart, a failover, a network cut, or an administrator running
`pg_terminate_backend` ends the session, and the server forgets what it had
queued for it. Notifications sent while you were disconnected are gone for
good. The listener cannot recover them, and it will not pretend it can.

What `next` does instead: it reconnects on its own, waiting 100 ms after the
first failed attempt and doubling up to 5 seconds, inside the time you gave
it. Once connected it runs every `LISTEN` again, and only then returns
`Event.Reconnected`, once, ahead of anything the new session delivers.
Notifications it had already read before the drop are delivered first. When
you see `Reconnected`, reload from the source of truth:

```bit
import { Event, Listener } from "postgres"

fn reloadPublished() {
  print("reloading the published list")
}

fn drain(l: Listener): ()! {
  let got = l.next(0)?
  match (got) {
    None => return
    Some(ev) => {
      match (ev) {
        Notify(n) => print("changed: ${n.payload}")
        Reconnected => reloadPublished()
      }
    }
  }
}
```

## Mistakes it refuses

`listen` fails on the first call, not later, for a URI that does not connect,
an empty channel list, and a channel name that is empty, contains a NUL byte,
or is longer than 63 bytes. The server cuts longer names silently, so the
name in a delivered notification would not be the one you asked for. Any other
name is fine: channel names go into `LISTEN` as quoted identifiers, so a name
holding a quote or a semicolon is one channel name, never a second statement.

During a reconnect, a failure that retrying cannot fix, such as a changed
password or a dropped database, makes `next` fail with the server's error and
closes the listener. Failures that mean the server is going away or not up
yet (SQLSTATE class 08, `57P01` to `57P03`, `53300`) and failures below the
database (the socket, DNS, TLS) are retried.

`notify` fails for an empty or oversized channel, and for a payload of 8000
bytes or more.

## Where to go next

[Errors](errors.md) covers telling a retryable failure from one that is not.
[Limitations](limitations.md) lists what a listener does not do yet.
