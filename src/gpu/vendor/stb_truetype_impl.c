// Single translation unit that instantiates stb_truetype's implementation.
// The Zig side (`text_stbtt.zig`) @cIncludes the header for declarations
// only; this file provides the definitions, linked once into the exe.
//
// stb_truetype's default STBTT_malloc/STBTT_free route to libc malloc/free
// (<stdlib.h>), so the consuming target must link libc — handled by
// `linkLinux` in build.zig (link_libc = true).
#define STB_TRUETYPE_IMPLEMENTATION
#include "stb_truetype.h"
