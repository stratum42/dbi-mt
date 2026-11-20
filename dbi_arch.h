/* vim: ts=8:sw=4:expandtab
 *
 * dbi_arch.h - Architecture detection, cache-line sizing, portable atomics,
 *              and dual-gated SIMD kernels for DBI (perl5-mt).
 *
 * Supports:
 *   - arm64   (NEON; 128B cacheline on Apple Silicon, 64B generic)
 *   - amd64   (runtime-dispatched AVX2 + baseline SSE2; 64B cacheline)
 *   - POWER   (VSX / AltiVec, endian-safe for ppc64le & ppc64 AIX; 128B cacheline)
 *   - s390x   (IBM Z Vector Facility z13+, disabled on EBCDIC; 256B cacheline)
 *   - generic (exact scalar reference twins)
 *
 * Dual-gated parity invariant (matching perl5-mt):
 *   Every SIMD kernel has an exact scalar reference twin.
 *   SIMD is bypassed when:
 *     - Compile time: -DPERL_FORCE_SCALAR, -DDBI_FORCE_SCALAR, or EBCDIC
 *     - Runtime:      PERL_FORCE_SCALAR=1 or PERL_DBI_FORCE_SCALAR=1
 *                     (or force_scalar != 0 passed by caller)
 *   No kernel ever reads outside [s, s + len) / [s, end).
 */

#ifndef DBI_ARCH_H
#define DBI_ARCH_H

#include <stddef.h>
#include <stdint.h>

#ifndef DBI_ARCH_NO_LIBC
# include <stdlib.h>
# include <string.h>
#endif

#ifdef DBI_ARCH_STANDALONE
typedef size_t   STRLEN;
typedef uint32_t U32;
#endif

#ifdef DBI_ARCH_NO_LIBC
# define dbi_arch_memcpy(dst, src, n) __builtin_memcpy((dst), (src), (n))
#else
# define dbi_arch_memcpy(dst, src, n) memcpy((dst), (src), (n))
#endif

/* ============================================================================
 * 1. Architecture detection & cache-line sizing
 * ============================================================================ */

#if defined(__s390x__) || defined(__zarch__) || defined(__SYSC_ZARCH__)
# define DBI_ARCH_S390X 1
# define DBI_ARCH_NAME  "s390x"
# define DBI_CACHELINE_SIZE 256
#elif defined(__powerpc64__) || defined(__ppc64__) || defined(_ARCH_PPC64)
# define DBI_ARCH_POWER 1
# if defined(__LITTLE_ENDIAN__) || (defined(__BYTE_ORDER__) && __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__)
#  define DBI_ARCH_NAME "ppc64le"
# else
#  define DBI_ARCH_NAME "ppc64"
# endif
# define DBI_CACHELINE_SIZE 128
#elif defined(__powerpc__) || defined(__ppc__) || defined(_ARCH_PPC)
# define DBI_ARCH_POWER 1
# define DBI_ARCH_NAME  "ppc"
# define DBI_CACHELINE_SIZE 128
#elif defined(__aarch64__) || defined(_M_ARM64)
# define DBI_ARCH_ARM64 1
# define DBI_ARCH_NAME  "arm64"
# if defined(__APPLE__)
#  define DBI_CACHELINE_SIZE 128
# else
#  define DBI_CACHELINE_SIZE 64
# endif
#elif defined(__x86_64__) || defined(_M_X64)
# define DBI_ARCH_AMD64 1
# define DBI_ARCH_NAME  "amd64"
# define DBI_CACHELINE_SIZE 64
#else
# define DBI_ARCH_GENERIC 1
# define DBI_ARCH_NAME    "generic"
# define DBI_CACHELINE_SIZE 64
#endif

/* Branch prediction & prefetch hints */
#if defined(__GNUC__) || defined(__clang__)
# define DBI_LIKELY(x)        __builtin_expect(!!(x), 1)
# define DBI_UNLIKELY(x)      __builtin_expect(!!(x), 0)
# define DBI_PREFETCH_READ(p) __builtin_prefetch((const void *)(p), 0, 3)
# define DBI_ALIGN_CACHELINE  __attribute__((aligned(DBI_CACHELINE_SIZE)))
#elif defined(_MSC_VER)
# define DBI_LIKELY(x)        (!!(x))
# define DBI_UNLIKELY(x)      (!!(x))
# define DBI_PREFETCH_READ(p) ((void)(p))
# define DBI_ALIGN_CACHELINE  __declspec(align(DBI_CACHELINE_SIZE))
#else
# define DBI_LIKELY(x)        (!!(x))
# define DBI_UNLIKELY(x)      (!!(x))
# define DBI_PREFETCH_READ(p) ((void)(p))
# define DBI_ALIGN_CACHELINE
#endif

/* ============================================================================
 * 2. Architecture-optimal acquire/release atomics
 * ============================================================================ */

#if defined(__GNUC__) || defined(__clang__)
/* Covers GCC, Clang, and IBM Open XL C on POWER/AIX & Linux */
# define dbi_atomic_load_acquire_ptr(var) \
    __atomic_load_n(&(var), __ATOMIC_ACQUIRE)
