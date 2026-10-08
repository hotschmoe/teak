// stb_truetype implementation for wasm32-freestanding (no libc, no headers
// beyond the compiler's own). Allocation and the libm calls stb cannot get from
// compiler builtins are provided by stb_wasm_shim.zig.
#include <stddef.h>

extern void *teak_stb_malloc(size_t n);
extern void teak_stb_free(void *p);
extern double teak_stb_pow(double, double);
extern double teak_stb_fmod(double, double);
extern double teak_stb_cos(double);
extern double teak_stb_acos(double);

static inline int teak_ifloor(double x) {
    int i = (int)x;
    return (double)i > x ? i - 1 : i;
}
static inline int teak_iceil(double x) {
    int i = (int)x;
    return (double)i < x ? i + 1 : i;
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
#define STBTT_pow(x, y) teak_stb_pow(x, y)
#define STBTT_fmod(x, y) teak_stb_fmod(x, y)
#define STBTT_cos(x) teak_stb_cos(x)
#define STBTT_acos(x) teak_stb_acos(x)
#define STBTT_strlen(x) teak_strlen(x)
#define STBTT_memcpy(d, s, n) __builtin_memcpy(d, s, n)
#define STBTT_memset(d, v, n) __builtin_memset(d, v, n)

#define STB_TRUETYPE_IMPLEMENTATION
#include "stb_truetype.h"
