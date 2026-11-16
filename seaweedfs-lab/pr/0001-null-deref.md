## Summary

Fixes a NULL pointer dereference that crashes the server when the Prometheus
exporter is enabled but the dynamic metrics are not.

`dynamic_metrics_export_info()` was the only function in
`src/monitoring/dynamic_metrics.cc` that dereferenced the global
`dynamic_metrics` unique_ptr without checking it first. The pointer is only
created by `dynamic_metrics__init()`, which `nfs_main.c` calls only when
`Enable_Dynamic_Metrics` is true. The Prometheus exporter, however, is started
whenever `Enable_Metrics` is true, and it calls `update_export()` for every
export whenever the export list changes.

With `Enable_Metrics = true` and `Enable_Dynamic_Metrics = false` the
exporter therefore reaches `dynamic_metrics_export_info()` with a NULL
pointer and the server dies with SIGSEGV:

```
#0 ganesha_monitoring::dynamic_metrics_export_info(...)      unique_ptr.h:199
#1 ganesha_monitoring::update_export(...)                     src/monitoring/prometheus_exposer.cc:506
#2 foreach_gsh_export(...)                                    src/support/export_mgr.c:938
#3 ganesha_monitoring::PrometheusExposer::server_thread(...)  src/monitoring/prometheus_exposer.cc:398
```

The result is a crash loop on startup for that configuration.

## The change

Two lines, restoring the invariant the other four functions in the same file
already have (`dynamic_metrics__observe_nfs_request`,
`dynamic_metrics__observe_nfs_io` and the two that follow them):

```c
void dynamic_metrics_export_info(const char *path, const uint64_t total_size,
				 const uint64_t avail_size,
				 const uint64_t total_files,
				 const uint64_t avail_files)
{
+	if (!dynamic_metrics)
+		return;
 	if (total_size) {
```

The fix is identical on the `v15.9` and `next` lines; the affected lines are
byte-for-byte the same in both.

## Verification

Built and run on V15.9 and V15.12 with `Enable_Metrics = true` and
`Enable_Dynamic_Metrics = false`:

- before: SIGSEGV, systemd `NRestarts` climbing continuously
- after: the server stays up, `NRestarts = 0` over a 120 s run

The patch was also built and format-checked on a clean GitHub Actions runner
(`build` reaches 100% and links `ganesha.nfsd`; the `format` job reports
`1 file(s) checked, the changed lines are clean`).

## Notes for the reviewer

- **This pull request shows no checks of its own.** A pull request is checked
  with the workflows that exist in its *base* branch, and `next` has no
  workflow yet. Once the companion pull request that adds the CI is merged,
  both jobs run here automatically.
- No behaviour change when `Enable_Dynamic_Metrics = true`: the pointer is
  non-NULL and the guard is a no-op.
- The exported function is only reached from the monitoring path
  (`prometheus_exposer.cc:506`), so the guard cannot affect request handling.