# define dbi_atomic_store_release_ptr(var, val) \
    __atomic_store_n(&(var), (val), __ATOMIC_RELEASE)

static inline U32
dbi_atomic_inc_u32(U32 *p)
{
    return __atomic_add_fetch(p, (U32)1, __ATOMIC_RELAXED);
}

#elif defined(_MSC_VER)
# include <windows.h>
# define dbi_atomic_load_acquire_ptr(var) \
    InterlockedCompareExchangePointer((PVOID volatile *)&(var), NULL, NULL)
# define dbi_atomic_store_release_ptr(var, val) \
    InterlockedExchangePointer((PVOID volatile *)&(var), (PVOID)(val))

static inline U32
dbi_atomic_inc_u32(U32 *p)
{
    return (U32)InterlockedIncrement((volatile LONG *)p);
}

#elif (defined(__IBMC__) || defined(__IBMCPP__) || defined(__xlC__)) && defined(DBI_ARCH_POWER)
/* Legacy IBM XL C on POWER / AIX */
# include <builtins.h>
# include <sys/atomic_op.h>

static inline void *
_dbi_xlc_ppc_load_acq(void * volatile *p)
{
    void *v = *p;
    __lwsync();
    return v;
}

static inline void
_dbi_xlc_ppc_store_rel(void * volatile *p, void *v)
{
    __lwsync();
    *p = v;
}

# define dbi_atomic_load_acquire_ptr(var) \
    _dbi_xlc_ppc_load_acq((void * volatile *)&(var))
# define dbi_atomic_store_release_ptr(var, val) \
    _dbi_xlc_ppc_store_rel((void * volatile *)&(var), (void *)(val))

static inline U32
dbi_atomic_inc_u32(U32 *p)
{
    return (U32)fetch_and_add((atomic_p)p, 1) + 1;
}

#elif (defined(__IBMC__) || defined(__IBMCPP__)) && defined(DBI_ARCH_S390X)
/* IBM XL C on z/OS / s390x (hardware TSO: loads acquire, stores release) */
# include <builtins.h>

static inline void *
_dbi_xlc_z_load_acq(void * volatile *p)
{
    void *v = *p;
    __fence();
    return v;
}

static inline void
_dbi_xlc_z_store_rel(void * volatile *p, void *v)
{
    __fence();
    *p = v;
}

# define dbi_atomic_load_acquire_ptr(var) \
    _dbi_xlc_z_load_acq((void * volatile *)&(var))
# define dbi_atomic_store_release_ptr(var, val) \
    _dbi_xlc_z_store_rel((void * volatile *)&(var), (void *)(val))

static inline U32
dbi_atomic_inc_u32(U32 *p)
{
    int oldv, newv;
    do {
        oldv = *(volatile int *)p;
        newv = oldv + 1;
    } while (__cs(&oldv, (int *)p, newv));
    return (U32)newv;
}

#else
/* Portable fallback */
# define dbi_atomic_load_acquire_ptr(var)       (var)
# define dbi_atomic_store_release_ptr(var, val) ((var) = (val))

static inline U32
dbi_atomic_inc_u32(U32 *p)
{
    return ++(*p);
}
#endif

/* ============================================================================
 * 3. Compile-time & runtime SIMD gating
 * ============================================================================ */

#if defined(EBCDIC)
# define DBI_ARCH_IS_EBCDIC 1
#else
# define DBI_ARCH_IS_EBCDIC 0
#endif

#if defined(PERL_FORCE_SCALAR) || defined(DBI_FORCE_SCALAR) || defined(EBCDIC)
# define DBI_SIMD_COMPILE_DISABLED 1
#else
# define DBI_SIMD_COMPILE_DISABLED 0
#endif

/* Backend capability flags */
#if !DBI_SIMD_COMPILE_DISABLED
# if defined(DBI_ARCH_AMD64) && (defined(__SSE2__) || defined(_M_X64))
#  include <immintrin.h>
#  define DBI_SIMD_HAVE_SSE2 1
#  if defined(__GNUC__) || defined(__clang__)
#   define DBI_SIMD_HAVE_AVX2_RUNTIME 1
#  endif
# elif defined(DBI_ARCH_ARM64) && (defined(__ARM_NEON) || defined(__ARM_NEON__))
#  include <arm_neon.h>
#  define DBI_SIMD_HAVE_NEON 1
# elif defined(DBI_ARCH_POWER) && (defined(__VSX__) || defined(__ALTIVEC__))
#  include <altivec.h>
   /* Prevent <altivec.h> macros from colliding with Perl/C++ identifiers */
#  undef vector
#  undef pixel
#  undef bool
#  define DBI_SIMD_HAVE_POWER_VEC 1
# elif defined(DBI_ARCH_S390X) && defined(__VEC__)
#  include <vecintrin.h>
#  define DBI_SIMD_HAVE_S390X_VX 1
# endif
#endif /* !DBI_SIMD_COMPILE_DISABLED */

