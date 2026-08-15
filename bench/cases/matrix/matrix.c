// Matches matrix.bit exactly: same data, same i-k-j loop order.
#include <stdio.h>
#include <stdlib.h>

int main(void) {
  long n = 512;
  double *a = malloc(sizeof(double) * n * n);
  double *b = malloc(sizeof(double) * n * n);
  double *c = calloc(n * n, sizeof(double));

  for (long i = 0; i < n; i++) {
    for (long j = 0; j < n; j++) {
      a[i * n + j] = (double)((i + j) % 13);
      b[i * n + j] = (double)((i * 2 + j * 3) % 17);
    }
  }

  for (long i = 0; i < n; i++) {
    for (long k = 0; k < n; k++) {
      double aik = a[i * n + k];
      for (long j = 0; j < n; j++) {
        c[i * n + j] += aik * b[k * n + j];
      }
    }
  }

  double sum = 0.0, trace = 0.0;
  for (long i = 0; i < n * n; i++) sum += c[i];
  for (long d = 0; d < n; d++) trace += c[d * n + d];

  printf("%lld %lld %lld %lld\n", (long long)sum, (long long)trace, (long long)c[0], (long long)c[n * n - 1]);
  free(a);
  free(b);
  free(c);
  return 0;
}
