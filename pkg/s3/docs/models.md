<!-- doctest: per-block -->

# Keep storage values and response details

When Inkwell saves a storage setting, save the value the service expects.
`wire()` gives you that value. `fromWire()` reads it back without losing a
value a service adds later.

## Prepare and save an article cover

An Inkwell device may download a cover larger than its memory budget. Keep
that body as a `ByteStream`, process one chunk at a time, and close it when
you stop early. `saveTo` creates a private temporary file beside the target.
It replaces the target only after EOF, length checks, and any supported
response checksum succeed. A failure removes the temporary file and keeps
an existing target.

This complete local example saves a cover, opens the file separately for
two request attempts, and reads a preview with a fixed buffer limit. It
does not require a storage server.

```bit
import { Body, ByteStream, bodyStream, isReplayable } from "s3"
import { remove } from "std/fs"
import { BodySource } from "std/http"
import { envOr } from "std/os"
import { uuidV4, format } from "std/uuid"

fn main(): ()! {
  let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\"><title>Inkwell cover</title></svg>"
  let path = envOr("TMPDIR", "/tmp") + "/inkwell-cover-" + format(uuidV4()) + ".svg"
  let cover: ByteStream = bodyStream(Body.Text(svg))?
  defer cover.close()
  cover.saveTo(path)?
  defer {
    remove(path) catch e {
      panic(e.message())
    }
  }

  let upload = Body.File(path)
  assert(isReplayable(upload), "file body can reopen for a retry")
  for attempt of [1, 2] {
    let body = bodyStream(upload)?
    defer body.close()
    assert(body.text(len(svg))? == svg, "attempt ${attempt} reads from byte zero")
  }

  let preview = bodyStream(Body.Bytes([]byte(svg)))?
  defer preview.close()
  println(string(preview.read(5)?))
  preview.pipeTo((part) => {
    println(part)
  })?

  let empty = bodyStream(Body.Empty)?
  assert(len(empty.bytes(0)?) == 0, "empty body needs no buffer")

  let at = 0
  let source: BodySource = (max) => {
    let count = len(svg) - at
    if (count > max) {
      count = max
    }
    let part = svg[at:at + count]
    at = at + count
    return part
  }
  let once = Body.Stream(source, Option.Some(len(svg)))
  assert(!isReplayable(once), "a caller source belongs to one request attempt")
  let streamed = bodyStream(once)?
  defer streamed.close()
  println(streamed.text(len(svg))?)
}
```

`bodyStream` opens one attempt. `Body.Empty`, `Body.Text`, `Body.Bytes`, and
`Body.File` are replayable. A file body opens a fresh descriptor and offset
for each attempt; keep the file unchanged until the request finishes.
`Body.Stream` takes the existing `std/http` `BodySource` and an optional byte
length. Use `Option<int>.None` when the length is unknown. The source must
return at most the requested bytes and return an empty string only at EOF.

`read(max)` returns at most the requested amount, capped at 64 KiB per pull.
`bytes(max)` requires an explicit limit and fails when the remaining body
exceeds it. `text(max)` uses the same check, with a 32 MiB default. Both read
the remaining body, not bytes consumed earlier. Use `pipeTo` or `saveTo`
instead of collecting a large body. Call `close` to abandon a body; repeated
close calls are safe. A failed stream keeps reporting failure on later reads.
`saveTo` rejects an already closed stream before touching the target.

Generated streaming response deserializers reject error status before any
body pull. They validate declared lengths and supported full-object checksums;
checksum mismatches reach the caller at EOF. Malformed checksum headers and
composite checksums fail before a body is handed over. The body library and
the generated deserializers are available to custom transports. The modeled
network pipeline is separate work; these examples do not add network behavior
to the current client. Continue with [Storing article covers](guide.md) for
the existing HTTP operations.

## Keep signing time in step with storage

