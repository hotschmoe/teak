// stb_truetype implementation for wasm32-freestanding (no libc, no headers
// beyond the compiler's own). Allocation is provided by stb_wasm_shim.zig.
#include <stddef.h>

extern void *teak_stb_malloc(size_t n);
extern void teak_stb_free(void *p);

static inline int teak_ifloor(double x) {
    int i = (int)x;
    return (double)i > x ? i - 1 : i;
}
static inline int teak_iceil(double x) {
    int i = (int)x;
    return (double)i < x ? i + 1 : i;
}
// pow/cos/acos are only reached from stb's SDF rasterizer and cubic solver,
// which teak never calls; trapping keeps the libm (compiler_rt rem_pio2, ~7 KB
// gzip) out of the wasm. fmod is the fractional part of a y offset.
static inline double teak_unreachable(void) { __builtin_trap(); }
static inline double teak_fmod(double x, double y) { return x - (double)(long long)(x / y) * y; }
static inline size_t teak_strlen(const char *s) {
    size_t n = 0;
    while (s[n]) n++;
    return n;
}

#define STBTT_malloc(x, u) ((void)(u), teak_stb_malloc(x))
#define STBTT_free(x, u) ((void)(u), teak_stb_free(x))
#define STBTT_assert(x) ((void)0)
#define STBTT_ifloor(x) teak_ifloor(x)
#define STBTT_iceil(x) teak_iceil(x)
#define STBTT_sqrt(x) __builtin_sqrt(x)
#define STBTT_fabs(x) __builtin_fabs(x)
#define STBTT_pow(x, y) (teak_unreachable())
#define STBTT_fmod(x, y) teak_fmod(x, y)
#define STBTT_cos(x) (teak_unreachable())
#define STBTT_acos(x) (teak_unreachable())
#define STBTT_strlen(x) teak_strlen(x)
#define STBTT_memcpy(d, s, n) __builtin_memcpy(d, s, n)
#define STBTT_memset(d, v, n) __builtin_memset(d, v, n)

#define STB_TRUETYPE_IMPLEMENTATION
#include "stb_truetype.h"
