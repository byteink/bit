// Matches json.bit's data and output, NOT its code shape -- see json.bit's
// header for why. This is a small vendored recursive-descent JSON parser
// (object/array/string/number/bool/null), parsed straight into the known
// {id,name,active,tags} record schema. Minimal on purpose: no \u escapes,
// no floats -- neither is present in the generated document.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef enum { J_NULL, J_BOOL, J_NUM, J_STR, J_ARR, J_OBJ } JType;
typedef struct JVal JVal;
typedef struct { char *key; JVal *val; } JEntry;
struct JVal {
  JType type;
  long num;
  int boolean;
  char *str;
  JVal **items;
  size_t nItems;
  JEntry *entries;
  size_t nEntries;
};

static const char *p;

static void skipWs(void) {
  while (*p == ' ' || *p == '\n' || *p == '\t' || *p == '\r') p++;
}

static JVal *newVal(JType t) {
  JVal *v = calloc(1, sizeof(JVal));
  v->type = t;
  return v;
}

static JVal *parseValue(void);

static char *parseStringRaw(void) {
  p++;
  size_t cap = 16, n = 0;
  char *buf = malloc(cap);
  while (*p != '"') {
    char c = *p++;
    if (c == '\\') {
      char e = *p++;
      if (e == 'n') c = '\n';
      else if (e == 't') c = '\t';
      else c = e;
    }
    if (n + 1 >= cap) {
      cap *= 2;
      buf = realloc(buf, cap);
    }
    buf[n++] = c;
  }
  p++;
  buf[n] = '\0';
  return buf;
}

static JVal *parseString(void) {
  JVal *v = newVal(J_STR);
  v->str = parseStringRaw();
  return v;
}

static JVal *parseNumber(void) {
  JVal *v = newVal(J_NUM);
  char *end;
  v->num = strtol(p, &end, 10);
  p = end;
  return v;
}

static JVal *parseArray(void) {
  JVal *v = newVal(J_ARR);
  p++;
  skipWs();
  size_t cap = 8;
  v->items = malloc(cap * sizeof(JVal *));
  if (*p == ']') {
    p++;
    return v;
  }
  for (;;) {
    skipWs();
    if (v->nItems >= cap) {
      cap *= 2;
      v->items = realloc(v->items, cap * sizeof(JVal *));
    }
    v->items[v->nItems++] = parseValue();
    skipWs();
    if (*p == ',') {
      p++;
      continue;
    }
    break;
  }
  skipWs();
  p++;
  return v;
}

static JVal *parseObject(void) {
  JVal *v = newVal(J_OBJ);
  p++;
  skipWs();
  size_t cap = 8;
  v->entries = malloc(cap * sizeof(JEntry));
  if (*p == '}') {
    p++;
    return v;
  }
  for (;;) {
    skipWs();
    char *key = parseStringRaw();
    skipWs();
    p++;
    skipWs();
    JVal *val = parseValue();
    if (v->nEntries >= cap) {
      cap *= 2;
      v->entries = realloc(v->entries, cap * sizeof(JEntry));
    }
    v->entries[v->nEntries].key = key;
    v->entries[v->nEntries].val = val;
    v->nEntries++;
    skipWs();
    if (*p == ',') {
      p++;
      continue;
    }
    break;
  }
  skipWs();
  p++;
  return v;
}

static JVal *parseValue(void) {
  skipWs();
  if (*p == '{') return parseObject();
  if (*p == '[') return parseArray();
  if (*p == '"') return parseString();
  if (*p == 't') {
    p += 4;
    JVal *v = newVal(J_BOOL);
    v->boolean = 1;
    return v;
  }
  if (*p == 'f') {
    p += 5;
    JVal *v = newVal(J_BOOL);
    v->boolean = 0;
    return v;
  }
  if (*p == 'n') {
    p += 4;
    return newVal(J_NULL);
  }
  return parseNumber();
}

static JVal *jget(JVal *obj, const char *key) {
  JVal *found = NULL;
  for (size_t i = 0; i < obj->nEntries; i++) {
    if (strcmp(obj->entries[i].key, key) == 0) found = obj->entries[i].val;
  }
  return found;
}

int main(void) {
  long recs = 30000;
  size_t cap = 1 << 21;
  char *buf = malloc(cap);
  size_t n = 0;
  char tmp[256];

#define APPEND(s)                                       \
  do {                                                    \
    size_t l = strlen(s);                                 \
    if (n + l + 1 >= cap) {                                 \
      cap *= 2;                                              \
      buf = realloc(buf, cap);                                \
    }                                                          \
    memcpy(buf + n, s, l);                                       \
    n += l;                                                        \
  } while (0)

  APPEND("[");
  for (long i = 0; i < recs; i++) {
    if (i > 0) APPEND(",");
    const char *active = (i % 2 == 0) ? "true" : "false";
    snprintf(tmp, sizeof(tmp), "{\"id\":%ld,\"name\":\"user%ld\",\"active\":%s,\"tags\":[%ld,%ld,%ld]}",
             i, i, active, i % 7, i % 11, i % 13);
    APPEND(tmp);
  }
  APPEND("]");
  buf[n] = '\0';

  p = buf;
  JVal *doc = parseValue();

  long idSum = 0, tagSum = 0, activeCount = 0, nameLenSum = 0;
  for (size_t i = 0; i < doc->nItems; i++) {
    JVal *item = doc->items[i];
    JVal *idv = jget(item, "id");
    if (idv) idSum += idv->num;
    JVal *actv = jget(item, "active");
    if (actv && actv->boolean) activeCount++;
    JVal *namev = jget(item, "name");
    if (namev) nameLenSum += (long)strlen(namev->str);
    JVal *tagsv = jget(item, "tags");
    if (tagsv) {
      for (size_t k = 0; k < tagsv->nItems; k++) tagSum += tagsv->items[k]->num;
    }
  }

  printf("%ld %ld %ld %ld\n", idSum, tagSum, activeCount, nameLenSum);
  free(buf);
  return 0;
}
