# pkg/authz docs

| Chapter | Covers |
| ------- | ------ |
| [Actions](actions.md) | Naming what a user can do with an enum, building `Authz<Action>`, the `Manage` wildcard, the CRUD variants |
| [Subjects](subjects.md) | Who is asking: the `Subject` interface, `$user.x` attributes with `attributeOf`, the guest as an absent subject |
| [Resources](resources.md) | Registering `@table` classes with `resource<T>()`, names from the class, `all`, `resourceRef`, `resourceByName`, `fieldType` |
| [Relationships](relationships.md) | Tuples such as `user:sara`, `editor`, `folder:launch`: `relate`, `unrelate`, `related`, usersets, validation, `RelationStore` and `MemoryRelationStore` |
