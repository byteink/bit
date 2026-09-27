// The canonical walk's encoding, shared by the two native peers
// (../libyaml/main.c and ../rapidyaml/main.cpp, #6049). It must produce
// byte-for-byte what ../bit/main.bit's canonicalWalk writes - that file's
// header explains why the checksum is the agreement proof:
//
//   mapping  "M<pairs>;"        sequence "Q<items>;"
//   string   "S<len>:<bytes>;"  null     "N;"
//   bool     "Bt;" / "Bf;"      int      "I<decimal i64>;"
//
// Neither library types a plain scalar, so canon_scalar() applies the YAML
// 1.2 core schema (spec 10.3.2) itself, exactly as pkg/yaml/schema.bit does:
// only a PLAIN scalar is typed, a quoted or block scalar is always a string.
// A plain scalar the core schema reads as a float is fatal, not guessed at:
// the walk has no float spelling every language prints identically, and the
// fixtures deliberately contain none (data/generate.py).
#ifndef CANON_H
#define CANON_H

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#if defined(__ARM_FEATURE_CRC32)
#include <arm_acle.h>
#endif

typedef struct {
  char *p;
  size_t len, cap;
} canon_buf;

static void canon_fatal(const char *what, const char *s, size_t n) {
  fprintf(stderr, "canon: %s: %.*s\n", what, (int)n, s);
  exit(1);
}

static void canon_put(canon_buf *b, const char *s, size_t n) {
  if (b->len + n > b->cap) {
    size_t cap = b->cap ? b->cap : 1 << 20;
    while (cap < b->len + n) cap *= 2;
    char *p = (char *)realloc(b->p, cap);
    if (!p) canon_fatal("out of memory", "", 0);
    b->p = p;
    b->cap = cap;
  }
  memcpy(b->p + b->len, s, n);
  b->len += n;
}

// Writes tag, then v in decimal (with a leading '-' when neg), then end.
static void canon_num(canon_buf *b, char tag, uint64_t v, int neg, char end) {
  char t[24];
  size_t i = sizeof t;
  do {
    t[--i] = (char)('0' + v % 10);
    v /= 10;
  } while (v);
  if (neg) t[--i] = '-';
  t[--i] = tag;
  canon_put(b, t + i, sizeof t - i);
  canon_put(b, &end, 1);
}

static int canon_is(const char *s, size_t n, const char *a, const char *b, const char *c) {
  size_t k = strlen(a);
  return n == k && (!memcmp(s, a, k) || !memcmp(s, b, k) || !memcmp(s, c, k));
}

static int canon_digit(char c, int base) {
  int d = c >= '0' && c <= '9' ? c - '0'
          : c >= 'a' && c <= 'f' ? c - 'a' + 10
          : c >= 'A' && c <= 'F' ? c - 'A' + 10
                                 : 99;
  return d < base ? d : -1;
}

// Core-schema int: [-+]?[0-9]+ | 0o[0-7]+ | 0x[0-9a-fA-F]+. Returns 1 and
// writes the token when s is one; an int that does not fit i64 is fatal.
static int canon_int(canon_buf *b, const char *s, size_t n) {
  size_t i = 0;
  int neg = 0, base = 10;
  if (n > 2 && s[0] == '0' && (s[1] == 'o' || s[1] == 'x')) {
    base = s[1] == 'o' ? 8 : 16;
    i = 2;
  } else if (n > 1 && (s[0] == '-' || s[0] == '+')) {
    neg = s[0] == '-';
    i = 1;
  }
  if (i == n) return 0;
  uint64_t v = 0;
  for (; i < n; i++) {
    int d = canon_digit(s[i], base);
    if (d < 0) return 0;
    if (v > (UINT64_MAX - (uint64_t)d) / (uint64_t)base) canon_fatal("int overflows i64", s, n);
    v = v * (uint64_t)base + (uint64_t)d;
  }
  if (v > (uint64_t)INT64_MAX + (uint64_t)neg) canon_fatal("int overflows i64", s, n);
  canon_num(b, 'I', v, neg && v != 0, ';');
  return 1;
}

// Core-schema float: [-+]?(\.[0-9]+|[0-9]+(\.[0-9]*)?)([eE][-+]?[0-9]+)?,
// [-+]?\.(inf|Inf|INF), \.(nan|NaN|NAN). Checked after canon_int.
static int canon_is_float(const char *s, size_t n) {
  size_t i = n && (s[0] == '-' || s[0] == '+');
  if (canon_is(s + i, n - i, ".inf", ".Inf", ".INF") || canon_is(s, n, ".nan", ".NaN", ".NAN")) return 1;
  size_t d = 0;
  while (i < n && s[i] >= '0' && s[i] <= '9') i++, d++;
  if (i < n && s[i] == '.') {
    i++;
    while (i < n && s[i] >= '0' && s[i] <= '9') i++, d++;
  }
  if (d == 0) return 0;
  if (i < n && (s[i] == 'e' || s[i] == 'E')) {
    i++;
    if (i < n && (s[i] == '-' || s[i] == '+')) i++;
    size_t e = i;
    while (i < n && s[i] >= '0' && s[i] <= '9') i++;
    if (i == e) return 0;
  }
  return i == n;
}

static void canon_scalar(canon_buf *b, const char *s, size_t n, int plain) {
  if (plain) {
    if (n == 0 || (n == 1 && s[0] == '~') || canon_is(s, n, "null", "Null", "NULL")) {
      canon_put(b, "N;", 2);
      return;
    }
    if (canon_is(s, n, "true", "True", "TRUE")) {
      canon_put(b, "Bt;", 3);
      return;
    }
    if (canon_is(s, n, "false", "False", "FALSE")) {
      canon_put(b, "Bf;", 3);
      return;
    }
    if (canon_int(b, s, n)) return;
    if (canon_is_float(s, n)) canon_fatal("float has no canonical spelling", s, n);
  }
  canon_num(b, 'S', n, 0, ':');
  canon_put(b, s, n);
  canon_put(b, ";", 1);
}

// CRC-32C (Castagnoli), the same function as std/hash's crc32c and Go's
// crc32.MakeTable(crc32.Castagnoli). Hardware instructions where the target
// has them, as Go's arm64 and amd64 implementations do.
static uint32_t canon_crc32c(const unsigned char *p, size_t n) {
  uint32_t c = 0xffffffffu;
#if defined(__ARM_FEATURE_CRC32)
  for (; n >= 8; p += 8, n -= 8) {
    uint64_t v;
    memcpy(&v, p, 8);
    c = __crc32cd(c, v);
  }
  for (; n; p++, n--) c = __crc32cb(c, *p);
#else
  for (; n; p++, n--) {
    c ^= *p;
    for (int k = 0; k < 8; k++) c = (c >> 1) ^ (0x82f63b78u & (0u - (c & 1u)));
  }
#endif
  return ~c;
}

#endif
