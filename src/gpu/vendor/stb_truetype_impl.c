// Single translation unit that instantiates stb_truetype's implementation.
// The Zig side (`src/text/`) @cIncludes the header for declarations
// only; this file provides the definitions, linked once into the exe.
//
// stb_truetype's default STBTT_malloc/STBTT_free route to libc malloc/free
// (<stdlib.h>), so the consuming target must link libc — handled by
// `linkLinux` in build.zig (link_libc = true).
// No libc assert: mingw's `_assert` import carries a NAME_EXPORTAS entry that
// Zig's self-hosted COFF linker (`-fno-llvm`, the fast Debug loop on
// Windows) cannot read yet. stb's asserts are internal sanity checks.
#define STBTT_assert(x) ((void)0)
#define STB_TRUETYPE_IMPLEMENTATION
#include "stb_truetype.h"