#if defined(DBI_SIMD_HAVE_AVX2_RUNTIME)
static inline int
dbi_arch_cpu_has_avx2(void)
{
# if defined(__AVX2__)
    return 1;
# elif (defined(__GNUC__) && (__GNUC__ > 4 || (__GNUC__ == 4 && __GNUC_MINOR__ >= 8))) || defined(__clang__)
    return __builtin_cpu_supports("avx2") ? 1 : 0;
# else
    return 0;
# endif
}
#endif

static inline int
dbi_arch_force_scalar_env(void)
{
#if DBI_SIMD_COMPILE_DISABLED
    return 1;
#elif defined(DBI_ARCH_NO_LIBC)
    return 0;
#else
    const char *v = getenv("PERL_FORCE_SCALAR");
    if (v && v[0] != '\0' && !(v[0] == '0' && v[1] == '\0'))
        return 1;
    v = getenv("PERL_DBI_FORCE_SCALAR");
    if (v && v[0] != '\0' && !(v[0] == '0' && v[1] == '\0'))
        return 1;
    return 0;
#endif
}

static inline const char *
dbi_arch_simd_name(int force_scalar)
{
    if (DBI_SIMD_COMPILE_DISABLED || force_scalar)
        return "scalar";
#if defined(DBI_SIMD_HAVE_AVX2_RUNTIME)
    if (dbi_arch_cpu_has_avx2())
        return "avx2";
    return "sse2";
#elif defined(DBI_SIMD_HAVE_SSE2)
    return "sse2";
#elif defined(DBI_SIMD_HAVE_NEON)
    return "neon";
#elif defined(DBI_SIMD_HAVE_POWER_VEC)
# if defined(__VSX__)
    return "vsx";
# else
    return "altivec";
# endif
#elif defined(DBI_SIMD_HAVE_S390X_VX)
    return "vx";
#else
    return "scalar";
#endif
}

/* ============================================================================
 * 4. Kernel A: dbi_rtrim_spaces_len
 *    Backward scan removing trailing ASCII ' ' (0x20).
 *    Never reads outside [s, s + len).
 * ============================================================================ */

static inline STRLEN
dbi_rtrim_spaces_len_scalar(const char *s, STRLEN len)
{
    while (len > 0 && s[len - 1] == ' ')
        len--;
    return len;
}

#if defined(DBI_SIMD_HAVE_SSE2)
static inline STRLEN
dbi_rtrim_spaces_len_sse2(const char *s, STRLEN len)
{
    const __m128i sp = _mm_set1_epi8(' ');
    while (len >= 16) {
        __m128i v  = _mm_loadu_si128((const __m128i *)(s + len - 16));
        __m128i eq = _mm_cmpeq_epi8(v, sp);
        uint32_t mask = (uint32_t)_mm_movemask_epi8(eq);
        if (mask == 0xFFFFu) {
            len -= 16;
            continue;
        }
        {
            uint32_t inv = (~mask) & 0xFFFFu;
            return len - (STRLEN)(__builtin_clz(inv) - 16);
        }
    }
    return dbi_rtrim_spaces_len_scalar(s, len);
}

# if defined(DBI_SIMD_HAVE_AVX2_RUNTIME)
__attribute__((target("avx2")))
static inline STRLEN
dbi_rtrim_spaces_len_avx2(const char *s, STRLEN len)
{
    const __m256i sp = _mm256_set1_epi8(' ');
    while (len >= 32) {
        __m256i v  = _mm256_loadu_si256((const __m256i *)(s + len - 32));
        __m256i eq = _mm256_cmpeq_epi8(v, sp);
        uint32_t mask = (uint32_t)_mm256_movemask_epi8(eq);
        if (mask == 0xFFFFFFFFu) {
            len -= 32;
            continue;
        }
        {
            uint32_t inv = ~mask;
            return len - (STRLEN)__builtin_clz(inv);
        }
    }
    return dbi_rtrim_spaces_len_sse2(s, len);
}
# endif /* DBI_SIMD_HAVE_AVX2_RUNTIME */

#elif defined(DBI_SIMD_HAVE_NEON)
static inline STRLEN
dbi_rtrim_spaces_len_neon(const char *s, STRLEN len)
{
    const uint8x16_t sp = vdupq_n_u8((uint8_t)' ');
    while (len >= 16) {
        uint8x16_t v  = vld1q_u8((const uint8_t *)(s + len - 16));
        uint8x16_t eq = vceqq_u8(v, sp);
        if (vminvq_u8(eq) == 0xFFu) {
            len -= 16;
            continue;
        }
        break;
    }
    return dbi_rtrim_spaces_len_scalar(s, len);
}

#elif defined(DBI_SIMD_HAVE_POWER_VEC)
static inline STRLEN
dbi_rtrim_spaces_len_power(const char *s, STRLEN len)
{
    const __vector unsigned char sp = {
        ' ',' ',' ',' ',' ',' ',' ',' ',' ',' ',' ',' ',' ',' ',' ',' '
    };
    while (len >= 16) {
        __vector unsigned char v;
        dbi_arch_memcpy(&v, s + len - 16, 16);
        if (vec_all_eq(v, sp)) {
            len -= 16;
            continue;
        }
        break;
    }
    return dbi_rtrim_spaces_len_scalar(s, len);
}

