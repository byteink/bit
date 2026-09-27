#!/usr/bin/env python3
# pkg/yaml/bench/data/generate.py - deterministic generator for the two checked-in
# fixtures: k8s-manifests.yaml (#5501) and yaml-features.yaml (#6049).
#
#   python3 generate.py > k8s-manifests.yaml
#   python3 generate.py features > yaml-features.yaml
#
# Run once, by hand, to produce the checked-in fixtures; run.sh never calls this
# - a benchmark whose input changes per run cannot be compared across commits
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


FEATURE_DOC_COUNT = 1200  # tuned to land yaml-features.yaml near 1 MiB, like k8s-manifests.yaml.


def feature_doc(i: int) -> str:
    # The syntax k8s-manifests.yaml barely touches (#6049): per-document anchors
    # reused by aliases on scalars, mappings and sequences, in block and flow
    # context; every block scalar header (| |- > >-); nested and empty flow
    # collections; single-quoted '' escapes; double-quoted escapes (\t \n \"
    # \\ \x \u) and a multi-line double-quoted fold. No floats and no merge
    # keys: the canonical walk has no portable float spelling, and `<<` is
    # YAML 1.1, which pkg/yaml rejects by design (docs/conformance.md).
    return f"""---
# record {i}
defaults: &defaults
  retries: {i % 7}
  timeout: {100 + i}
  enabled: {"true" if i % 2 == 0 else "false"}
  owner: ~
  backup:
port: &port {8000 + i % 100}
tags: &tags [alpha, "beta-{i}", 'gamma''s', {i}, null]
primary:
  settings: *defaults
  labels: *tags
  name: &name "node-{i}\\tsvc\\n\\"quoted\\" \\\\ caf\\u00e9 \\x41\\u263A"
  alias_of_name: *name
  ports: [*port, 9090, *port]
  aliases: [*name, *tags, *defaults]
replicas:
  - {{id: {i}, role: leader, zone: "us-east-1a", weight: 10, extra: null}}
  - {{id: {i + 1}, role: follower, zone: 'us-east-1b', weight: 5, extra: ~}}
  - [nested, [deep, {{k: v, n: {i % 13}}}], {{}}, [], ""]
  - &replica
    id: -{i}
    role: 'observer'
    settings: *defaults
  - *replica
script: |
  #!/bin/sh
  set -eu
  echo "record {i}"
  for f in a b c; do
    echo "$f: done"
  done
note: >
  This is a folded
  paragraph for record {i},
  wrapped across lines.

  Second paragraph stays separate.
trimmed: |-
  no trailing newline {i}
  second line
folded_strip: >-
  folded and
  stripped {i}
single: 'it''s record {i}: with ''quotes'' and "doubles" # not a comment'
escapes: "tab\\there, nl\\nthere, bs\\\\, quote\\", hex \\x7e, uni \\u00fc\\u4e2d"
multi_line_dq: "first line
  continued line {i}

  new paragraph"
matrix: [[1, 2, 3], [4, 5, 6], [{i % 10}, {i % 11}, {i % 12}]]
map_of_flow: {{a: [1, 2], b: {{c: d, e: [f, g]}}, h: "i j", 'k l': true}}
"""


def k8s() -> str:
    parts = []
    for i in range(DOC_COUNT):
        parts.append(deployment(i))
        parts.append(service(i))
        parts.append(configmap(i))
    return "".join(parts)


def features() -> str:
    return "".join(feature_doc(i) for i in range(FEATURE_DOC_COUNT))


def main() -> None:
    which = sys.argv[1] if len(sys.argv) > 1 else "k8s"
    if which == "k8s":
        sys.stdout.write(k8s())
    elif which == "features":
        sys.stdout.write(features())
    else:
        sys.exit(f"generate.py: unknown fixture {which!r} (k8s | features)")


if __name__ == "__main__":
    main()
