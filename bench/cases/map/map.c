// Matches map.bit: C has no built-in map, so this hand-rolls an
// open-addressing table (linear probing, tombstone delete) over the same
// key set -- same asymptotic behaviour as map.bit/map.go's native maps, not
// the same code.
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>

typedef struct { int64_t key, val; int8_t state; } Slot; // 0=empty,1=live,2=tombstone

static Slot *table;
static uint64_t cap;

static uint64_t mix64(uint64_t x) {
  x ^= x >> 33;
  x *= 0xff51afd7ed558ccdULL;
  x ^= x >> 33;
  x *= 0xc4ceb9fe1a85ec53ULL;
  x ^= x >> 33;
  return x;
}

static void tinsert(int64_t key, int64_t val) {
  uint64_t idx = mix64((uint64_t)key) & (cap - 1);
  for (;;) {
    if (table[idx].state != 1) {
      table[idx].key = key;
      table[idx].val = val;
      table[idx].state = 1;
      return;
    }
    if (table[idx].key == key) {
      table[idx].val = val;
      return;
    }
    idx = (idx + 1) & (cap - 1);
  }
}

static int tlookup(int64_t key, int64_t *out) {
  uint64_t idx = mix64((uint64_t)key) & (cap - 1);
  for (;;) {
    if (table[idx].state == 0) return 0;
    if (table[idx].state == 1 && table[idx].key == key) {
      *out = table[idx].val;
      return 1;
    }
    idx = (idx + 1) & (cap - 1);
  }
}

static void tdelete(int64_t key) {
  uint64_t idx = mix64((uint64_t)key) & (cap - 1);
  for (;;) {
    if (table[idx].state == 0) return;
    if (table[idx].state == 1 && table[idx].key == key) {
      table[idx].state = 2;
      return;
    }
    idx = (idx + 1) & (cap - 1);
  }
}

int main(void) {
  int64_t n = 1500000;
  cap = 1;
  while (cap < (uint64_t)(n * 3)) cap <<= 1;
  table = calloc(cap, sizeof(Slot));

  for (int64_t i = 0; i < n; i++) tinsert(i, i * 7);

  int64_t sum1 = 0;
  for (int64_t i = 0; i < n; i++) {
    int64_t v = 0;
    tlookup(i, &v);
    sum1 += v;
  }

  for (int64_t i = 0; i < n; i++) {
    if (i % 4 == 0) tdelete(i);
  }

  int64_t sum2 = 0, remaining = 0;
  for (int64_t i = 0; i < n; i++) {
    int64_t v = 0;
    if (tlookup(i, &v)) {
      sum2 += v;
      remaining++;
    }
  }

  int64_t live = 0;
  for (uint64_t i = 0; i < cap; i++) {
    if (table[i].state == 1) live++;
  }

  printf("%lld %lld %lld %lld\n", (long long)sum1, (long long)remaining, (long long)sum2, (long long)live);
  free(table);
  return 0;
}