When an unattended Inkwell device drifts from its storage server, a request
can fail even with valid credentials. If you build a request transport,
keep one `ClockSkewCorrection` alongside its `RetryStrategy`. Capture the
raw send time, use `signingTime` for the instant passed to your signer, and
keep the returned offset snapshot until the response arrives.

```bit
import { ClockSkewCorrection, RetryStrategy } from "s3"
import { Second, Timestamp, parseHttpDate } from "std/time"

fn main(): ()! {
  let correction = ClockSkewCorrection()
  let retries = RetryStrategy()?
  let call = retries.begin()
  let sent = parseHttpDate("Sun, 06 Nov 1994 08:49:37 GMT")?
  let (signingAt, previous) = correction.signingTime(sent)?
  println("Sign the cover request at ${signingAt.toString()}")

  let received = Timestamp{ ns = sent.ns + 2 * Second }
  let corrected = correction.observe(
    "Date: Sun, 06 Nov 1994 10:49:38 GMT\r\n", sent, received, previous,
  )
  println("Retained offset: ${correction.offset()} nanoseconds")
  println("Pass ${corrected} as skewCorrected to this call's decide method")
  println("Attempt ${call.attempt()}")

  let disabled = ClockSkewCorrection(disableClockSkewCorrection = true)
  let (raw, _) = disabled.signingTime(sent)?
  println("Disabled signing time: ${raw.toString()}")
}
```

Call `observe` after every response, including successes. It keeps the
server's `Date` minus the midpoint of your raw send and receive times.
Responses with any `Age` field, no usable HTTP date, a backwards interval,
or a round trip longer than 900 seconds leave the offset unchanged. Exactly
900 seconds is accepted. Invalid arithmetic also leaves it unchanged.

Small corrections persist too. For an error, pass `observe`'s result as
`skewCorrected` to `Invocation.decide`: it is true when the new offset has
magnitude at least 240 seconds and differs from this attempt's snapshot.
The retry strategy still enforces replayability, cancellation, attempt and
quota limits. Use the new signing time on each retry. Concurrent calls
share a locked offset; each signing instant keeps its matching snapshot.

`disableClockSkewCorrection = true` disables both learning and applying
the offset. `signingTime` reports `InvalidInput` with
`clock skew: signing time is outside the Timestamp range` if adding the
correction would overflow. The helper never changes the system clock.
This standalone helper is for transports you build; the current `Client`
does not invoke it automatically.

## Read an event frame

If you already have a complete Select response frame, check its lengths and
checksums before reading article records. `decodeEventMessage` reads exactly
one frame; trailing bytes and incomplete frames fail. `decodeSelectEvent`
also interprets its Select event headers. It returns the existing modeled
Records, Stats, Progress, Cont and End values. Records can end partway through
a record; End marks normal completion. Neither function sends a request or
collects a response stream for you.

```bit
import {
  EventHeaderValue, EventMessage, EventStream, SelectObjectContentEventStream,
  decodeEventMessage, decodeSelectEvent,
} from "s3"
import { decodeBase64 } from "std/crypto"

fn main(): ()! {
  let frame = decodeBase64("AAAAOAAAACjBxoTUDTptZXNzYWdlLXR5cGUHAAVldmVudAs6ZXZlbnQtdHlwZQcAA0VuZM+X05I=")?
  let message: EventMessage = decodeEventMessage(frame)?
  println("${len(message.headers)} headers, ${len(message.payload)} payload bytes")
  let event: SelectObjectContentEventStream = decodeSelectEvent(frame)?
  let stream = EventStream<SelectObjectContentEventStream>{ events = [event] }
  println("${len(stream.events)} decoded event")

  // Header values retain their wire types, including signed integers.
  let values: []EventHeaderValue = [
    EventHeaderValue.Bool(true), EventHeaderValue.Byte(i8(-1)),
    EventHeaderValue.Short(i16(42)), EventHeaderValue.Integer(i32(42)),
    EventHeaderValue.Long(i64(42)), EventHeaderValue.Binary([]byte("article")),
    EventHeaderValue.Text("article"), EventHeaderValue.Timestamp(i64(8675309)),
    EventHeaderValue.Uuid([]byte(16)),
  ]
  println("${len(values)} header value types")
}
```

