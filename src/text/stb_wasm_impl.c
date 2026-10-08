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
// stb reaches pow/cos/acos only from its distance-field rasterizer (the cubic solver of
// stbtt_GetGlyphSDF): pow(x, 1/3), cos / acos on small angles. Small polynomial/Newton
// versions keep the libm (compiler_rt rem_pio2, ~7 KB gzip) out of the wasm.
static inline double teak_fmod(double x, double y) { return x - (double)(long long)(x / y) * y; }
static double teak_pow(double x, double y) {
    (void)y; // only ever 1/3
    if (x == 0) return 0;
    double a = x < 0 ? -x : x;
    double r = a > 1 ? a / 3 : 1;
    for (int i = 0; i < 40; i++) r = (2 * r + a / (r * r)) / 3;
    return x < 0 ? -r : r;
}
static double teak_cos(double x) { // |x| <= ~pi/2 here
    double x2 = x * x;
    return 1 - x2 * (0.5 - x2 * (1.0 / 24 - x2 * (1.0 / 720 - x2 * (1.0 / 40320 - x2 * (1.0 / 3628800 - x2 / 479001600)))));
}
static double teak_acos(double x) { // Abramowitz-Stegun 4.4.46, |error| < 2e-8
    double a = x < 0 ? -x : x;
    double p = 1.5707963050 + a * (-0.2145988016 + a * (0.0889789874 + a * (-0.0501743046 + a * (0.0308918810 + a * (-0.0170881256 + a * (0.0066700901 + a * -0.0012624911))))));
    double r = __builtin_sqrt(1 - a) * p;
    return x < 0 ? 3.14159265358979323846 - r : r;
}
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
#define STBTT_pow(x, y) teak_pow(x, y)
#define STBTT_fmod(x, y) teak_fmod(x, y)
#define STBTT_cos(x) teak_cos(x)
#define STBTT_acos(x) teak_acos(x)
#define STBTT_strlen(x) teak_strlen(x)
#define STBTT_memcpy(d, s, n) __builtin_memcpy(d, s, n)
#define STBTT_memset(d, v, n) __builtin_memset(d, v, n)

#define STB_TRUETYPE_IMPLEMENTATION
#include "stb_truetype.h"
