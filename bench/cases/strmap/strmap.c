// Matches strmap.bit: C has no built-in map, so this hand-rolls an
// open-addressing table (linear probing, tombstone delete) keyed on 16-byte
// strings over the same key set -- same asymptotic behaviour as
// strmap.bit/strmap.go's native maps, not the same code, exactly as map.c is
// to map.bit.
//
// The hash is word-at-a-time rather than a byte-at-a-time FNV: every native
// map this row compares against hashes strings a word at a time (Bit's
// wyhash, Go's AES/memhash), so a byte-at-a-time C hash would publish a ratio
// that is mostly a hash-choice penalty. Quality is comparable; the function
// is not the same function on any two of the three sides, and cannot be.
//
// Pre-sized in one calloc to >= n*3 slots, matching strmap.bit's
// map<string,i64>(n) capacity hint and strmap.go's make(map[string]int64, n).
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

// -DBENCH_ALLOC_STATS builds a counting copy that prints this run's malloc
// count on stderr, so bench/run.sh can compare it against the Bit and Go
// sides of the same case (#3934). The timed binary is built without it and is
// byte-for-byte the program below.
#ifdef BENCH_ALLOC_STATS
static long nmalloc = 0;
#define malloc(n) (nmalloc++, malloc(n))
#define calloc(n, s) (nmalloc++, calloc(n, s))
#define REPORT_ALLOCS() fprintf(stderr, "[allocs] %ld\n", nmalloc)
#else
#define REPORT_ALLOCS() ((void)0)
#endif

#define WIDTH 16

typedef struct { const char *key; int64_t val; int8_t state; } Slot; // 0=empty,1=live,2=tombstone

static Slot *table;
static uint64_t cap;

static long mixi(long i) { return ((i + 1) * 2654435761L) % 2147483647L; }

static uint64_t wymix(uint64_t a, uint64_t b) {
  __uint128_t p = (__uint128_t)a * (__uint128_t)b;
  return (uint64_t)p ^ (uint64_t)(p >> 64);
}

static uint64_t hashKey(const char *p, size_t n) {
  uint64_t s = 0x9e3779b97f4a7c15ULL ^ (uint64_t)n;
  while (n >= 16) {
    uint64_t a, b;
    memcpy(&a, p, 8);
    memcpy(&b, p + 8, 8);
    s = wymix(a ^ s, b ^ 0xc2b2ae3d27d4eb4fULL);
    p += 16;
    n -= 16;
  }
  uint64_t a = 0, b = 0;
  if (n >= 8) {
    memcpy(&a, p, 8);
    memcpy(&b, p + n - 8, 8);
  } else {
    for (size_t i = 0; i < n; i++) a = (a << 8) | (unsigned char)p[i];
    b = a;
  }
  return wymix(a ^ s, b ^ 0x165667b19e3779f9ULL);
}

static void tinsert(const char *key, int64_t val) {
  uint64_t idx = hashKey(key, WIDTH) & (cap - 1);
  for (;;) {
    if (table[idx].state != 1) {
      table[idx].key = key;
      table[idx].val = val;
      table[idx].state = 1;
      return;
    }
    if (memcmp(table[idx].key, key, WIDTH) == 0) {
      table[idx].val = val;
      return;
    }
    idx = (idx + 1) & (cap - 1);
  }
}

static int tlookup(const char *key, int64_t *out) {
  uint64_t idx = hashKey(key, WIDTH) & (cap - 1);
  for (;;) {
    if (table[idx].state == 0) return 0;
    if (table[idx].state == 1 && memcmp(table[idx].key, key, WIDTH) == 0) {
      *out = table[idx].val;
      return 1;
    }
    idx = (idx + 1) & (cap - 1);
  }
}

static void tdelete(const char *key) {
  uint64_t idx = hashKey(key, WIDTH) & (cap - 1);
  for (;;) {
    if (table[idx].state == 0) return;
    if (table[idx].state == 1 && memcmp(table[idx].key, key, WIDTH) == 0) {
      table[idx].state = 2;
      return;
    }
    idx = (idx + 1) & (cap - 1);
  }
}

int main(void) {
  int64_t n = 200000, total = n * 2, reps = 30;

  char *blob = malloc((size_t)total * WIDTH);
  for (int64_t i = 0; i < total; i++) {
    int64_t q = i, j = 0;
    for (; j < 4; j++) {
      blob[i * WIDTH + j] = (char)(97 + q % 26);
      q /= 26;
    }
    for (; j < WIDTH; j++) {
      blob[i * WIDTH + j] = (char)(97 + mixi(i * 37 + j + 1) % 26);
    }
  }

  // One heap object per key, matching the other two sides.
  char **keys = malloc(sizeof(char *) * (size_t)total);
  for (int64_t i = 0; i < total; i++) {
    keys[i] = malloc(WIDTH);
    memcpy(keys[i], blob + i * WIDTH, WIDTH);
  }

  cap = 1;
  while (cap < (uint64_t)(n * 3)) cap <<= 1;
  table = calloc(cap, sizeof(Slot));

  for (int64_t i = 0; i < n; i++) tinsert(keys[i], i * 7);

  int64_t hits = 0;
  for (int64_t r = 0; r < reps; r++) {
    for (int64_t i = 0; i < n; i++) {
      int64_t v = 0;
      tlookup(keys[i], &v);
      hits += v;
    }
  }

  int64_t misses = 0;
  for (int64_t r = 0; r < reps; r++) {
    for (int64_t i = n; i < total; i++) {
      int64_t v = 0;
      if (!tlookup(keys[i], &v)) misses++;
    }
  }

  for (int64_t i = 0; i < n; i++) {
    if (i % 4 == 0) tdelete(keys[i]);
  }

  int64_t sum2 = 0, remaining = 0;
  for (int64_t i = 0; i < n; i++) {
    int64_t v = 0;
    if (tlookup(keys[i], &v)) {
      sum2 += v;
      remaining++;
    }
  }

  int64_t live = 0;
  for (uint64_t i = 0; i < cap; i++) {
    if (table[i].state == 1) live++;
  }

  printf("%lld %lld %lld %lld %lld\n", (long long)hits, (long long)misses,
         (long long)remaining, (long long)sum2, (long long)live);
  REPORT_ALLOCS();
  return 0;
}