#elif defined(DBI_SIMD_HAVE_S390X_VX)
static inline STRLEN
dbi_rtrim_spaces_len_s390x(const char *s, STRLEN len)
{
    const __vector unsigned char sp = {
        ' ',' ',' ',' ',' ',' ',' ',' ',' ',' ',' ',' ',' ',' ',' ',' '
    };
    while (len >= 16) {
        __vector unsigned char v;
        dbi_arch_memcpy(&v, s + len - 16, 16);
        if (vec_all_eq(v, sp)) {
            len -= 16;
            continue;
        }
        break;
    }
    return dbi_rtrim_spaces_len_scalar(s, len);
}
#endif

static inline STRLEN
dbi_rtrim_spaces_len(const char *s, STRLEN len, int force_scalar)
{
    if (DBI_SIMD_COMPILE_DISABLED || force_scalar || len < 16)
        return dbi_rtrim_spaces_len_scalar(s, len);
#if defined(DBI_SIMD_HAVE_AVX2_RUNTIME)
    if (len >= 32 && dbi_arch_cpu_has_avx2())
        return dbi_rtrim_spaces_len_avx2(s, len);
    return dbi_rtrim_spaces_len_sse2(s, len);
#elif defined(DBI_SIMD_HAVE_SSE2)
    return dbi_rtrim_spaces_len_sse2(s, len);
#elif defined(DBI_SIMD_HAVE_NEON)
    return dbi_rtrim_spaces_len_neon(s, len);
#elif defined(DBI_SIMD_HAVE_POWER_VEC)
    return dbi_rtrim_spaces_len_power(s, len);
#elif defined(DBI_SIMD_HAVE_S390X_VX)
    return dbi_rtrim_spaces_len_s390x(s, len);
#else
    return dbi_rtrim_spaces_len_scalar(s, len);
#endif
}

/* ============================================================================
 * 5. Kernel B: dbi_scan_sql_plain
 *    Forward scan skipping ordinary SQL characters until any delimiter:
 *      '\'', '"', '-', '/', '?', ':', '#', '\n', '\r', '\0', '%', '{'
 *    ('%' and '{' are included for preparse() DBIpp_ph_sp / DBIpp_cm_br safety.)
 *    Never reads outside [s, end).
 * ============================================================================ */

static inline int
dbi_is_sql_delim_byte(unsigned char c)
{
    switch (c) {
    case '\0':
    case '\n':
    case '\r':
    case '"':
    case '#':
    case '%':
    case '\'':
    case '-':
    case '/':
    case ':':
    case '?':
    case '{':
        return 1;
    default:
        return 0;
    }
}

static inline const char *
dbi_scan_sql_plain_scalar(const char *s, const char *end)
{
    while (s < end && !dbi_is_sql_delim_byte((unsigned char)*s))
        s++;
    return s;
}

#if defined(DBI_SIMD_HAVE_SSE2)
static inline const char *
dbi_scan_sql_plain_sse2(const char *s, const char *end)
{
    const __m128i c_nul = _mm_set1_epi8('\0');
    const __m128i c_nl  = _mm_set1_epi8('\n');
    const __m128i c_cr  = _mm_set1_epi8('\r');
    const __m128i c_dq  = _mm_set1_epi8('"');
    const __m128i c_hs  = _mm_set1_epi8('#');
    const __m128i c_pc  = _mm_set1_epi8('%');
    const __m128i c_sq  = _mm_set1_epi8('\'');
    const __m128i c_hy  = _mm_set1_epi8('-');
    const __m128i c_sl  = _mm_set1_epi8('/');
    const __m128i c_co  = _mm_set1_epi8(':');
    const __m128i c_qm  = _mm_set1_epi8('?');
    const __m128i c_lb  = _mm_set1_epi8('{');

    while ((size_t)(end - s) >= 16) {
        __m128i v = _mm_loadu_si128((const __m128i *)s);
        __m128i m = _mm_or_si128(
            _mm_or_si128(
                _mm_or_si128(_mm_cmpeq_epi8(v, c_nul), _mm_cmpeq_epi8(v, c_nl)),
                _mm_or_si128(_mm_cmpeq_epi8(v, c_cr),  _mm_cmpeq_epi8(v, c_dq))),
            _mm_or_si128(
                _mm_or_si128(
                    _mm_or_si128(_mm_cmpeq_epi8(v, c_hs), _mm_cmpeq_epi8(v, c_pc)),
                    _mm_or_si128(_mm_cmpeq_epi8(v, c_sq), _mm_cmpeq_epi8(v, c_hy))),
                _mm_or_si128(
                    _mm_or_si128(_mm_cmpeq_epi8(v, c_sl), _mm_cmpeq_epi8(v, c_co)),
                    _mm_or_si128(_mm_cmpeq_epi8(v, c_qm), _mm_cmpeq_epi8(v, c_lb)))));
        uint32_t mask = (uint32_t)_mm_movemask_epi8(m);
        if (mask != 0)
            return s + __builtin_ctz(mask);
        s += 16;
    }
    return dbi_scan_sql_plain_scalar(s, end);
}

