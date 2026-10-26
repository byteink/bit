# HTTP/2 frame codecs

The [connection engine](http2.md) handles these frames for ordinary programs.
Use these codecs when building or inspecting an HTTP/2 peer.

<!-- doctest: per-block -->

## Inspecting a draft response

To inspect a peer, first decode its frame header, then decode the matching
payload. This example round-trips the frame shapes an inspector can receive.
The header fragments contain opaque compressed bytes; use the connection
engine when you need it to manage compression and stream state for you.

```bit
import {
  FrameHeader, Frame, DataFrame, HeadersFrame, PriorityFrame, RstStreamFrame,
  Setting, SettingsFrame, PushPromiseFrame, PingFrame, GoawayFrame,
  WindowUpdateFrame, ContinuationFrame, encodeFrameHeader, decodeFrameHeader,
  readFrame, encodeData, decodeData, encodeHeaders, decodeHeaders,
  encodePriority, decodePriority, encodeRstStream, decodeRstStream,
  encodeSettings, decodeSettings, encodePushPromise, decodePushPromise,
  encodePing, decodePing, encodeGoaway, decodeGoaway, encodeWindowUpdate,
  decodeWindowUpdate, encodeContinuation, decodeContinuation,
  frameData, frameHeaders, framePriority, frameRstStream, frameSettings,
  framePushPromise, framePing, frameGoaway, frameWindowUpdate, frameContinuation,
  flagEndStream, flagEndHeaders, flagPadded, flagPriority, flagAck,
  settingsHeaderTableSize, settingsEnablePush, settingsMaxConcurrentStreams,
  settingsInitialWindowSize, settingsMaxFrameSize, settingsMaxHeaderListSize,
  settingsEnableConnectProtocol, defaultMaxFrameSize, maxMaxFrameSize,
  errorNoError, errorProtocolError, errorInternalError, errorFlowControlError,
  errorSettingsTimeout, errorStreamClosed, errorFrameSizeError, errorRefusedStream,
  errorCancel, errorCompressionError, errorConnectError, errorEnhanceYourCalm,
  errorInadequateSecurity, errorHttp11Required,
} from "std/http2"

fn knownFrame(frame: Frame): bool {
  let types = [
    frameData, frameHeaders, framePriority, frameRstStream, frameSettings,
    framePushPromise, framePing, frameGoaway, frameWindowUpdate, frameContinuation,
  ]
  for code of types {
    if (frame.header.ftype == code) {
      return true
    }
  }
  return false
}

fn inspectDraft(): ()! {
  let header = FrameHeader{ length = 5, ftype = frameData, flags = flagEndStream, streamId = 1 }
  assert(decodeFrameHeader(encodeFrameHeader(header)?)?.streamId == 1)
  let data = DataFrame{ streamId = 1, data = []byte("draft"), endStream = true, padLength = -1 }
  let frame = readFrame(encodeData(data)?, defaultMaxFrameSize)?
  assert(knownFrame(frame) && string(decodeData(frame)?.data) == "draft")
  let headers = HeadersFrame{
    streamId = 1, blockFragment = []byte(0), endStream = false,
    endHeaders = true, padLength = -1, hasPriority = false, exclusive = false,
    streamDependency = 0, weight = 16,
  }
  assert(decodeHeaders(readFrame(encodeHeaders(headers)?, defaultMaxFrameSize)?)?.endHeaders)
  let priority = PriorityFrame{ streamId = 1, exclusive = false, streamDependency = 0, weight = 16 }
  assert(decodePriority(readFrame(encodePriority(priority)?, defaultMaxFrameSize)?)?.weight == 16)
  let reset = RstStreamFrame{ streamId = 1, errorCode = errorCancel }
  assert(
      decodeRstStream(readFrame(encodeRstStream(reset)?, defaultMaxFrameSize)?)?.errorCode ==
      errorCancel,
  )
  let settings = [
    Setting{ id = settingsHeaderTableSize, value = 4096 },
    Setting{ id = settingsEnablePush, value = 0 },
    Setting{ id = settingsMaxConcurrentStreams, value = 8 },
    Setting{ id = settingsInitialWindowSize, value = 65535 },
    Setting{ id = settingsMaxFrameSize, value = defaultMaxFrameSize },
    Setting{ id = settingsMaxHeaderListSize, value = 8192 },
    Setting{ id = settingsEnableConnectProtocol, value = 1 },
  ]
  let config = SettingsFrame{ ack = false, settings = settings }
  assert(len(decodeSettings(readFrame(encodeSettings(config)?, maxMaxFrameSize)?)?.settings) == 7)
  let push = PushPromiseFrame{
    streamId = 1, promisedStreamId = 2,
    blockFragment = []byte(0), endHeaders = true, padLength = -1,
  }
  assert(
      decodePushPromise(readFrame(encodePushPromise(push)?, defaultMaxFrameSize)?)?.promisedStreamId ==
      2,
  )
  let ping = PingFrame{ ack = false, data = []byte("draft-id") }
  assert(string(decodePing(readFrame(encodePing(ping)?, defaultMaxFrameSize)?)?.data) == "draft-id")
  let goodbye = GoawayFrame{ lastStreamId = 1, errorCode = errorNoError, debugData = []byte(0) }
  assert(decodeGoaway(readFrame(encodeGoaway(goodbye)?, defaultMaxFrameSize)?)?.lastStreamId == 1)
  let credit = WindowUpdateFrame{ streamId = 1, increment = 4096 }
  assert(
      decodeWindowUpdate(readFrame(encodeWindowUpdate(credit)?, defaultMaxFrameSize)?)?.increment ==
      4096,
  )
  let continued = ContinuationFrame{ streamId = 1, blockFragment = []byte(0), endHeaders = true }
  assert(decodeContinuation(readFrame(encodeContinuation(continued)?, defaultMaxFrameSize)?)?.endHeaders)
}

fn inspectFlags(flags: int): []bool {
  return [
    (flags & flagEndStream) != 0, (flags & flagEndHeaders) != 0,
    (flags & flagPadded) != 0, (flags & flagPriority) != 0, (flags & flagAck) != 0,
  ]
}

fn knownError(code: int): bool {
  let codes = [
    errorNoError, errorProtocolError, errorInternalError, errorFlowControlError,
    errorSettingsTimeout, errorStreamClosed, errorFrameSizeError, errorRefusedStream,
    errorCancel, errorCompressionError, errorConnectError, errorEnhanceYourCalm,
    errorInadequateSecurity, errorHttp11Required,
  ]
  for value of codes {
    if (value == code) {
      return true
    }
  }
  return false
}

fn main(): ()! {
  inspectDraft()?
  assert(inspectFlags(flagEndStream)[0])
  assert(knownError(errorCancel))
}
```

