# Scripting

<!-- doctest: per-block -->

Inkwell lets an author publish three articles a minute, no more. The obvious
code reads the author's recent publishes, counts them, and writes a new one
if there is room. Two requests for the same author arrive together, both read
"two so far", both write, and the author publishes four. The check and the
write have to happen as one step, and Redis has exactly that: a Lua script
runs on the server without another command getting in between.

```bit
import { open, Script, luaBool } from "redis"

const limiter: string = `
local t = redis.call('TIME')
local now = t[1] * 1000 + math.floor(t[2] / 1000)
redis.call('ZREMRANGEBYSCORE', KEYS[1], 0, now - tonumber(ARGV[2]))
if redis.call('ZCARD', KEYS[1]) >= tonumber(ARGV[1]) then
  return 0
end
local seq = redis.call('INCR', KEYS[2])
redis.call('ZADD', KEYS[1], now, now .. '-' .. seq)
redis.call('PEXPIRE', KEYS[1], ARGV[2])
redis.call('PEXPIRE', KEYS[2], ARGV[2])
return 1
`

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let canPublish = Script(limiter)
  let keys = ["{publish:ada}:hits", "{publish:ada}:seq"]
  let ok = canPublish.run(r, luaBool, keys = keys, args = ["3", "60000"])?
  if (ok) {
    println("published")
  } else {
    println("slow down")
  }
  r.close()
  return
}
```

`Script(source)` hashes the source once, when you create it. `run` sends
`EVALSHA` with that hash, so the Lua text crosses the network only the first
time a server sees it. Whatever you pass in `keys` shows up as `KEYS` in Lua
and `args` as `ARGV`, both numbered from 1.

Three things in the script are worth copying:

- `redis.call('TIME')` reads the server's clock, so every client agrees on
  "now" however skewed their own clocks are.
- Both keys carry the same `{publish:ada}` tag. Redis Cluster hashes only the
  text inside the braces, so the two keys land in one slot and one script can
  touch both. Without the shared tag a cluster refuses the call.
- Every key the script touches is in `keys`. A key built from `ARGV` inside
  the Lua source works on a single server and breaks on a cluster, because the
  server routes the call by `keys` alone.

## Reading the result

A script ends with a Lua value, so you say what type you expect. `run` takes
a decoder as its second argument; these ship with the package:

| Decoder | Lua value | Result |
| ------- | --------- | ------ |
| `luaInt` | a number | `i64` |
| `luaBool` | `true` / `false` or `nil` | `bool` |
| `luaOptString` | a string, or `nil` | `Option<string>` |
| `luaStrings` | a table of strings | `[]string` |
| `luaReply` | anything | the raw `Reply` |

Lua converts a number to an integer reply, so `return 3.7` arrives as `3`;
return it as a string (`tostring(x)`) when the fraction matters.

```bit
import { open, Script, luaInt, luaOptString, luaStrings, luaReply } from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?

  let bump = Script("return redis.call('INCRBY', KEYS[1], ARGV[1])")
  let total = bump.run(r, luaInt, keys = ["article:1:views"], args = ["1"])?
  println("${total} views")

  let title = Script("return redis.call('GET', KEYS[1])")
  match (title.run(r, luaOptString, keys = ["article:1:title"])?) {
    Some(t) => println(t)
    None => println("(no title)")
  }

  let both = Script("return {KEYS[1], ARGV[1]}")
  let pair = both.run(r, luaStrings, keys = ["a"], args = ["b"])?
  println("${pair[0]} ${pair[1]}")

  let raw = Script("return redis.status_reply('PONG')")
  match (raw.run(r, luaReply)?) {
    Simple(text) => println(text) // PONG
    _ => println("some other reply")
  }
  r.close()
  return
}
```

A decoder is just `(Reply) => T!RedisError`, so a closure works too when you
need a shape none of these fit.

## When the server has forgotten the script

A server only knows a script after it has seen it: a fresh server, a restart
and `SCRIPT FLUSH` all empty the cache. Then `EVALSHA` fails with `NOSCRIPT`.
`run` handles it: it sends `SCRIPT LOAD` with the source and repeats the call
once. You never see the error, and the common case (the script is cached)
costs one round trip. A second `NOSCRIPT` right after a successful load is
returned to you as `RedisError.NoScript`.

You can load ahead of time, and ask the server what it holds, through
`script.load(r)` and `ScriptCache`:

```bit
import { open, Script, ScriptCache, FlushMode } from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let s = Script("return 'ready'")

  let sha = s.load(r)?
  println("loaded ${sha}, the same hash as s.sha: ${sha == s.sha}")

  let cache = ScriptCache(r)
  let known = cache.exists([s.sha, "0000000000000000000000000000000000000000"])?
  println("${known[0]} ${known[1]}") // true false

  cache.flush(FlushMode.Sync)?
  println("${cache.exists([s.sha])?[0]}") // false, run() would load it again
  println(s.source)
  r.close()
  return
}
```

`FlushMode.Sync` frees the memory before the call returns; `FlushMode.Async`
returns first. The mode is required because the server's own default depends
on a setting, and a flush that blocks on one machine and not another is a
surprise nobody wants.

## In a pipeline or a transaction