# if defined(DBI_SIMD_HAVE_AVX2_RUNTIME)
__attribute__((target("avx2")))
static inline const char *
dbi_scan_sql_plain_avx2(const char *s, const char *end)
{
    const __m256i c_nul = _mm256_set1_epi8('\0');
    const __m256i c_nl  = _mm256_set1_epi8('\n');
    const __m256i c_cr  = _mm256_set1_epi8('\r');
    const __m256i c_dq  = _mm256_set1_epi8('"');
    const __m256i c_hs  = _mm256_set1_epi8('#');
    const __m256i c_pc  = _mm256_set1_epi8('%');
    const __m256i c_sq  = _mm256_set1_epi8('\'');
    const __m256i c_hy  = _mm256_set1_epi8('-');
    const __m256i c_sl  = _mm256_set1_epi8('/');
    const __m256i c_co  = _mm256_set1_epi8(':');
    const __m256i c_qm  = _mm256_set1_epi8('?');
    const __m256i c_lb  = _mm256_set1_epi8('{');

    while ((size_t)(end - s) >= 32) {
        __m256i v = _mm256_loadu_si256((const __m256i *)s);
        __m256i m = _mm256_or_si256(
            _mm256_or_si256(
                _mm256_or_si256(_mm256_cmpeq_epi8(v, c_nul), _mm256_cmpeq_epi8(v, c_nl)),
                _mm256_or_si256(_mm256_cmpeq_epi8(v, c_cr),  _mm256_cmpeq_epi8(v, c_dq))),
            _mm256_or_si256(
                _mm256_or_si256(
                    _mm256_or_si256(_mm256_cmpeq_epi8(v, c_hs), _mm256_cmpeq_epi8(v, c_pc)),
                    _mm256_or_si256(_mm256_cmpeq_epi8(v, c_sq), _mm256_cmpeq_epi8(v, c_hy))),
                _mm256_or_si256(
                    _mm256_or_si256(_mm256_cmpeq_epi8(v, c_sl), _mm256_cmpeq_epi8(v, c_co)),
                    _mm256_or_si256(_mm256_cmpeq_epi8(v, c_qm), _mm256_cmpeq_epi8(v, c_lb)))));
        uint32_t mask = (uint32_t)_mm256_movemask_epi8(m);
        if (mask != 0)
            return s + __builtin_ctz(mask);
        s += 32;
    }
    return dbi_scan_sql_plain_sse2(s, end);
}
# endif /* DBI_SIMD_HAVE_AVX2_RUNTIME */

#elif defined(DBI_SIMD_HAVE_NEON)
static inline const char *
dbi_scan_sql_plain_neon(const char *s, const char *end)
{
    const uint8x16_t c_nul = vdupq_n_u8((uint8_t)'\0');
    const uint8x16_t c_nl  = vdupq_n_u8((uint8_t)'\n');
    const uint8x16_t c_cr  = vdupq_n_u8((uint8_t)'\r');
    const uint8x16_t c_dq  = vdupq_n_u8((uint8_t)'"');
    const uint8x16_t c_hs  = vdupq_n_u8((uint8_t)'#');
    const uint8x16_t c_pc  = vdupq_n_u8((uint8_t)'%');
    const uint8x16_t c_sq  = vdupq_n_u8((uint8_t)'\'');
    const uint8x16_t c_hy  = vdupq_n_u8((uint8_t)'-');
    const uint8x16_t c_sl  = vdupq_n_u8((uint8_t)'/');
    const uint8x16_t c_co  = vdupq_n_u8((uint8_t)':');
    const uint8x16_t c_qm  = vdupq_n_u8((uint8_t)'?');
    const uint8x16_t c_lb  = vdupq_n_u8((uint8_t)'{');

    while ((size_t)(end - s) >= 16) {
        uint8x16_t v = vld1q_u8((const uint8_t *)s);
        uint8x16_t m = vorrq_u8(
            vorrq_u8(
                vorrq_u8(vceqq_u8(v, c_nul), vceqq_u8(v, c_nl)),
                vorrq_u8(vceqq_u8(v, c_cr),  vceqq_u8(v, c_dq))),
            vorrq_u8(
                vorrq_u8(
                    vorrq_u8(vceqq_u8(v, c_hs), vceqq_u8(v, c_pc)),
                    vorrq_u8(vceqq_u8(v, c_sq), vceqq_u8(v, c_hy))),
                vorrq_u8(
                    vorrq_u8(vceqq_u8(v, c_sl), vceqq_u8(v, c_co)),
                    vorrq_u8(vceqq_u8(v, c_qm), vceqq_u8(v, c_lb)))));
        if (vmaxvq_u8(m) != 0)
            break;
        s += 16;
    }
    return dbi_scan_sql_plain_scalar(s, end);
}