`inspectFlags` reports bits only. Their meaning depends on the frame type:
ACK and END_STREAM share the same bit, for example. Unknown frame types and
error codes are possible; retain their numeric values when you log them.

## The frame header

Every HTTP/2 message is a stream of frames: a fixed 9-byte header followed by
a type-specific payload.

### `FrameHeader`

A parsed frame header: the payload `length`, the frame type `ftype`, the
`flags`, and the `streamId` it belongs to.

### `Frame`

A whole frame: its `header` and the raw `payload` bytes. `readFrame` produces
one; a `decode*` function turns it into a typed frame such as `DataFrame`.

### `encodeFrameHeader(h: FrameHeader): []byte!`

The 9 wire bytes of a frame header.

### `decodeFrameHeader(b: []byte): FrameHeader!`

The frame header the first 9 bytes of `b` spell out. Fails on fewer than 9
bytes.

### `readFrame(buf: []byte, maxFrameSize: int): Frame!`

Reads one whole frame off the front of `buf`, rejecting a frame larger than
`maxFrameSize`. Advance past `9 + frame.header.length` bytes to read the next
one.

## Frame types

The ten frame type codes, used on `FrameHeader.ftype` to tell frames apart.

### `frameData: int`

DATA: a piece of a stream's message body.

### `frameHeaders: int`