Timestamps retain signed milliseconds since the Unix epoch. UUIDs retain
their sixteen bytes. Header names are unique, nonempty UTF-8; string values
must also be valid UTF-8. Binary values and payloads remain bytes.

The decoder applies a local **16 MiB total-frame resource limit**, including
headers and checksums. This is an allocation policy, not an AWS protocol
maximum. Payloads and binary headers borrow slices of the input, so retaining
one retains its frame. Process and discard frames individually.

A failed checksum gives `S3Error.kind = ChecksumMismatch` and the message
`event stream: prelude CRC mismatch` or `event stream: message CRC mismatch`.
Stop reading that stream. Service error and exception frames give an
`S3Error` with the service's code and its mapped kind. Unknown event names
remain `Unknown(name)` so a future event does not silently disappear.

Malformed frames give `InvalidInput`: `truncated prelude`, `invalid message
length`, `message exceeds local 16 MiB limit`, `truncated header`, `empty
header name`, `duplicate header name`, `unknown header type`, or `invalid
UTF-8 header`, each prefixed with `event stream: `. A missing required
event header reports `missing <name>`; a non-string event header reports
`<name> is not a string`; an unrecognized message type reports `unknown
message type`. Statistics errors report `invalid statistics XML`, `wrong
statistics root`, or `invalid BytesScanned`,
`invalid BytesProcessed`, `invalid BytesReturned`, with the same prefix.

Use the ordinary object operations in [Storing article covers](guide.md)
when you need an HTTP client rather than a frame decoder.

```bit
import { StorageClass } from "s3"

fn main() {
  let coverStorage = StorageClass.fromWire("STANDARD_IA")
  println(coverStorage.wire())
  let futureStorage = StorageClass.fromWire("FUTURE_CLASS")
  println(futureStorage.wire())
}
```

You can check your stored settings without contacting a service. The same
pair works on every modeled enum:

```bit
import {
  AnalyticsS3ExportFileFormat,
  AnnotationConfigurationState,
  AnnotationDirective,
  ArchiveStatus,
  BucketAbacStatus,
  BucketAccelerateStatus,
  BucketCannedACL,
  BucketLocationConstraint,
  BucketLogsPermission,
  BucketNamespace,
  BucketType,
  BucketVersioningStatus,
  ChecksumAlgorithm,
  ChecksumMode,
  ChecksumType,
  CompressionType,
  DataRedundancy,
  DeleteMarkerReplicationStatus,
  EncodingType,
  EncryptionType,
  Event,
  ExistingObjectReplicationStatus,
  ExpirationState,
  ExpirationStatus,
  ExpressionType,
  FileHeaderInfo,
  FilterRuleName,
  IntelligentTieringAccessTier,
  IntelligentTieringStatus,
  InventoryConfigurationState,
  InventoryFormat,
  InventoryFrequency,
  InventoryIncludedObjectVersions,
  InventoryOptionalField,
  JSONType,
  LocationType,
  MFADelete,
  MFADeleteStatus,
  MetadataDirective,
  MetricsStatus,
  ObjectAttributes,
  ObjectCannedACL,
  ObjectLockEnabled,
  ObjectLockEventHold,
  ObjectLockLegalHoldStatus,
  ObjectLockMode,
  ObjectLockRetentionMode,
  ObjectOwnership,
  ObjectStorageClass,
  ObjectVersionStorageClass,
  OptionalObjectAttributes,
  OwnerOverride,
  PartitionDateSource,
  Payer,
  Permission,
  Protocol,
  QuoteFields,
  ReplicaModificationsStatus,
  ReplicationRuleStatus,
  ReplicationStatus,
  ReplicationTimeStatus,
  RequestCharged,
  RequestPayer,
  RestoreRequestType,
  S3TablesBucketType,
  ServerSideEncryption,
  SessionMode,
  SseKmsEncryptedObjectsStatus,
  StorageClass,
  StorageClassAnalysisSchemaVersion,
  TableSseAlgorithm,
  TaggingDirective,
  Tier,
  TransitionDefaultMinimumObjectSize,
  TransitionStorageClass,
  Type,
} from "s3"

fn checkStored1_0() {
  assert(AnalyticsS3ExportFileFormat.fromWire("CSV").wire() == "CSV", "AnalyticsS3ExportFileFormat")
  assert(
    AnnotationConfigurationState.fromWire("DISABLED").wire() == "DISABLED",
    "AnnotationConfigurationState",
  )
  assert(AnnotationDirective.fromWire("COPY").wire() == "COPY", "AnnotationDirective")
  assert(ArchiveStatus.fromWire("ARCHIVE_ACCESS").wire() == "ARCHIVE_ACCESS", "ArchiveStatus")
  assert(BucketAbacStatus.fromWire("Disabled").wire() == "Disabled", "BucketAbacStatus")
  assert(BucketAccelerateStatus.fromWire("Enabled").wire() == "Enabled", "BucketAccelerateStatus")
  assert(
    BucketCannedACL.fromWire("authenticated-read").wire() == "authenticated-read",
    "BucketCannedACL",
  )
  assert(BucketLocationConstraint.fromWire("EU").wire() == "EU", "BucketLocationConstraint")
  assert(
    BucketLogsPermission.fromWire("FULL_CONTROL").wire() == "FULL_CONTROL",
    "BucketLogsPermission",
  )
  assert(
    BucketNamespace.fromWire("account-regional").wire() == "account-regional",
    "BucketNamespace",
  )
  assert(BucketType.fromWire("Directory").wire() == "Directory", "BucketType")
  assert(BucketVersioningStatus.fromWire("Enabled").wire() == "Enabled", "BucketVersioningStatus")
  assert(ChecksumAlgorithm.fromWire("CRC32").wire() == "CRC32", "ChecksumAlgorithm")
  assert(ChecksumMode.fromWire("ENABLED").wire() == "ENABLED", "ChecksumMode")
  assert(ChecksumType.fromWire("COMPOSITE").wire() == "COMPOSITE", "ChecksumType")
  assert(CompressionType.fromWire("BZIP2").wire() == "BZIP2", "CompressionType")
}

fn checkStored1_1() {
  assert(
    DataRedundancy.fromWire("SingleAvailabilityZone").wire() == "SingleAvailabilityZone",
    "DataRedundancy",
  )
  assert(
    DeleteMarkerReplicationStatus.fromWire("Disabled").wire() == "Disabled",
    "DeleteMarkerReplicationStatus",
  )
  assert(EncodingType.fromWire("url").wire() == "url", "EncodingType")
  assert(EncryptionType.fromWire("NONE").wire() == "NONE", "EncryptionType")
  assert(Event.fromWire("s3:IntelligentTiering").wire() == "s3:IntelligentTiering", "Event")
  assert(
    ExistingObjectReplicationStatus.fromWire("Disabled").wire() == "Disabled",
    "ExistingObjectReplicationStatus",
  )
  assert(ExpirationState.fromWire("DISABLED").wire() == "DISABLED", "ExpirationState")
  assert(ExpirationStatus.fromWire("Disabled").wire() == "Disabled", "ExpirationStatus")
  assert(ExpressionType.fromWire("SQL").wire() == "SQL", "ExpressionType")
  assert(FileHeaderInfo.fromWire("IGNORE").wire() == "IGNORE", "FileHeaderInfo")
  assert(FilterRuleName.fromWire("prefix").wire() == "prefix", "FilterRuleName")
  assert(
    IntelligentTieringAccessTier.fromWire("ARCHIVE_ACCESS").wire() == "ARCHIVE_ACCESS",
    "IntelligentTieringAccessTier",
  )
  assert(
    IntelligentTieringStatus.fromWire("Disabled").wire() == "Disabled",
    "IntelligentTieringStatus",
  )
  assert(
    InventoryConfigurationState.fromWire("DISABLED").wire() == "DISABLED",
    "InventoryConfigurationState",
  )
  assert(InventoryFormat.fromWire("CSV").wire() == "CSV", "InventoryFormat")
  assert(InventoryFrequency.fromWire("Daily").wire() == "Daily", "InventoryFrequency")
}

fn checkStored1_2() {
  assert(
    InventoryIncludedObjectVersions.fromWire("All").wire() == "All",
    "InventoryIncludedObjectVersions",
  )
  assert(
    InventoryOptionalField.fromWire("BucketKeyStatus").wire() == "BucketKeyStatus",
    "InventoryOptionalField",
  )
  assert(JSONType.fromWire("DOCUMENT").wire() == "DOCUMENT", "JSONType")
  assert(LocationType.fromWire("AvailabilityZone").wire() == "AvailabilityZone", "LocationType")
  assert(MFADelete.fromWire("Disabled").wire() == "Disabled", "MFADelete")
  assert(MFADeleteStatus.fromWire("Disabled").wire() == "Disabled", "MFADeleteStatus")
  assert(MetadataDirective.fromWire("COPY").wire() == "COPY", "MetadataDirective")
  assert(MetricsStatus.fromWire("Disabled").wire() == "Disabled", "MetricsStatus")
  assert(ObjectAttributes.fromWire("Checksum").wire() == "Checksum", "ObjectAttributes")
  assert(
    ObjectCannedACL.fromWire("authenticated-read").wire() == "authenticated-read",
    "ObjectCannedACL",
  )
  assert(ObjectLockEnabled.fromWire("Enabled").wire() == "Enabled", "ObjectLockEnabled")
  assert(ObjectLockEventHold.fromWire("OFF").wire() == "OFF", "ObjectLockEventHold")
  assert(ObjectLockLegalHoldStatus.fromWire("OFF").wire() == "OFF", "ObjectLockLegalHoldStatus")
  assert(ObjectLockMode.fromWire("COMPLIANCE").wire() == "COMPLIANCE", "ObjectLockMode")
  assert(
    ObjectLockRetentionMode.fromWire("COMPLIANCE").wire() == "COMPLIANCE",
    "ObjectLockRetentionMode",
  )
  assert(
    ObjectOwnership.fromWire("BucketOwnerEnforced").wire() == "BucketOwnerEnforced",
    "ObjectOwnership",
  )
}

fn checkStored1_3() {
  assert(
    ObjectStorageClass.fromWire("AWS_BACKUP_LOW_COST_WARM").wire() == "AWS_BACKUP_LOW_COST_WARM",
    "ObjectStorageClass",
  )
  assert(
    ObjectVersionStorageClass.fromWire("STANDARD").wire() == "STANDARD",
    "ObjectVersionStorageClass",
  )
  assert(
    OptionalObjectAttributes.fromWire("RestoreStatus").wire() == "RestoreStatus",
    "OptionalObjectAttributes",
  )
  assert(OwnerOverride.fromWire("Destination").wire() == "Destination", "OwnerOverride")
  assert(
    PartitionDateSource.fromWire("DeliveryTime").wire() == "DeliveryTime",
    "PartitionDateSource",
  )
  assert(Payer.fromWire("BucketOwner").wire() == "BucketOwner", "Payer")
  assert(Permission.fromWire("FULL_CONTROL").wire() == "FULL_CONTROL", "Permission")
  assert(Protocol.fromWire("http").wire() == "http", "Protocol")
  assert(QuoteFields.fromWire("ALWAYS").wire() == "ALWAYS", "QuoteFields")
  assert(
    ReplicaModificationsStatus.fromWire("Disabled").wire() == "Disabled",
    "ReplicaModificationsStatus",
  )
  assert(ReplicationRuleStatus.fromWire("Disabled").wire() == "Disabled", "ReplicationRuleStatus")
  assert(ReplicationStatus.fromWire("COMPLETE").wire() == "COMPLETE", "ReplicationStatus")
  assert(ReplicationTimeStatus.fromWire("Disabled").wire() == "Disabled", "ReplicationTimeStatus")
  assert(RequestCharged.fromWire("requester").wire() == "requester", "RequestCharged")
  assert(RequestPayer.fromWire("requester").wire() == "requester", "RequestPayer")
  assert(RestoreRequestType.fromWire("SELECT").wire() == "SELECT", "RestoreRequestType")
}

fn checkStored1_4() {
  assert(S3TablesBucketType.fromWire("aws").wire() == "aws", "S3TablesBucketType")
  assert(ServerSideEncryption.fromWire("AES256").wire() == "AES256", "ServerSideEncryption")
  assert(SessionMode.fromWire("ReadOnly").wire() == "ReadOnly", "SessionMode")
  assert(
    SseKmsEncryptedObjectsStatus.fromWire("Disabled").wire() == "Disabled",
    "SseKmsEncryptedObjectsStatus",
  )
  assert(
    StorageClass.fromWire("AWS_BACKUP_LOW_COST_WARM").wire() == "AWS_BACKUP_LOW_COST_WARM",
    "StorageClass",
  )
  assert(
    StorageClassAnalysisSchemaVersion.fromWire("V_1").wire() == "V_1",
    "StorageClassAnalysisSchemaVersion",
  )
  assert(TableSseAlgorithm.fromWire("AES256").wire() == "AES256", "TableSseAlgorithm")
  assert(TaggingDirective.fromWire("COPY").wire() == "COPY", "TaggingDirective")
  assert(Tier.fromWire("Bulk").wire() == "Bulk", "Tier")
  assert(
      TransitionDefaultMinimumObjectSize.fromWire("all_storage_classes_128K").wire() ==
      "all_storage_classes_128K",
    "TransitionDefaultMinimumObjectSize",
  )
  assert(
    TransitionStorageClass.fromWire("DEEP_ARCHIVE").wire() == "DEEP_ARCHIVE",
    "TransitionStorageClass",
  )
  assert(Type.fromWire("AmazonCustomerByEmail").wire() == "AmazonCustomerByEmail", "Type")
  assert(StorageClass.fromWire("FUTURE_CLASS").wire() == "FUTURE_CLASS", "future class")
}

fn main() {
  checkStored1_0()
  checkStored1_1()
  checkStored1_2()
  checkStored1_3()
  checkStored1_4()
}
```

