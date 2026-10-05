# pkg/authz docs

| Chapter | Covers |
| ------- | ------ |
| [Actions](actions.md) | Naming what a user can do with an enum, building `Authz<Action>`, the `Manage` wildcard, the CRUD variants |
| [Subjects](subjects.md) | Who is asking: the `Subject` interface, `$user.x` attributes with `attributeOf`, the guest as an absent subject |
| [Resources](resources.md) | Registering `@table` classes with `resource<T>()`, names from the class, `all`, `resourceRef`, `resourceByName`, `fieldType` |
| [Conditions](conditions.md) | The `Cond` tree: `eq`, `ne`, `oneOf`, `lt`, `lte`, `gt`, `gte`, `and`, `or`, `not`, `evalCond` and its `Truth` answer, `validate` at startup, `fromWhere`, how NULL and CASL differ, `compileSql` with `asAllow`/`asDeny` to filter a list, and `canIf`/`custom` code rules with `filterable`, `validateFilterable` and `NotFilterable` |
| [Relationships](relationships.md) | Tuples such as `user:sara`, `editor`, `folder:launch`: declaring relations with `relation`, `relate`, `unrelate`, `related`, usersets, the `hasRelation` check with `inherit` and its bounds (`RelationLimit`), `RelationStore` and `MemoryRelationStore` |
| [Policies](policies.md) | `Policy`, `Rules`, `Rule` and `Effect`: `can`, `cannot`, `canAll`, `cannotAll`, `rulesFor`, and `validatePolicy` at startup; roles that bundle them: `role`, `roleNames`, `checkRoles`, `rolesOf` and `Resolved` |
| [Deciding](decisions.md) | `can` and `check` on `Authz`: deny wins, default deny, `Manage`, the guest as `None`, `logTo`, the decision log and `Denied`, rules that are wrong at request time |
