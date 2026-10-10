# Lambda benchmark fixtures

These files are **not deployed**. They are the code variants used by `scripts/benchmark/run.sh`
to compare cold-start and request latency against the production function (`src/save-order`).

| Variant | What differs from production |
|---|---|
| `baseline` | The production code (`src/save-order`), unchanged |
| `slim-imports` | Low-level `@aws-sdk/client-dynamodb` only (no `lib-dynamodb`), with a small marshalling helper |
| `init-warmup` | `slim-imports` plus client timeouts and credentials/region resolved during init |

Results and the decision they led to are in the [root README](../../README.md#performance).
