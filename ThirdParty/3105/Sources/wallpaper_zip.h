#ifndef WALLPAPER_ZIP_H
#define WALLPAPER_ZIP_H

#include <stdint.h>

int wallpaper_zip_extract_entry(
    const char *archive_path,
    uint64_t data_offset,
    uint64_t compressed_size,
    uint16_t compression_method,
    const char *destination_path,
    uint64_t expected_size,
    uint32_t expected_crc32
);

#endif
