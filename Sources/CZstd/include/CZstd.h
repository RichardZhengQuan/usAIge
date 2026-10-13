#ifndef USAIGE_CZSTD_H
#define USAIGE_CZSTD_H

#include <stddef.h>

// Decode exactly one ordinary, dictionary-free Zstandard frame. Returns 1 on
// success and sets output_size; returns 0 for invalid input or exceeded limits.
// Output capacity is at most 1 MiB; the frame window is at most 8 MiB.
int usaige_zstd_decode(const void *source, size_t source_size,
                       void *output, size_t output_capacity, size_t *output_size);

#endif