HEADERS: opens a stream and carries a header block.

### `framePriority: int`

PRIORITY: a stream's priority dependency and weight.

### `frameRstStream: int`

RST_STREAM: abrupt termination of a stream.

### `frameSettings: int`

SETTINGS: connection configuration parameters.

### `framePushPromise: int`

PUSH_PROMISE: a server's promise to push a stream.

### `framePing: int`

PING: a connection liveness probe.

### `frameGoaway: int`

GOAWAY: connection shutdown, naming the last stream processed.

### `frameWindowUpdate: int`

WINDOW_UPDATE: a flow-control window increment.

### `frameContinuation: int`

CONTINUATION: a continued header block.

## Frame flags

The frame flag bits, read from `FrameHeader.flags`.

### `flagEndStream: int`

END_STREAM on DATA/HEADERS: this is the last frame for the stream.

### `flagEndHeaders: int`

END_HEADERS on HEADERS/PUSH_PROMISE/CONTINUATION: the header block is
complete.

### `flagPadded: int`

PADDED on DATA/HEADERS/PUSH_PROMISE: the payload carries padding.

### `flagPriority: int`

PRIORITY on HEADERS: a priority section precedes the header block.

### `flagAck: int`

ACK on SETTINGS/PING: this frame acknowledges the peer's frame.

## Settings parameter ids

The six SETTINGS parameter ids, used on `Setting.id`.

### `settingsHeaderTableSize: int`

The HPACK dynamic-table size limit the sender advertises.

### `settingsEnablePush: int`

Whether server push is permitted.

### `settingsMaxConcurrentStreams: int`

The most streams the sender will allow open at once.

### `settingsInitialWindowSize: int`

The initial per-stream flow-control window the sender grants.

### `settingsMaxFrameSize: int`

The largest frame payload the sender accepts.

### `settingsMaxHeaderListSize: int`

The largest header list the sender accepts.

### `settingsEnableConnectProtocol: int`

Whether the sender accepts extended CONNECT requests (RFC 8441): `1` allows them.
Only `0` and `1` are legal, and a sender must not go from `1` back to `0`; the
engine treats either as a connection error.

## Frame-size bounds

### `defaultMaxFrameSize: int`

The default and minimum allowed max frame size, 16384 bytes.

### `maxMaxFrameSize: int`

The largest allowed max frame size, the widest value the 24-bit length field
can hold.

## Error codes

The error codes a stream or connection can be closed with, used on
`RstStreamFrame.errorCode` and `GoawayFrame.errorCode`.

### `errorNoError: int`

Graceful shutdown, no problem occurred.

### `errorProtocolError: int`

An unspecified protocol violation.

### `errorInternalError: int`

An internal fault on the sender's side.

### `errorFlowControlError: int`

A flow-control window was exceeded.

### `errorSettingsTimeout: int`

A SETTINGS frame was not acknowledged in time.

### `errorStreamClosed: int`

A frame arrived on a stream that was already closed.

### `errorFrameSizeError: int`

A frame's size was invalid for its type.

### `errorRefusedStream: int`

The stream was refused before any processing, safe to retry elsewhere.

### `errorCancel: int`

The stream is no longer needed.

### `errorCompressionError: int`

The HPACK decoder state could not be recovered.

### `errorConnectError: int`

A CONNECT tunnel failed.

### `errorEnhanceYourCalm: int`

The peer is generating more load than will be processed.

### `errorInadequateSecurity: int`

The transport is not secure enough for this request.

### `errorHttp11Required: int`

The peer requires HTTP/1.1 for this request.

## DATA frames

### `DataFrame`

A DATA frame: `streamId`, the body `data`, `endStream`, and `padLength`.

### `encodeData(f: DataFrame): []byte!`

The wire bytes of a DATA frame.

### `decodeData(f: Frame): DataFrame!`

The DATA frame `f` carries. Fails if `f` is not a DATA frame.