A queued command has no reply until the whole batch runs, so a queued script
cannot notice `NOSCRIPT` and reload itself. Load it first, then queue
`script.cmd(...)`, which takes the same arguments as `run` and returns what
`Pipeline.queue` and `Tx.queue` expect:

```bit
import { open, Script, Future, luaInt } from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let bump = Script("return redis.call('INCRBY', KEYS[1], ARGV[1])")
  bump.load(r)? // safe to repeat, cheap when already loaded

  let p = r.pipeline()
  let a = p.queue(bump.cmd(luaInt, keys = ["article:1:views"], args = ["1"]))
  let b = p.queue(bump.cmd(luaInt, keys = ["article:2:views"], args = ["1"]))
  p.exec()?
  println("${a.get()?} ${b.get()?}")

  let views = r.transaction<Future<i64>>(["article:3:views"], (tx) => {
    return tx.queue(bump.cmd(luaInt, keys = ["article:3:views"], args = ["1"]))
  })?
  println("${views.get()?} views after the transaction")
  r.close()
  return
}
```

If you skip the load, `exec()` fails with `RedisError.NoScript`, the first
server error of the batch. The pipeline still reads every reply it asked for,
so the connection goes back to the pool clean, but no future is filled: load
the script and queue the batch again.

## Scripts that only read

`Script(source, readOnly = true)` sends `EVALSHA_RO`. The server then refuses
any write the script attempts, and, because running it twice is harmless, the
client retries it once on a dropped connection the way it retries `get`. A
replica accepts a read-only script; it refuses a plain one.

```bit
import { open, Script, luaOptString } from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let title = Script("return redis.call('GET', KEYS[1])", readOnly = true)
  match (title.run(r, luaOptString, keys = ["article:1:title"])?) {
    Some(t) => println(t)
    None => println("(no title)")
  }
  r.close()
  return
}
```

## Functions: a library the server keeps

A script is sent by your application, so every deployment carries its Lua.
A function lives on the server: you load a library once, and every client
calls its functions by name. Libraries survive a restart and `SCRIPT FLUSH`,
so there is no `NOSCRIPT` step.

```bit
import { open, Functions, Fn, FlushMode, luaBool, luaInt } from "redis"

const library: string = `#!lua name=inkwell
redis.register_function('can_publish', function(keys, args)
  local t = redis.call('TIME')
  local now = t[1] * 1000 + math.floor(t[2] / 1000)
  redis.call('ZREMRANGEBYSCORE', keys[1], 0, now - tonumber(args[2]))
  if redis.call('ZCARD', keys[1]) >= tonumber(args[1]) then
    return 0
  end
  redis.call('ZADD', keys[1], now, now)
  redis.call('PEXPIRE', keys[1], args[2])
  return 1
end)
redis.register_function{
  function_name = 'recent_publishes',
  callback = function(keys, args) return redis.call('ZCARD', keys[1]) end,
  flags = { 'no-writes' },
  description = 'how many publishes are inside the window',
}
`

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let fns = Functions(r)
  let name = fns.load(library, replace = true)?
  println("loaded ${name}")

  let can = Fn("can_publish")
  let ok = can.run(r, luaBool, keys = ["{publish:ada}:hits"], args = ["3", "60000"])?
  println("allowed: ${ok}")

  let count = Fn("recent_publishes", readOnly = true)
  println("${count.run(r, luaInt, keys = ["{publish:ada}:hits"])?} in the window")

  for lib of fns.list(libraryName = "inkwell")? {
    for f of lib.functions {
      println("${lib.name}.${f.name} ${f.flags}")
    }
  }

  fns.delete("inkwell")?
  fns.flush(FlushMode.Sync)?
  r.close()
  return
}
```

- `fns.load(code)` fails if a library of that name exists; `replace = true`
  swaps it in. Deploy new code with `replace = true`.
- `Fn(name, readOnly = true)` sends `FCALL_RO`, for functions registered with
  the `no-writes` flag.
- `fn.cmd(...)` is the pipeline and transaction form, exactly like
  `Script.cmd`, and needs no preload.
- `fns.list()` returns one `Library` per library: `name`, `engine`,
  `functions` and, with `withCode = true`, the source in `code`. Each
  `FunctionInfo` has `name`, `description` (an `Option`, since a function may
  have none) and `flags`.
- `fns.delete(name)` removes one library and fails if there is none by that
  name. `fns.flush(mode)` removes every library, so use it in tests, not in
  production.

## Sharp edges

- A script that runs too long makes the server answer other clients with
  `BUSY` (`RedisError.Busy`). Keep scripts short, and never loop over an
  unbounded set inside one.
- Blocking commands such as `BLPOP` behave as their non-blocking forms inside
  a script. Do waiting in your program.
- A script that writes is never retried by the client, even on a transport
  error, because it may already have run. Make it idempotent or accept the
  error.
- `SCRIPT FLUSH` and `FUNCTION FLUSH` are server-wide: they affect every
  application on that server.
- A write inside a `readOnly` script, or `FCALL_RO` of a function that is not
  flagged `no-writes`, fails with a normal `RedisError`, not a silent skip.

## Next

[Strings and keys](strings-and-keys.md) covers the commands a script usually
wraps, [Sorted sets](sorted-sets.md) the structure the rate limiter uses,
and [Connecting](connecting.md) the pool and timeouts `run` goes through.
