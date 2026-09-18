# pkg/yaml/bench results — pending

The measured table (#5501) is not published yet: `run.sh`'s own exclusivity
requirement (an idle box, 15+ runs) has not been met in this worktree. Run
`./run.sh` on a drained machine to fill this in — it overwrites this whole
file and the `BENCH` block in `../README.md` together, every time.

What HAS been proven, on Bit `9221db25`: all three implementations parse
`data/k8s-manifests.yaml` to the identical `docs`/`nodes`/checksum triple.
`./run.sh --verify` reproduces this without timing anything:

```
bit:      docs=1440 nodes=96480 crc=3200269929
yaml.v3:  docs=1440 nodes=96480 crc=3200269929
goccy:    docs=1440 nodes=96480 crc=3200269929
```

And the disagreement path is real, not just written: flipping one byte of
`apps/yamlv3/main.go`'s boolean encoding (`"Bt;"` -> `"Bf;"`) changes only
that side's checksum (`3200269929` -> `908521919`) and `run.sh --verify`
exits 1 with a named `CHECKSUM MISMATCH` naming which side diverged, before
either build touches a stopwatch.
