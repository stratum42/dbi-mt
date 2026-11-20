# DBI for perl5-mt

This repository carries a small set of changes on top of upstream
[DBI](https://github.com/perl5-dbi/dbi) so that DBI and thread-safe DBD
drivers can run in-process (Tier 1) across
[`perl5-mt`](https://github.com/stratum42/perl5-mt) worker threads, while
remaining compatible with stock Perl 5.

DBI is the work of Tim Bunce, H.Merijn Brand, and decades of contributors
across the Perl community. Everything here builds directly on their design,
and upstream history is left untouched. For the original upstream DBI quick
start, mailing list, and support guidelines, see
[README.upstream.md](README.upstream.md).

## What Changed and Why

1. **Tier 1 (`PERL_XS_THREADSAFE=1`) support in `DBI.xs` and `DBIXS.h`**
   - `Makefile.PL` detects `perl5-mt` via `DBI::DBD::dbd_mt_threadsafe_defines()`
     and adds `-DPERL_XS_THREADSAFE=1` unless `PERL_DBI_NO_MT=1` is set.
   - `DBIXS.h` defines `PERL_NO_GET_CONTEXT` when `PERL_XS_THREADSAFE` is active
     and loads/stores the cached `dbi_state_lval_p` pointer with acquire/release
     atomics.
   - Outer-to-inner method dispatch caching (`dbi_ima_t`) is split so that the
     shared `CV` metadata holds only an immutable slot index (`ima_id`), while
     each interpreter keeps its own `stash`/`gv`/`generation` cache in
     `MY_CXT.ima_cache`. That avoids cross-thread writes into frozen `CV`s after
     `MT::Image::freeze()`.
   - Dynamic dispatch wrappers created by `_install_method` are marked
     `CvMT_THREADSAFE_on`, and `XS_DBI_dispatch` skips `use_xsbypass` when the
     target driver XSUB is a Tier 2 remote compartment (`CvMT_REMOTE`).

2. **Freeze and `CLONE` hygiene in Perl modules**
   - Package-scoped `our` variables and `CLONE` hooks are used for driver
     handles and caches in `DBI.pm`, `DBD::Switch`, `DBD::Sponge`,
     `DBD::Gofer::Transport::null`, `DBD::Gofer::Transport::stream`, and
     `DBI::PurePerl` so worker interpreters do not inherit frozen parent state.
   - `DBD::File` and `DBD::ExampleP` use lexical directory and file handles
     (`opendir`/`open`) rather than `Symbol::gensym` / `IO::Dir` / `IO::File`
     package globs where those interact poorly with frozen stashes.

3. **Per-worker, fiber-aware connection pooling (`DBI::MT::Pool`)**
   - `DBI::MT::Pool` stores only immutable configuration in the pool object so
     it can be constructed before `MT::Image::freeze()`. Each worker lazily
     maintains its own idle connections in `our %DBI::MT::Pool::_POOLS`
     (cleared in `CLONE`), and parks/wakes contending `MT::Fiber` coroutines
     within that worker.

4. **Dual-gated SIMD helpers (`dbi_arch.h`)**
   - `dbi_arch.h` provides portable acquire/release atomics, architecture
     cache-line sizing, a cached `dbi_arch_force_scalar()` runtime toggle, and
     small SIMD string-scanning helpers for `ChopBlanks` trailing-space
     trimming, `preparse()`, and `neatsvpv()`.
   - Every SIMD path has an exact scalar reference twin and is bypassed when
     compiled with `-DPERL_FORCE_SCALAR` or `-DDBI_FORCE_SCALAR` (or on
     EBCDIC), or at runtime with `PERL_FORCE_SCALAR=1` or
     `PERL_DBI_FORCE_SCALAR=1`.

## Caveats and Limitations

- **Database handles are not shared across threads.** Each `MT::Worker` opens
  and owns its own DBI handles, just as under stock Perl `ithreads`.
- **Tier 1 is opt-in per driver.** Only drivers whose XS code and underlying C
  client library are thread-safe should compile with `-DPERL_XS_THREADSAFE=1`.
  Unmodified drivers continue to run in `perl5-mt` Tier 2 XS compartments. Set
  `PERL_DBI_NO_MT=1` at build time to disable Tier 1 compilation.
- **Blocking C drivers still block the worker OS thread.** `DBI::MT::Pool`
  coordinates `MT::Fiber` checkout contention within a worker, but a
  synchronous C query inside a DBD driver will occupy that worker thread until
  it returns.
- **SIMD helpers are narrow by design.** On short strings or workloads that do
  not enable `ChopBlanks` or heavy `preparse()`, the vector paths are neutral
  relative to the scalar loops; use `PERL_DBI_FORCE_SCALAR=1` to compare on
  your own workload.

## Building and Testing

```sh
/path/to/perl5-mt Makefile.PL
make
/path/to/perl5-mt -Mblib -I/path/to/dbd-sqlite-mt/blib/lib -I/path/to/dbd-sqlite-mt/blib/arch \
    -I/path/to/dbd-odbc-mt/blib/lib -I/path/to/dbd-odbc-mt/blib/arch \
    -MTest::Harness -e 'runtests(@ARGV)' t/mt_*.t
```

## Related Repositories

- [`stratum42/perl5-mt`](https://github.com/stratum42/perl5-mt) — Multi-threaded Perl 5 runtime
- [`stratum42/dbd-sqlite-mt`](https://github.com/stratum42/dbd-sqlite-mt) — `DBD::SQLite` with Tier 1 support
- [`stratum42/dbd-odbc-mt`](https://github.com/stratum42/dbd-odbc-mt) — `DBD::ODBC` with Tier 1 support
- [`stratum42/dbi-mt-bench`](https://github.com/stratum42/dbi-mt-bench) — Benchmarks and reproducibility harness

## Upstream Documentation

The original DBI README by Tim Bunce and the perl5-dbi team is preserved
unchanged at [README.upstream.md](README.upstream.md). Feedback, bug reports,
and corrections are always welcome.
