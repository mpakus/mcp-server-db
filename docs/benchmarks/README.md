# Benchmarks

The current report is [STRESS.md](STRESS.md): **stdio**, **HTTP**, **stdio + cache**
and **HTTP + cache**, measured from the same build and bound lookup workload
for MySQL and PostgreSQL. It includes RPS, latency, CPU/RSS, cache-hit/miss counts,
laptop/software versions, methodology and reproduction commands.

- [Current raw results](stress-2026-10-20.json): all measured phases, environment and hashes.
- [Four-mode harness](../../test/cache-benchmark.mjs): matched sweeps and repeated confirmations.
- [Stdio/HTTP comparison notes](STDIO.md): session and generator differences.
- [Cache interpretation](CACHE.md): hot results, cold misses and TTL limitations.

Earlier measurements are superseded. Their raw artifacts remain only for historical
reproducibility: [session introduction](session-processes-2026-10-20.json),
[stdio optimization](stdio-2026-10-20.json), and
[initial cache experiment](cache-2026-10-20.json). They use different revisions,
workloads or concurrency and must not be mixed with the current result table.
The older `test/benchmark.mjs` and `test/stdio-benchmark.mjs` harnesses reproduce
those revision comparisons; `test/stress.mjs` also retains its separate overload
sweep. Use the four-mode command in STRESS.md for the current benchmark.
