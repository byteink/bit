# pkg/authz docs

| Chapter | Covers |
| ------- | ------ |
| [Actions](actions.md) | Naming what a user can do with an enum, building `Authz<Action>`, the `Manage` wildcard, the CRUD variants |
| [Subjects](subjects.md) | Who is asking: the `Subject` interface, `$user.x` attributes with `attributeOf`, the guest as an absent subject |
| [Resources](resources.md) | Registering `@table` classes with `resource<T>()`, names from the class, `all`, `resourceRef`, `resourceByName`, `fieldType` |
| [Conditions](conditions.md) | The `Cond` tree: `eq`, `ne`, `oneOf`, `lt`, `lte`, `gt`, `gte`, `and`, `or`, `not`, `evalCond` and its `Truth` answer, `validate` at startup, `fromWhere`, how NULL and CASL differ |
| [Relationships](relationships.md) | Tuples such as `user:sara`, `editor`, `folder:launch`: declaring relations with `relation`, `relate`, `unrelate`, `related`, usersets, the `hasRelation` check with `inherit` and its bounds (`RelationLimit`), `RelationStore` and `MemoryRelationStore` |
