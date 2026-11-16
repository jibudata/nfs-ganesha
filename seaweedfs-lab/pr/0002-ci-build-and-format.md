## Summary

Adds the first active CI for this repository.

The tree already carried the two ingredients of a CI setup - a `.clang-format`
file and a CMake build - but nothing ran either of them:

- `.github/` contained only a pull-request template, no workflow
- `.travis.yml` pointed at a service that no longer runs, and only built the
  `next` branch
- `.clang-format` (asking for clang-format >= 11) was not wired to anything

A patch that does not compile, or that breaks the formatting of the lines it
touches, could be merged unnoticed. This adds two jobs that run on every push
and every pull request.

## `build`

Configures and compiles the server with the option set that is known to work
for a plain FSAL_VFS build, so a patch that does not compile cannot be merged.

```cmake
cmake -S src -B build \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DUSE_FSAL_VFS=ON \
  -DUSE_FSAL_CEPH=OFF -DUSE_FSAL_CEPH_FSCRYPT=OFF \
  ... (every other FSAL off) ...
  -DUSE_MONITORING=ON -DUSE_GSS=ON -DUSE_NFSIDMAP=DEFAULT_ON
```

Three details worth calling out:

- **Only the `ntirpc` submodule is fetched, and recursively.**
  `src/libntirpc` carries a nested submodule of its own
  (`src/monitoring/prometheus-cpp-lite`), and the vendored headers in it are
  what the ntirpc monitoring code includes. A shallow, non-recursive fetch
  fails the build with `fatal error: prometheus/counter.h: No such file or
  directory`.
- **`libkmip` is deliberately not fetched.** It is only needed for CephFS
  fscrypt, and it is a large clone from a different project.
- **`liburcu-dev` is a hard dependency, not an extra.** `src/CMakeLists.txt`
  looks up `urcu-bp` unconditionally and aborts the configure step with
  `userspace-rcu library not found!` when it is missing. It is in the Ubuntu
  main archive (`0.13.1-1` in jammy, `0.14.0` in noble) and provides both
  `liburcu-bp.so` and the `urcu-bp.h` / `urcu/ref.h` headers the configure
  step looks for.

## `format`

Checks that the lines a branch changed follow the repository's `.clang-format`.

Only the **changed lines** are checked, not the whole file. The tree already
has pre-existing violations - three in `src/monitoring/dynamic_metrics.cc`,
present in the pristine checkout - so a whole-file check would be red before
any change is made, and would bury the signal this job is meant to give.

`.github/scripts/check-format.sh` computes the changed line ranges from
`git diff -U0` and passes them to `clang-format --dry-run --Werror --lines`.
Files listed in `.clang-format-ignore` are skipped. Only C and C++ sources are
checked: handing `clang-format` a shell script or a YAML file produces
meaningless violations.

`clang-format` is pinned to `clang-format-14` so the verdict does not change
when the runner image does.

## Runner and action versions

The runners are pinned to `ubuntu-24.04`, the release the build was validated
on, and `actions/checkout` is pinned to `v5`, which runs on the current Node
runtime.

## Verification

The workflow was run on GitHub Actions against this branch:

| run | trigger | `build` | `format` |
|---|---|---|---|
| [43867569983](https://github.com/jibudata/nfs-ganesha/actions/runs/43867569983) | push to this branch | pass | pass |
| [43867580572](https://github.com/jibudata/nfs-ganesha/actions/runs/43867580572) | pull request #2 | pass | pass |

The `build` job reaches 100% and links `build/ganesha.nfsd` and
`build/FSAL/FSAL_VFS/vfs/libfsalvfs.so`; the `format` job reports
`1 file(s) checked, the changed lines are clean`.

The first run of this workflow failed in the configure step with
`userspace-rcu library not found!`, because `liburcu-dev` was missing from the
dependency list. That is fixed in the follow-up commit.

The `build` job's steps were also run end to end against the `next` branch on a
Linux host before the workflow was written:

```
submodule fetch (recursive, shallow)  ->  ok
cmake configure                        ->  ok (VERSION = 15.12)
cmake --build build --parallel $(nproc)->  ok, 0 warnings, build/ganesha.nfsd produced
```

The `format` job's script was exercised in three cases:

| case | result |
|---|---|
| a branch that changes only `.sh`/`.yml` | passes, 0 files checked |
| a branch changing two well-formatted C lines | passes, 1 file checked |
| a branch changing a mis-formatted C line | fails with a `::error file=` annotation |

The two well-formatted C lines in the middle row are the null-pointer guard
from the companion pull request, so that patch is format-checked by this
workflow on a real runner as well.

## Notes for the reviewer

- **Merge this before the companion null-pointer fix.** A pull request is
  checked with the workflows that exist in its *base* branch, so the fix pull
  request shows no checks at all until this workflow is on `next`. Once it is,
  that pull request gets both jobs automatically.
- The `build` job deliberately builds only the FSAL_VFS configuration. The
  other FSALs need GlusterFS, CephFS, GPFS, Lustre or lustre headers, which
  would make the job slow and fragile. Enabling them is a follow-up.
- The workflow runs on every branch push. If the fork ends up with a lot of
  traffic, restrict the `push` trigger to the branches that matter and keep
  `pull_request` for everything else.
