<!-- doctest: per-block -->

# Keep storage values and response details

When Inkwell saves a storage setting, save the value the service expects.
`wire()` gives you that value. `fromWire()` reads it back without losing a
value a service adds later.

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