#elif defined(DBI_SIMD_HAVE_POWER_VEC)
static inline const char *
dbi_scan_sql_plain_power(const char *s, const char *end)
{
    const __vector unsigned char z0    = { 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0 };
    const __vector unsigned char c_nl  = { '\n','\n','\n','\n','\n','\n','\n','\n','\n','\n','\n','\n','\n','\n','\n','\n' };
    const __vector unsigned char c_cr  = { '\r','\r','\r','\r','\r','\r','\r','\r','\r','\r','\r','\r','\r','\r','\r','\r' };
    const __vector unsigned char c_dq  = { '"','"','"','"','"','"','"','"','"','"','"','"','"','"','"','"' };
    const __vector unsigned char c_hs  = { '#','#','#','#','#','#','#','#','#','#','#','#','#','#','#','#' };
    const __vector unsigned char c_pc  = { '%','%','%','%','%','%','%','%','%','%','%','%','%','%','%','%' };
    const __vector unsigned char c_sq  = { '\'','\'','\'','\'','\'','\'','\'','\'','\'','\'','\'','\'','\'','\'','\'','\'' };
    const __vector unsigned char c_hy  = { '-','-','-','-','-','-','-','-','-','-','-','-','-','-','-','-' };
    const __vector unsigned char c_sl  = { '/','/','/','/','/','/','/','/','/','/','/','/','/','/','/','/' };
    const __vector unsigned char c_co  = { ':',':',':',':',':',':',':',':',':',':',':',':',':',':',':',':' };
    const __vector unsigned char c_qm  = { '?','?','?','?','?','?','?','?','?','?','?','?','?','?','?','?' };
    const __vector unsigned char c_lb  = { '{','{','{','{','{','{','{','{','{','{','{','{','{','{','{','{' };

    while ((size_t)(end - s) >= 16) {
        __vector unsigned char v;
        __vector __bool char m;
        dbi_arch_memcpy(&v, s, 16);
        m = vec_cmpeq(v, z0)   | vec_cmpeq(v, c_nl) | vec_cmpeq(v, c_cr) | vec_cmpeq(v, c_dq)
          | vec_cmpeq(v, c_hs) | vec_cmpeq(v, c_pc) | vec_cmpeq(v, c_sq) | vec_cmpeq(v, c_hy)
          | vec_cmpeq(v, c_sl) | vec_cmpeq(v, c_co) | vec_cmpeq(v, c_qm) | vec_cmpeq(v, c_lb);
        if (!vec_all_eq(m, (__vector __bool char)z0))
            break;
        s += 16;
    }
    return dbi_scan_sql_plain_scalar(s, end);
}

#elif defined(DBI_SIMD_HAVE_S390X_VX)
static inline const char *
dbi_scan_sql_plain_s390x(const char *s, const char *end)
{
    const __vector unsigned char z0    = { 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0 };
    const __vector unsigned char c_nl  = { '\n','\n','\n','\n','\n','\n','\n','\n','\n','\n','\n','\n','\n','\n','\n','\n' };
    const __vector unsigned char c_cr  = { '\r','\r','\r','\r','\r','\r','\r','\r','\r','\r','\r','\r','\r','\r','\r','\r' };
    const __vector unsigned char c_dq  = { '"','"','"','"','"','"','"','"','"','"','"','"','"','"','"','"' };
    const __vector unsigned char c_hs  = { '#','#','#','#','#','#','#','#','#','#','#','#','#','#','#','#' };
    const __vector unsigned char c_pc  = { '%','%','%','%','%','%','%','%','%','%','%','%','%','%','%','%' };
    const __vector unsigned char c_sq  = { '\'','\'','\'','\'','\'','\'','\'','\'','\'','\'','\'','\'','\'','\'','\'','\'' };
    const __vector unsigned char c_hy  = { '-','-','-','-','-','-','-','-','-','-','-','-','-','-','-','-' };
    const __vector unsigned char c_sl  = { '/','/','/','/','/','/','/','/','/','/','/','/','/','/','/','/' };
    const __vector unsigned char c_co  = { ':',':',':',':',':',':',':',':',':',':',':',':',':',':',':',':' };
    const __vector unsigned char c_qm  = { '?','?','?','?','?','?','?','?','?','?','?','?','?','?','?','?' };
    const __vector unsigned char c_lb  = { '{','{','{','{','{','{','{','{','{','{','{','{','{','{','{','{' };

    while ((size_t)(end - s) >= 16) {
        __vector unsigned char v;
        __vector __bool char m;
        dbi_arch_memcpy(&v, s, 16);
        m = vec_cmpeq(v, z0)   | vec_cmpeq(v, c_nl) | vec_cmpeq(v, c_cr) | vec_cmpeq(v, c_dq)
          | vec_cmpeq(v, c_hs) | vec_cmpeq(v, c_pc) | vec_cmpeq(v, c_sq) | vec_cmpeq(v, c_hy)
          | vec_cmpeq(v, c_sl) | vec_cmpeq(v, c_co) | vec_cmpeq(v, c_qm) | vec_cmpeq(v, c_lb);
        if (!vec_all_eq(m, (__vector __bool char)z0))
            break;
        s += 16;
    }
    return dbi_scan_sql_plain_scalar(s, end);
}
#endif

