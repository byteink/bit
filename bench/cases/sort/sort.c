// Matches sort.bit, using C's qsort (typically an introsort/quicksort
// hybrid) -- see sort.bit's header for the fairness note on differing
// algorithms.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static long mix(long i) { return ((i + 1) * 2654435761L) % 2147483647L; }

static int cmpI64(const void *a, const void *b) {
  long x = *(const long *)a, y = *(const long *)b;
  return (x > y) - (x < y);
}

static int cmpStr(const void *a, const void *b) {
  const char *x = *(const char *const *)a;
  const char *y = *(const char *const *)b;
  return strcmp(x, y);
}

int main(void) {
  long mod = 1000000007L;

  long n = 800000;
  long *xs = malloc(sizeof(long) * n);
  for (long i = 0; i < n; i++) xs[i] = mix(i);
  qsort(xs, n, sizeof(long), cmpI64);

  int sortedOk1 = 1;
  for (long i = 1; i < n; i++) {
    if (xs[i] < xs[i - 1]) {
      sortedOk1 = 0;
      break;
    }
  }

  long checksum1 = 0;
  for (long i = 0; i < n; i++) {
    checksum1 = (checksum1 + (xs[i] % mod) * (i + 1)) % mod;
  }

  long m = 150000;
  char **ss = malloc(sizeof(char *) * m);
  for (long i = 0; i < m; i++) {
    long tokLen = 3 + mix(i) % 12;
    char *tok = malloc(tokLen + 1);
    for (long k = 0; k < tokLen; k++) {
      tok[k] = (char)(97 + mix(i * 37 + k + 1) % 26);
    }
    tok[tokLen] = '\0';
    ss[i] = tok;
  }
  qsort(ss, m, sizeof(char *), cmpStr);

  int sortedOk2 = 1;
  for (long i = 1; i < m; i++) {
    if (strcmp(ss[i], ss[i - 1]) < 0) {
      sortedOk2 = 0;
      break;
    }
  }

  long checksum2 = 0;
  for (long i = 0; i < m; i++) {
    long bytesum = 0;
    for (const char *c = ss[i]; *c; c++) bytesum += (unsigned char)*c;
    checksum2 = (checksum2 + bytesum * (i + 1)) % mod;
  }

  printf("%ld %s %ld %s\n", checksum1, sortedOk1 ? "true" : "false", checksum2, sortedOk2 ? "true" : "false");

  free(xs);
  for (long i = 0; i < m; i++) free(ss[i]);
  free(ss);
  return 0;
}