## HEADERS frames

### `HeadersFrame`

A HEADERS frame: `streamId`, the header block `blockFragment`, `endStream`,
`endHeaders`, `padLength`, and an optional priority section.

### `encodeHeaders(f: HeadersFrame): []byte!`

The wire bytes of a HEADERS frame.

### `decodeHeaders(f: Frame): HeadersFrame!`

The HEADERS frame `f` carries. Fails if `f` is not a HEADERS frame.

## PRIORITY frames

### `PriorityFrame`

A PRIORITY frame: `streamId`, `exclusive`, `streamDependency`, and `weight`.

### `encodePriority(f: PriorityFrame): []byte!`

The wire bytes of a PRIORITY frame.

### `decodePriority(f: Frame): PriorityFrame!`

The PRIORITY frame `f` carries. Fails if `f` is not a PRIORITY frame.

## RST_STREAM frames

### `RstStreamFrame`

A RST_STREAM frame: `streamId` and the `errorCode` it is reset with.

### `encodeRstStream(f: RstStreamFrame): []byte!`

The wire bytes of a RST_STREAM frame.

### `decodeRstStream(f: Frame): RstStreamFrame!`

The RST_STREAM frame `f` carries. Fails if `f` is not a RST_STREAM frame.

## SETTINGS frames

### `Setting`

One SETTINGS parameter: an `id` (a `settings*` constant) and its `value`.

### `SettingsFrame`

A SETTINGS frame: either `ack` set, or a list of `settings`.

### `encodeSettings(f: SettingsFrame): []byte!`

The wire bytes of a SETTINGS frame.

### `decodeSettings(f: Frame): SettingsFrame!`

The SETTINGS frame `f` carries. Fails if `f` is not a SETTINGS frame.

## PUSH_PROMISE frames

### `PushPromiseFrame`

A PUSH_PROMISE frame: the carrying `streamId`, the `promisedStreamId`, the
request headers in `blockFragment`, `endHeaders`, and `padLength`.

### `encodePushPromise(f: PushPromiseFrame): []byte!`

The wire bytes of a PUSH_PROMISE frame.

### `decodePushPromise(f: Frame): PushPromiseFrame!`

The PUSH_PROMISE frame `f` carries. Fails if `f` is not a PUSH_PROMISE frame.

## PING frames

### `PingFrame`

A PING frame: 8 opaque `data` bytes, echoed back with `ack` set.

### `encodePing(f: PingFrame): []byte!`

The wire bytes of a PING frame.

### `decodePing(f: Frame): PingFrame!`

The PING frame `f` carries. Fails if `f` is not a PING frame.

## GOAWAY frames

### `GoawayFrame`

A GOAWAY frame: the `lastStreamId` processed, an `errorCode`, and optional
`debugData`.

### `encodeGoaway(f: GoawayFrame): []byte!`

The wire bytes of a GOAWAY frame.

### `decodeGoaway(f: Frame): GoawayFrame!`

The GOAWAY frame `f` carries. Fails if `f` is not a GOAWAY frame.

## WINDOW_UPDATE frames

### `WindowUpdateFrame`

A WINDOW_UPDATE frame: a flow-control `increment`. `streamId` 0 targets the
whole connection; a non-zero id targets that stream.

### `encodeWindowUpdate(f: WindowUpdateFrame): []byte!`

The wire bytes of a WINDOW_UPDATE frame.

### `decodeWindowUpdate(f: Frame): WindowUpdateFrame!`

The WINDOW_UPDATE frame `f` carries. Fails if `f` is not a WINDOW_UPDATE
frame.

## CONTINUATION frames

### `ContinuationFrame`

A CONTINUATION frame: `streamId`, a continued `blockFragment`, and
`endHeaders`.

### `encodeContinuation(f: ContinuationFrame): []byte!`

The wire bytes of a CONTINUATION frame.

### `decodeContinuation(f: Frame): ContinuationFrame!`

The CONTINUATION frame `f` carries. Fails if `f` is not a CONTINUATION frame.