static inline const char *
dbi_scan_sql_plain(const char *s, const char *end, int force_scalar)
{
    if (s >= end)
        return s;
    if (DBI_SIMD_COMPILE_DISABLED || force_scalar || (size_t)(end - s) < 16)
        return dbi_scan_sql_plain_scalar(s, end);
#if defined(DBI_SIMD_HAVE_AVX2_RUNTIME)
    if ((size_t)(end - s) >= 32 && dbi_arch_cpu_has_avx2())
        return dbi_scan_sql_plain_avx2(s, end);
    return dbi_scan_sql_plain_sse2(s, end);
#elif defined(DBI_SIMD_HAVE_SSE2)
    return dbi_scan_sql_plain_sse2(s, end);
#elif defined(DBI_SIMD_HAVE_NEON)
    return dbi_scan_sql_plain_neon(s, end);
#elif defined(DBI_SIMD_HAVE_POWER_VEC)
    return dbi_scan_sql_plain_power(s, end);
#elif defined(DBI_SIMD_HAVE_S390X_VX)
    return dbi_scan_sql_plain_s390x(s, end);
#else
    return dbi_scan_sql_plain_scalar(s, end);
#endif
}

/* ============================================================================
 * 6. Kernel C: dbi_scan_nonprint_or_quote
 *    Forward scan for the first byte matching:
 *      c < 0x20 || c >= 0x7f || c == '\'' || c == '\\'
 *    Returns index in [0, len], or len if no matching byte is present.
 *    Never reads outside [s, s + len).
 * ============================================================================ */

static inline int
dbi_is_nonprint_or_quote_byte(unsigned char c)
{
    return (c < 0x20 || c >= 0x7f || c == '\'' || c == '\\');
}

static inline STRLEN
dbi_scan_nonprint_or_quote_scalar(const char *s, STRLEN len)
{
    STRLEN i = 0;
    while (i < len && !dbi_is_nonprint_or_quote_byte((unsigned char)s[i]))
        i++;
    return i;
}

#if defined(DBI_SIMD_HAVE_SSE2)
static inline STRLEN
dbi_scan_nonprint_or_quote_sse2(const char *s, STRLEN len)
{
    /* In signed int8: bytes 0x00..0x1f (0..31) and 0x80..0xff (-128..-1)
     * are all strictly less than 0x20 (32). Only 0x7f (127) needs eq check. */
    const __m128i c_20 = _mm_set1_epi8(0x20);
    const __m128i c_7f = _mm_set1_epi8(0x7f);
    const __m128i c_sq = _mm_set1_epi8('\'');
    const __m128i c_bs = _mm_set1_epi8('\\');
    STRLEN i = 0;

    while (i + 16 <= len) {
        __m128i v = _mm_loadu_si128((const __m128i *)(s + i));
        __m128i m = _mm_or_si128(
            _mm_or_si128(_mm_cmpgt_epi8(c_20, v), _mm_cmpeq_epi8(v, c_7f)),
            _mm_or_si128(_mm_cmpeq_epi8(v, c_sq), _mm_cmpeq_epi8(v, c_bs)));
        uint32_t mask = (uint32_t)_mm_movemask_epi8(m);
        if (mask != 0)
            return i + (STRLEN)__builtin_ctz(mask);
        i += 16;
    }
    return i + dbi_scan_nonprint_or_quote_scalar(s + i, len - i);
}

# if defined(DBI_SIMD_HAVE_AVX2_RUNTIME)
__attribute__((target("avx2")))
static inline STRLEN
dbi_scan_nonprint_or_quote_avx2(const char *s, STRLEN len)
{
    const __m256i c_20 = _mm256_set1_epi8(0x20);
    const __m256i c_7f = _mm256_set1_epi8(0x7f);
    const __m256i c_sq = _mm256_set1_epi8('\'');
    const __m256i c_bs = _mm256_set1_epi8('\\');
    STRLEN i = 0;

    while (i + 32 <= len) {
        __m256i v = _mm256_loadu_si256((const __m256i *)(s + i));
        __m256i m = _mm256_or_si256(
            _mm256_or_si256(_mm256_cmpgt_epi8(c_20, v), _mm256_cmpeq_epi8(v, c_7f)),
            _mm256_or_si256(_mm256_cmpeq_epi8(v, c_sq), _mm256_cmpeq_epi8(v, c_bs)));
        uint32_t mask = (uint32_t)_mm256_movemask_epi8(m);
        if (mask != 0)
            return i + (STRLEN)__builtin_ctz(mask);
        i += 32;
    }
    return i + dbi_scan_nonprint_or_quote_sse2(s + i, len - i);
}
# endif /* DBI_SIMD_HAVE_AVX2_RUNTIME */

