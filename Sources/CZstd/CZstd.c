#include "include/CZstd.h"

// The official decompression-only amalgamation is included once in this
// translation unit. Its upstream source and BSD notices are unmodified.
#include "vendor/zstddeclib.inc"

int usaige_zstd_decode(const void *source, size_t source_size,
                       void *output, size_t output_capacity, size_t *output_size)
{
    const unsigned char *bytes = (const unsigned char *)source;
    ZSTD_FrameHeader header;
    size_t header_status, frame_size, decoded_size;

    if (!source || !output || !output_size || source_size < 4 ||
        source_size > 2 * 1024 * 1024 || output_capacity == 0 ||
        output_capacity > 1024 * 1024) return 0;
    *output_size = 0;

    // Skippable frames are not usage responses, and concatenated frames or
    // trailing bytes must not turn a damaged cache entry into accepted data.
    if (bytes[0] != 0x28 || bytes[1] != 0xB5 ||
        bytes[2] != 0x2F || bytes[3] != 0xFD) return 0;
    header_status = ZSTD_getFrameHeader(&header, source, source_size);
    if (ZSTD_isError(header_status) || header_status != 0 ||
        header.frameType != ZSTD_frame || header.dictID != 0 ||
        header.windowSize > 8 * 1024 * 1024 ||
        (header.frameContentSize != ZSTD_CONTENTSIZE_UNKNOWN &&
         header.frameContentSize > output_capacity)) return 0;
    frame_size = ZSTD_findFrameCompressedSize(source, source_size);
    if (ZSTD_isError(frame_size) || frame_size != source_size) return 0;

    // The one-pass decoder writes only to the fixed caller buffer and does
    // not allocate a frame-sized history window. Its checksum validation and
    // output-capacity checks also apply when the content size is unspecified.
    decoded_size = ZSTD_decompress(output, output_capacity, source, source_size);
    if (ZSTD_isError(decoded_size) || decoded_size > output_capacity) return 0;
    *output_size = decoded_size;
    return 1;
}
