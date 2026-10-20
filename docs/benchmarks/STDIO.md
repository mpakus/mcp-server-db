# Stdio and HTTP performance

See [the current four-mode benchmark](STRESS.md#results) for **stdio**, **HTTP**,
**stdio + cache** and **HTTP + cache** on both engines. Its result tables replace
the older stdio before/after comparison. [Raw current measurements](stress-2026-10-20.json)
include all phases and resource samples.

Both transports use supervised session GenServers and bounded query workers.
Stdio has one logical session per executable, buffered input and one stdout
writer that batches responses already waiting. HTTP uses authenticated
keep-alive connections and independent session IDs.

The current benchmark holds total concurrency at 64, with one stdio session
and one generator thread versus four HTTP sessions/generator threads. Therefore
cross-transport differences include session and client parallelism; they do not
measure HTTP framing or pipe overhead in isolation. Cache hits still traverse
session tasks, policy and transport, but skip database execution.

Use [the shared reproduction procedure](STRESS.md#reproduce). To focus on one
transport, set `CACHE_BENCH_TRANSPORTS=stdio` or `http`. Pool/worker settings,
latency methodology and laptop versions are defined once in STRESS.md.
Historical raw data is listed in the [benchmark index](README.md).
