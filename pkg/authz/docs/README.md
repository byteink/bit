# pkg/authz docs

| Chapter | Covers |
| ------- | ------ |
| [Actions](actions.md) | Naming what a user can do with an enum, building `Authz<Action>`, the `Manage` wildcard, the CRUD variants |
| [Subjects](subjects.md) | Who is asking: the `Subject` interface, `$user.x` attributes with `attributeOf`, the guest as an absent subject |
| [Resources](resources.md) | Registering `@table` classes with `resource<T>()`, names from the class, `all`, `resourceRef`, `resourceByName`, `fieldType` |
| [Conditions](conditions.md) | The `Cond` tree: `eq`, `ne`, `oneOf`, `lt`, `lte`, `gt`, `gte`, `and`, `or`, `not`, `evalCond` and its `Bool3` answer, `validate` at startup, `fromWhere`, how NULL and CASL differ |