#elif defined(DBI_SIMD_HAVE_NEON)
static inline STRLEN
dbi_scan_nonprint_or_quote_neon(const char *s, STRLEN len)
{
    const uint8x16_t c_20 = vdupq_n_u8(0x20u);
    const uint8x16_t c_7f = vdupq_n_u8(0x7fu);
    const uint8x16_t c_sq = vdupq_n_u8((uint8_t)'\'');
    const uint8x16_t c_bs = vdupq_n_u8((uint8_t)'\\');
    STRLEN i = 0;

    while (i + 16 <= len) {
        uint8x16_t v = vld1q_u8((const uint8_t *)(s + i));
        uint8x16_t m = vorrq_u8(
            vorrq_u8(vcltq_u8(v, c_20), vcgeq_u8(v, c_7f)),
            vorrq_u8(vceqq_u8(v, c_sq), vceqq_u8(v, c_bs)));
        if (vmaxvq_u8(m) != 0)
            break;
        i += 16;
    }
    return i + dbi_scan_nonprint_or_quote_scalar(s + i, len - i);
}

#elif defined(DBI_SIMD_HAVE_POWER_VEC)
static inline STRLEN
dbi_scan_nonprint_or_quote_power(const char *s, STRLEN len)
{
    const __vector unsigned char z0   = { 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0 };
    const __vector unsigned char c_20 = { 0x20,0x20,0x20,0x20,0x20,0x20,0x20,0x20,0x20,0x20,0x20,0x20,0x20,0x20,0x20,0x20 };
    const __vector unsigned char c_7f = { 0x7f,0x7f,0x7f,0x7f,0x7f,0x7f,0x7f,0x7f,0x7f,0x7f,0x7f,0x7f,0x7f,0x7f,0x7f,0x7f };
    const __vector unsigned char c_sq = { '\'','\'','\'','\'','\'','\'','\'','\'','\'','\'','\'','\'','\'','\'','\'','\'' };
    const __vector unsigned char c_bs = { '\\','\\','\\','\\','\\','\\','\\','\\','\\','\\','\\','\\','\\','\\','\\','\\' };
    STRLEN i = 0;

    while (i + 16 <= len) {
        __vector unsigned char v;
        __vector __bool char m;
        dbi_arch_memcpy(&v, s + i, 16);
        m = vec_cmplt(v, c_20) | vec_cmpge(v, c_7f)
          | vec_cmpeq(v, c_sq) | vec_cmpeq(v, c_bs);
        if (!vec_all_eq(m, (__vector __bool char)z0))
            break;
        i += 16;
    }
    return i + dbi_scan_nonprint_or_quote_scalar(s + i, len - i);
}

#elif defined(DBI_SIMD_HAVE_S390X_VX)
static inline STRLEN
dbi_scan_nonprint_or_quote_s390x(const char *s, STRLEN len)
{
    const __vector unsigned char z0   = { 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0 };
    const __vector unsigned char c_20 = { 0x20,0x20,0x20,0x20,0x20,0x20,0x20,0x20,0x20,0x20,0x20,0x20,0x20,0x20,0x20,0x20 };
    const __vector unsigned char c_7f = { 0x7f,0x7f,0x7f,0x7f,0x7f,0x7f,0x7f,0x7f,0x7f,0x7f,0x7f,0x7f,0x7f,0x7f,0x7f,0x7f };
    const __vector unsigned char c_sq = { '\'','\'','\'','\'','\'','\'','\'','\'','\'','\'','\'','\'','\'','\'','\'','\'' };
    const __vector unsigned char c_bs = { '\\','\\','\\','\\','\\','\\','\\','\\','\\','\\','\\','\\','\\','\\','\\','\\' };
    STRLEN i = 0;

    while (i + 16 <= len) {
        __vector unsigned char v;
        __vector __bool char m;
        dbi_arch_memcpy(&v, s + i, 16);
        m = vec_cmplt(v, c_20) | vec_cmpge(v, c_7f)
          | vec_cmpeq(v, c_sq) | vec_cmpeq(v, c_bs);
        if (!vec_all_eq(m, (__vector __bool char)z0))
            break;
        i += 16;
    }
    return i + dbi_scan_nonprint_or_quote_scalar(s + i, len - i);
}
#endif

static inline STRLEN
dbi_scan_nonprint_or_quote(const char *s, STRLEN len, int force_scalar)
{
    if (DBI_SIMD_COMPILE_DISABLED || force_scalar || len < 16)
        return dbi_scan_nonprint_or_quote_scalar(s, len);
#if defined(DBI_SIMD_HAVE_AVX2_RUNTIME)
    if (len >= 32 && dbi_arch_cpu_has_avx2())
        return dbi_scan_nonprint_or_quote_avx2(s, len);
    return dbi_scan_nonprint_or_quote_sse2(s, len);
#elif defined(DBI_SIMD_HAVE_SSE2)
    return dbi_scan_nonprint_or_quote_sse2(s, len);
#elif defined(DBI_SIMD_HAVE_NEON)
    return dbi_scan_nonprint_or_quote_neon(s, len);
#elif defined(DBI_SIMD_HAVE_POWER_VEC)
    return dbi_scan_nonprint_or_quote_power(s, len);
#elif defined(DBI_SIMD_HAVE_S390X_VX)
    return dbi_scan_nonprint_or_quote_s390x(s, len);
#else
    return dbi_scan_nonprint_or_quote_scalar(s, len);
#endif
}

#endif /* DBI_ARCH_H */