When you build an adapter for a modeled operation, a result without a response
body still needs a place for the request details. Its output type gives you that
place after an update or delete, just as an upload output does.
These outputs contain only `responseMetadata`; object user metadata stays in
the separate `metadata` field on outputs that model it. These examples construct
result values; a response parser fills their metadata.

```bit
import {
  CreateBucketMetadataConfigurationOutput,
  CreateBucketMetadataTableConfigurationOutput,
  DeleteBucketOutput,
  DeleteBucketAnalyticsConfigurationOutput,
  DeleteBucketCorsOutput,
  DeleteBucketEncryptionOutput,
  DeleteBucketIntelligentTieringConfigurationOutput,
  DeleteBucketInventoryConfigurationOutput,
  DeleteBucketLifecycleOutput,
  DeleteBucketMetadataConfigurationOutput,
  DeleteBucketMetadataTableConfigurationOutput,
  DeleteBucketMetricsConfigurationOutput,
  DeleteBucketOwnershipControlsOutput,
  DeleteBucketPolicyOutput,
  DeleteBucketReplicationOutput,
  DeleteBucketTaggingOutput,
  DeleteBucketWebsiteOutput,
  DeletePublicAccessBlockOutput,
  PutBucketAbacOutput,
  PutBucketAccelerateConfigurationOutput,
  PutBucketAclOutput,
  PutBucketAnalyticsConfigurationOutput,
  PutBucketCorsOutput,
  PutBucketEncryptionOutput,
  PutBucketIntelligentTieringConfigurationOutput,
  PutBucketInventoryConfigurationOutput,
  PutBucketLoggingOutput,
  PutBucketMetricsConfigurationOutput,
  PutBucketNotificationConfigurationOutput,
  PutBucketOwnershipControlsOutput,
  PutBucketPolicyOutput,
  PutBucketReplicationOutput,
  PutBucketRequestPaymentOutput,
  PutBucketTaggingOutput,
  PutBucketVersioningOutput,
  PutBucketWebsiteOutput,
  PutPublicAccessBlockOutput,
  UpdateBucketMetadataAnnotationTableConfigurationOutput,
  UpdateBucketMetadataInventoryTableConfigurationOutput,
  UpdateBucketMetadataJournalTableConfigurationOutput,
  WriteGetObjectResponseOutput,
} from "s3"

fn checkStored2_0() {
  assert(
    CreateBucketMetadataConfigurationOutput{}.responseMetadata.httpStatusCode == 0,
    "CreateBucketMetadataConfigurationOutput",
  )
  assert(
    CreateBucketMetadataTableConfigurationOutput{}.responseMetadata.httpStatusCode == 0,
    "CreateBucketMetadataTableConfigurationOutput",
  )
  assert(DeleteBucketOutput{}.responseMetadata.httpStatusCode == 0, "DeleteBucketOutput")
  assert(
    DeleteBucketAnalyticsConfigurationOutput{}.responseMetadata.httpStatusCode == 0,
    "DeleteBucketAnalyticsConfigurationOutput",
  )
  assert(DeleteBucketCorsOutput{}.responseMetadata.httpStatusCode == 0, "DeleteBucketCorsOutput")
  assert(
    DeleteBucketEncryptionOutput{}.responseMetadata.httpStatusCode == 0,
    "DeleteBucketEncryptionOutput",
  )
  assert(
    DeleteBucketIntelligentTieringConfigurationOutput{}.responseMetadata.httpStatusCode == 0,
    "DeleteBucketIntelligentTieringConfigurationOutput",
  )
  assert(
    DeleteBucketInventoryConfigurationOutput{}.responseMetadata.httpStatusCode == 0,
    "DeleteBucketInventoryConfigurationOutput",
  )
  assert(
    DeleteBucketLifecycleOutput{}.responseMetadata.httpStatusCode == 0,
    "DeleteBucketLifecycleOutput",
  )
  assert(
    DeleteBucketMetadataConfigurationOutput{}.responseMetadata.httpStatusCode == 0,
    "DeleteBucketMetadataConfigurationOutput",
  )
  assert(
    DeleteBucketMetadataTableConfigurationOutput{}.responseMetadata.httpStatusCode == 0,
    "DeleteBucketMetadataTableConfigurationOutput",
  )
  assert(
    DeleteBucketMetricsConfigurationOutput{}.responseMetadata.httpStatusCode == 0,
    "DeleteBucketMetricsConfigurationOutput",
  )
  assert(
    DeleteBucketOwnershipControlsOutput{}.responseMetadata.httpStatusCode == 0,
    "DeleteBucketOwnershipControlsOutput",
  )
  assert(
    DeleteBucketPolicyOutput{}.responseMetadata.httpStatusCode == 0,
    "DeleteBucketPolicyOutput",
  )
  assert(
    DeleteBucketReplicationOutput{}.responseMetadata.httpStatusCode == 0,
    "DeleteBucketReplicationOutput",
  )
  assert(
    DeleteBucketTaggingOutput{}.responseMetadata.httpStatusCode == 0,
    "DeleteBucketTaggingOutput",
  )
}

fn checkStored2_1() {
  assert(
    DeleteBucketWebsiteOutput{}.responseMetadata.httpStatusCode == 0,
    "DeleteBucketWebsiteOutput",
  )
  assert(
    DeletePublicAccessBlockOutput{}.responseMetadata.httpStatusCode == 0,
    "DeletePublicAccessBlockOutput",
  )
  assert(PutBucketAbacOutput{}.responseMetadata.httpStatusCode == 0, "PutBucketAbacOutput")
  assert(
    PutBucketAccelerateConfigurationOutput{}.responseMetadata.httpStatusCode == 0,
    "PutBucketAccelerateConfigurationOutput",
  )
  assert(PutBucketAclOutput{}.responseMetadata.httpStatusCode == 0, "PutBucketAclOutput")
  assert(
    PutBucketAnalyticsConfigurationOutput{}.responseMetadata.httpStatusCode == 0,
    "PutBucketAnalyticsConfigurationOutput",
  )
  assert(PutBucketCorsOutput{}.responseMetadata.httpStatusCode == 0, "PutBucketCorsOutput")
  assert(
    PutBucketEncryptionOutput{}.responseMetadata.httpStatusCode == 0,
    "PutBucketEncryptionOutput",
  )
  assert(
    PutBucketIntelligentTieringConfigurationOutput{}.responseMetadata.httpStatusCode == 0,
    "PutBucketIntelligentTieringConfigurationOutput",
  )
  assert(
    PutBucketInventoryConfigurationOutput{}.responseMetadata.httpStatusCode == 0,
    "PutBucketInventoryConfigurationOutput",
  )
  assert(PutBucketLoggingOutput{}.responseMetadata.httpStatusCode == 0, "PutBucketLoggingOutput")
  assert(
    PutBucketMetricsConfigurationOutput{}.responseMetadata.httpStatusCode == 0,
    "PutBucketMetricsConfigurationOutput",
  )
  assert(
    PutBucketNotificationConfigurationOutput{}.responseMetadata.httpStatusCode == 0,
    "PutBucketNotificationConfigurationOutput",
  )
  assert(
    PutBucketOwnershipControlsOutput{}.responseMetadata.httpStatusCode == 0,
    "PutBucketOwnershipControlsOutput",
  )
  assert(PutBucketPolicyOutput{}.responseMetadata.httpStatusCode == 0, "PutBucketPolicyOutput")
  assert(
    PutBucketReplicationOutput{}.responseMetadata.httpStatusCode == 0,
    "PutBucketReplicationOutput",
  )
}

fn checkStored2_2() {
  assert(
    PutBucketRequestPaymentOutput{}.responseMetadata.httpStatusCode == 0,
    "PutBucketRequestPaymentOutput",
  )
  assert(PutBucketTaggingOutput{}.responseMetadata.httpStatusCode == 0, "PutBucketTaggingOutput")
  assert(
    PutBucketVersioningOutput{}.responseMetadata.httpStatusCode == 0,
    "PutBucketVersioningOutput",
  )
  assert(PutBucketWebsiteOutput{}.responseMetadata.httpStatusCode == 0, "PutBucketWebsiteOutput")
  assert(
    PutPublicAccessBlockOutput{}.responseMetadata.httpStatusCode == 0,
    "PutPublicAccessBlockOutput",
  )
  assert(
    UpdateBucketMetadataAnnotationTableConfigurationOutput{}.responseMetadata.httpStatusCode == 0,
    "UpdateBucketMetadataAnnotationTableConfigurationOutput",
  )
  assert(
    UpdateBucketMetadataInventoryTableConfigurationOutput{}.responseMetadata.httpStatusCode == 0,
    "UpdateBucketMetadataInventoryTableConfigurationOutput",
  )
  assert(
    UpdateBucketMetadataJournalTableConfigurationOutput{}.responseMetadata.httpStatusCode == 0,
    "UpdateBucketMetadataJournalTableConfigurationOutput",
  )
  assert(
    WriteGetObjectResponseOutput{}.responseMetadata.httpStatusCode == 0,
    "WriteGetObjectResponseOutput",
  )
}

fn main() {
  checkStored2_0()
  checkStored2_1()
  checkStored2_2()
}
```

Use typed enum variants when your application must reject an unfamiliar value.
Use `Unknown` when you need to preserve it for a later request.
Continue with [the S3 guide chapters](README.md).
