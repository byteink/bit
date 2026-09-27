/*
 * tomlc17's side of pkg/toml/bench (#6048). Same two modes and the same
 * canonical checksum as ../bit/main.bit, so run.sh diffs every side's
 * stdout byte for byte before timing anything:
 *
 *   tomlc17bench parse <file>      read + parse once, print "entries=<N>"
 *   tomlc17bench checksum <file>   ... and "hash=<H>", CRC-32C (Castagnoli)
 *                                  folded over keys sorted bytewise
 *
 * tomlc17 stores fractional seconds as microseconds; the fixtures never
 * carry a seventh digit, so usec * 1000 is the exact nanosecond field.
 */
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "tomlc17.h"

static uint32_t crctab[256];

static void crcinit(void) {
  for (uint32_t i = 0; i < 256; i++) {
    uint32_t c = i;
    for (int k = 0; k < 8; k++)
      c = (c & 1) ? (c >> 1) ^ 0x82F63B78u : c >> 1;
    crctab[i] = c;
  }
}

/* Chainable like Go's crc32.Update: fold(fold(h, a), b) == fold(h, a||b). */
static uint32_t fold(uint32_t h, const char *p, size_t n) {
  uint32_t c = ~h;
  for (size_t i = 0; i < n; i++)
    c = crctab[(c ^ (uint8_t)p[i]) & 0xff] ^ (c >> 8);
  return ~c;
}

static uint32_t foldf(uint32_t h, const char *fmt, ...) {
  char buf[128];
  va_list ap;
  va_start(ap, fmt);
  int n = vsnprintf(buf, sizeof buf, fmt, ap);
  va_end(ap);
  if (n < 0 || (size_t)n >= sizeof buf) {
    fprintf(stderr, "foldf: overflow\n");
    exit(1);
  }
  return fold(h, buf, (size_t)n);
}

static int64_t count(const toml_datum_t *d) {
  int64_t total = 0;
  if (d->type == TOML_TABLE) {
    total = d->u.tab.size;
    for (int i = 0; i < d->u.tab.size; i++)
      total += count(&d->u.tab.value[i]);
  } else if (d->type == TOML_ARRAY) {
    for (int i = 0; i < d->u.arr.size; i++)
      total += count(&d->u.arr.elem[i]);
  }
  return total;
}

static const toml_datum_t *sorttab; /* qsort has no context argument in C17 */

static int keycmp(const void *a, const void *b) {
  int i = *(const int *)a, j = *(const int *)b;
  int li = sorttab->u.tab.len[i], lj = sorttab->u.tab.len[j];
  int c = memcmp(sorttab->u.tab.key[i], sorttab->u.tab.key[j], li < lj ? li : lj);
  return c ? c : (li > lj) - (li < lj);
}

static uint32_t hashvalue(uint32_t h, const toml_datum_t *d);

static uint32_t hashtable(uint32_t h, const toml_datum_t *d) {
  int n = d->u.tab.size;
  int *idx = malloc(sizeof(int) * (size_t)(n ? n : 1));
  if (!idx) {
    fprintf(stderr, "out of memory\n");
    exit(1);
  }
  for (int i = 0; i < n; i++)
    idx[i] = i;
  sorttab = d;
  qsort(idx, (size_t)n, sizeof(int), keycmp);
  h = foldf(h, "T%d:", n);
  for (int i = 0; i < n; i++) {
    int k = idx[i];
    h = foldf(h, "K%d:", d->u.tab.len[k]);
    h = fold(h, d->u.tab.key[k], (size_t)d->u.tab.len[k]);
    h = fold(h, "=", 1);
    h = hashvalue(h, &d->u.tab.value[k]);
  }
  free(idx);
  return fold(h, "}", 1);
}

static uint32_t hashtime(uint32_t h, const toml_datum_t *d) {
  return foldf(h, "%02d:%02d:%02d.%09ld", d->u.ts.hour, d->u.ts.minute,
               d->u.ts.second, (long)d->u.ts.usec * 1000);
}

static uint32_t hashdate(uint32_t h, const toml_datum_t *d) {
  return foldf(h, "%04d-%02d-%02d", d->u.ts.year, d->u.ts.month, d->u.ts.day);
}

static uint32_t hashvalue(uint32_t h, const toml_datum_t *d) {
  switch (d->type) {
  case TOML_TABLE:
    return hashtable(h, d);
  case TOML_ARRAY:
    h = foldf(h, "A%d:", d->u.arr.size);
    for (int i = 0; i < d->u.arr.size; i++)
      h = hashvalue(h, &d->u.arr.elem[i]);
    return fold(h, "]", 1);
  case TOML_STRING:
    h = foldf(h, "S%d:", d->u.str.len);
    return fold(h, d->u.str.ptr, (size_t)d->u.str.len);
  case TOML_INT64:
    return foldf(h, "I%lld;", (long long)d->u.int64);
  case TOML_FP64:
    return fold(h, "F;", 2);
  case TOML_BOOLEAN:
    return fold(h, d->u.boolean ? "Bt;" : "Bf;", 3);
  case TOML_DATE:
    return fold(hashdate(fold(h, "D", 1), d), ";", 1);
  case TOML_TIME:
    return fold(hashtime(fold(h, "M", 1), d), ";", 1);
  case TOML_DATETIME:
    h = hashdate(fold(h, "N", 1), d);
    return fold(hashtime(fold(h, "T", 1), d), ";", 1);
  case TOML_DATETIMETZ: {
    int m = d->u.ts.tz < 0 ? -d->u.ts.tz : d->u.ts.tz;
    h = hashdate(fold(h, "O", 1), d);
    h = hashtime(fold(h, "T", 1), d);
    return foldf(h, "%c%02d:%02d;", d->u.ts.tz < 0 ? '-' : '+', m / 60, m % 60);
  }
  default:
    return h;
  }
}

static char *slurp(const char *path, int *len) {
  FILE *f = fopen(path, "rb");
  if (!f)
    return NULL;
  char *buf = NULL;
  long n = -1;
  if (fseek(f, 0, SEEK_END) == 0 && (n = ftell(f)) >= 0 && fseek(f, 0, SEEK_SET) == 0)
    buf = malloc((size_t)n + 1);
  if (buf && fread(buf, 1, (size_t)n, f) != (size_t)n) {
    free(buf);
    buf = NULL;
  }
  fclose(f);
  if (!buf)
    return NULL;
  buf[n] = 0;
  *len = (int)n;
  return buf;
}

int main(int argc, char **argv) {
  if (argc < 3) {
    fprintf(stderr, "usage: tomlc17bench <parse|checksum> <file.toml>\n");
    return 1;
  }
  int len = 0;
  char *src = slurp(argv[2], &len);
  if (!src) {
    fprintf(stderr, "cannot read %s\n", argv[2]);
    return 1;
  }
  toml_result_t r = toml_parse(src, len);
  if (!r.ok) {
    fprintf(stderr, "%s\n", r.errmsg);
    return 1;
  }
  int64_t n = count(&r.toptab);
  if (strcmp(argv[1], "checksum") == 0) {
    crcinit();
    printf("entries=%lld hash=%u\n", (long long)n, hashvalue(0, &r.toptab));
  } else {
    printf("entries=%lld\n", (long long)n);
  }
  /* No toml_free: every other side exits with its tree still live. */
  return 0;
}
