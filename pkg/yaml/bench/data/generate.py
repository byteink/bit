#!/usr/bin/env python3
# pkg/yaml/bench/data/generate.py — deterministic generator for k8s-manifests.yaml (#5501).
#
# Run once, by hand, to produce the checked-in fixture; run.sh never calls this
# — a benchmark whose input changes per run cannot be compared across commits
# (#5501's own ticket). Re-run only to intentionally regenerate the fixture,
# and commit the new output in the same change as whatever motivated it.
#
# Deterministic: no randomness, no wall-clock, no environment. Same output on
# every machine, every time, so the fixture in git IS what this script emits.
import sys

DOC_COUNT = 480  # tuned to land the output comfortably over 1 MiB.

# Reused across every document via a YAML anchor/alias pair (block mappings
# exercised for real, well under the package's 100,000-alias-expansion and
# 1,000,000-node budgets: DOC_COUNT aliases total, not exponential chaining).
COMMON_LABELS = """
  labels: &commonLabels
    app.kubernetes.io/part-of: bench-suite
    app.kubernetes.io/managed-by: bench-generator
    team: platform
"""


def deployment(i: int) -> str:
    name = f"svc-{i:04d}"
    # Block scalar (the entrypoint script) + a quoted scalar (an annotation
    # holding a colon and a newline-sensitive value) + block sequences
    # (containers, env, ports) + a block mapping reusing the anchored labels.
    return f"""---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {name}
  namespace: bench
  annotations:
    description: "service {i}: handles shard \\"{i % 16}\\", owner: platform-team"
{COMMON_LABELS}
spec:
  replicas: {2 + (i % 5)}
  selector:
    matchLabels:
      app: {name}
  template:
    metadata:
      labels: *commonLabels
    spec:
      containers:
        - name: {name}
          image: registry.internal/bench/{name}:1.{i % 9}.0
          command:
            - /bin/sh
            - -c
            - |
              echo "starting {name}"
              export SHARD={i % 16}
              exec /app/server --port=8080 --shard="$SHARD"
          ports:
            - containerPort: 8080
              name: http
            - containerPort: 9090
              name: metrics
          env:
            - name: SERVICE_NAME
              value: {name}
            - name: LOG_LEVEL
              value: info
            - name: FEATURE_FLAGS
              value: "shadow-writes,new-router"
          resources:
            requests:
              cpu: "250m"
              memory: "256Mi"
            limits:
              cpu: "500m"
              memory: "512Mi"
          readinessProbe:
            httpGet:
              path: /healthz
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 10
          securityContext:
            privileged: false
            readOnlyRootFilesystem: true
            allowPrivilegeEscalation: false
      restartPolicy: Always
      automountServiceAccountToken: false
"""


def service(i: int) -> str:
    name = f"svc-{i:04d}"
    return f"""---
apiVersion: v1
kind: Service
metadata:
  name: {name}
  namespace: bench
{COMMON_LABELS}
spec:
  selector:
    app: {name}
  ports:
    - name: http
      port: 80
      targetPort: 8080
    - name: metrics
      port: 9090
      targetPort: 9090
  type: ClusterIP
"""


def configmap(i: int) -> str:
    name = f"svc-{i:04d}-config"
    return f"""---
apiVersion: v1
kind: ConfigMap
metadata:
  name: {name}
  namespace: bench
{COMMON_LABELS}
data:
  app.yaml: |
    server:
      port: 8080
      timeoutSeconds: 30
    routing:
      strategy: round-robin
      retries: 3
  enabled: "true"
  maxConnections: "128"
  tags:
    - production
    - shard-{i % 16}
    - region-us-east
"""


def main() -> None:
    parts = []
    for i in range(DOC_COUNT):
        parts.append(deployment(i))
        parts.append(service(i))
        parts.append(configmap(i))
    out = "".join(parts)
    sys.stdout.write(out)


if __name__ == "__main__":
    main()
