/* stb_truetype is header-only, and @cImport cannot host the implementation
   (it generates declarations, not a translation unit). So the implementation
   define lives here and this file is added via addCSourceFile. */
#define STB_TRUETYPE_IMPLEMENTATION
#include "stb_truetype.h"
