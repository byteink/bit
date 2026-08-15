// Matches strings.bit: build via a hand-rolled growable buffer (C has no
// built-in string builder), then window-slice, compare and concatenate.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static long mix(long i) { return ((i + 1) * 2654435761L) % 2147483647L; }

typedef struct { char *buf; size_t len, cap; } Buf;

static void bufPush(Buf *b, char c) {
  if (b->len + 1 >= b->cap) {
    b->cap *= 2;
    b->buf = realloc(b->buf, b->cap);
  }
  b->buf[b->len++] = c;
}

int main(void) {
  long n = 3000000;
  Buf b;
  b.cap = 1 << 16;
  b.len = 0;
  b.buf = malloc(b.cap);

  for (long i = 0; i < n; i++) {
    long tokLen = 3 + mix(i) % 12;
    for (long k = 0; k < tokLen; k++) {
      bufPush(&b, (char)(97 + mix(i * 37 + k + 1) % 26));
    }
    bufPush(&b, ' ');
  }
  b.buf[b.len] = '\0';
  long total = (long)b.len;

  long width = 8;
  long windows = total / width;
  long matches = 0;
  for (long w = 0; w < windows - 1; w++) {
    if (memcmp(b.buf + w * width, b.buf + (w + 1) * width, width) == 0) {
      matches++;
    }
  }

  char *joined = malloc(10001);
  memcpy(joined, b.buf, 5000);
  memcpy(joined + 5000, b.buf + total - 5000, 5000);
  joined[10000] = '\0';
  long joinedLen = (long)strlen(joined);

  printf("%ld %ld %ld\n", total, matches, joinedLen);
  free(b.buf);
  free(joined);
  return 0;
}
