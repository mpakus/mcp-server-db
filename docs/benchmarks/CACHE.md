# Query-cache benchmark interpretation

The current [four-mode stress report](STRESS.md) compares **stdio**, **HTTP**,
**stdio + cache** and **HTTP + cache**. Its tables replace the older standalone
cache comparison. [Current raw results](stress-2026-10-20.json) retain cache-status
counts, every phase, resource samples and environment/build hashes.

Uncached modes disable the server cache and omit the tool's `cache` argument.
Cached modes enable it and send `cache: true`; all four modes use the same bound
fixture lookup and total concurrency. The cache has a five-second fixed TTL,
1000-entry cap and 65536-byte per-entry cap. Warmed runs still include expiry
and SQL refreshes during their repeated 20-second samples.

Cached RPS measures reused JSON payloads, not SQL execution capacity. Hot runs
record hit/miss counts; unique-key cold probes exercise storage bounds and
expiry, and enabled-cache probes without opt-in confirm that reads stay live.
The cold SQL includes an extra predicate/parameter, so its timing does not isolate
cache overhead. Short probes are descriptive, not statistically confirmed gains
or regressions. All performance runs disable PII and dashboard publishing.

For real usage, [configure the cache](../CONFIGURATION.md#optional-query-cache)
and [opt in per read](../USER-GUIDE.md#optional-cached-reads). Writes through one
instance invalidate its cache; changes elsewhere rely on TTL. Resource discovery
stays live. Freshness-sensitive or volatile reads should remain uncached.
Use [STRESS.md's reproduction commands](STRESS.md#reproduce) for a fresh measurement.
