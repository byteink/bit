# Calendar invites

Inkwell's editors meet every Monday at nine. Kim wants the meeting to land in
each editor's calendar with Yes, No and Maybe buttons, the way a mail from
Google Calendar does, and to be able to move it or call it off later without
anyone ending up with two copies. That is one field on the message: `invite`,
an `Invite`.

<!-- doctest: per-block -->

## Inviting people

```bit
import { Invite, Mailer, Message, Options, Outbox } from "mail"
import { Minute, parseRfc3339 } from "std/time"
import { contains } from "std/strings"

fn main(): ()! {
  let start = parseRfc3339("2026-10-12T09:00:00Z")?
  let box = Outbox()
  let mailer = Mailer(box, Options{ from = "Kim Lee <kim@inkwell.dev>" })?
  mailer.send(
    Message{
      to = ["Sara Ali <sara@example.com>", "Lee Chen <lee@example.com>"],
      subject = "Editorial standup",
      text = "Monday, 09:00 UTC. The invite is attached.",
      invite = Option<Invite>.Some(
        Invite{
          uid = "standup-2026-10-12@inkwell.dev",
          start = start,
          end = start.add(30 * Minute),
          summary = "Editorial standup",
          location = "Room 4, second floor",
          description = "Bring this week's drafts.\nWe start with the calendar.",
        },
      ),
    },
  )?
  let raw = box.sent()[0].raw
  let part = "Content-Type: text/calendar; method=REQUEST; charset=UTF-8"
  println("calendar part: ${contains(raw, part)}")
  println("attachment: ${contains(raw, "filename=\"invite.ics\"")}")
  mailer.close()
  return
}
```

That prints `calendar part: true` and `attachment: true`. The mail carries the
event twice, because mail clients disagree about where to look. Gmail and
Outlook read the `text/calendar` part, the last alternative of the mail, and
draw the buttons from it (RFC 6047, the standard for calendar mail). Clients
that only look at attachments find the same bytes as `invite.ics`. The
`method=REQUEST` in the part's header and the `METHOD:REQUEST` in the event are
the same word, which is what a client checks before it trusts the buttons.

An `Invite` needs four things: a `uid`, a `start`, an `end` and a `summary`.
Times are read in UTC and written as `20261012T090000Z`; a fraction of a second
is dropped, since the format has none. `location` and `description` are
optional and left out of the event when empty. Commas, semicolons, backslashes
and line breaks in any text are escaped as the format requires, and long lines
are folded at 75 octets without cutting a character in two, so Arabic or
Japanese text arrives whole.

## Who is the organizer, who is invited

```bit
import { Invite, Message } from "mail"
import { Minute, parseRfc3339 } from "std/time"

fn main(): ()! {
  let start = parseRfc3339("2026-10-12T09:00:00Z")?
  let m = Message{
    from = "Inkwell <hello@inkwell.dev>",
    to = ["Sara Ali <sara@example.com>"],
    cc = ["Lee Chen <lee@example.com>"],
    bcc = ["audit@inkwell.dev"],
    subject = "Editorial standup",
    text = "Monday, 09:00 UTC.",
    invite = Option<Invite>.Some(
      Invite{
        uid = "standup-2026-10-12@inkwell.dev",
        start = start,
        end = start.add(30 * Minute),
        summary = "Editorial standup",
        organizer = "Kim Lee <kim@inkwell.dev>",
        attendees = ["Sara Ali <sara@example.com>"],
      },
    ),
  }
  match (m.invite) {
    Some(inv) => println("${inv.organizer} invites ${len(inv.attendees)}")
    None => println("no invite")
  }
  return
}
```

That prints `Kim Lee <kim@inkwell.dev> invites 1`. Left empty, `organizer` is the
message's From, which is the address Gmail and Outlook expect an invite to come
from, and `attendees` is `to` followed by `cc`. `bcc` is never an attendee,
because an attendee list is shown to everyone on it. Each attendee is written
with `ROLE=REQ-PARTICIPANT`, `PARTSTAT=NEEDS-ACTION` and `RSVP=TRUE`: a required
guest who has not answered and is asked to.

## Moving the meeting and calling it off

```bit
import { Invite, Method } from "mail"
import { Minute, parseRfc3339 } from "std/time"

fn main(): ()! {
  let start = parseRfc3339("2026-10-12T09:00:00Z")?
  let first = Invite{
    uid = "standup-2026-10-12@inkwell.dev",
    start = start,
    end = start.add(30 * Minute),
    summary = "Editorial standup",
  }
  let moved = Invite{
    uid = first.uid,
    start = start.add(60 * Minute),
    end = start.add(90 * Minute),
    summary = first.summary,
    sequence = first.sequence + 1,
  }
  let cancelled = Invite{
    uid = first.uid,
    start = moved.start,
    end = moved.end,
    summary = first.summary,
    method = Method.Cancel,
    sequence = moved.sequence + 1,
  }
  println("sequences: ${first.sequence} ${moved.sequence} ${cancelled.sequence}")
  return
}
```

That prints `sequences: 0 1 2`. A calendar knows an event by its `uid` alone,
so the invite, every update and the cancellation use the same one; a new `uid`
is a second meeting. `sequence` says which version is newest: it starts at 0
and goes up by one with each update and with the cancel, and a client ignores a
message whose sequence is lower than the one it already has. `method` is
`Method.Request` unless you set `Method.Cancel`; a cancel is written with
`STATUS:CANCELLED` and asks nobody to reply.

## What is refused

```bit
import { Invite, Mailer, Message, Method, Options, Outbox } from "mail"
import { Minute, parseRfc3339 } from "std/time"

fn main(): ()! {
  let start = parseRfc3339("2026-10-12T09:00:00Z")?
  let mailer = Mailer(Outbox(), Options{ from = "Kim Lee <kim@inkwell.dev>" })?
  let cancel = Invite{
    uid = "standup-2026-10-12@inkwell.dev",
    start = start,
    end = start.add(30 * Minute),
    summary = "Editorial standup",
    method = Method.Cancel,
  }
  mailer.send(
    Message{
      to = ["sara@example.com"],
      subject = "Editorial standup is off",
      text = "Not this week.",
      invite = Option<Invite>.Some(cancel),
    },
  ) catch e {
    println(e.message())
    mailer.close()
    return
  }
  mailer.close()
  return
}
```

That prints `mail: invite.sequence: is 0 on a CANCEL; a cancel must supersede
the request, so give it a sequence higher than the request's`. These are
mistakes in the program, so each one fails the send, naming the field:

| Mistake | Field |
|---|---|
| no `uid`, or a CR or LF in it | `invite.uid` |
| no `summary` | `invite.summary` |
| `end` not after `start`, or a year outside 1 to 9999 | `invite.end`, `invite.start` |
| a negative `sequence`, or 0 on a cancel | `invite.sequence` |
| a control character in a text field | `invite.location`, `invite.description` |
| an organizer or attendee that is not an address | `invite.organizer`, `invite.attendees[1]` |
| nobody to invite: no `attendees` and no `to` or `cc` | `invite.attendees` |

## Where to go next

[Messages](messages.md) lists every `Message` field. [The Mailer](mailer.md)
sends it, and its `Outbox` is how a test reads the calendar part back.
