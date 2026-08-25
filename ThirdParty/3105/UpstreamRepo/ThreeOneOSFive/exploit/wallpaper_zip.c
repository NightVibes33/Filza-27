#include "wallpaper_zip.h"

#include <errno.h>
#include <fcntl.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <zlib.h>

#define WALLPAPER_ZIP_CHUNK (64 * 1024)

static int write_all(int descriptor, const unsigned char *bytes, size_t count) {
    size_t written = 0;
    while (written < count) {
        ssize_t result = write(descriptor, bytes + written, count - written);
        if (result < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (result == 0) return -1;
        written += (size_t)result;
    }
    return 0;
}

static ssize_t read_at(int descriptor, void *buffer, size_t count, uint64_t offset) {
    for (;;) {
        ssize_t result = pread(descriptor, buffer, count, (off_t)offset);
        if (result < 0 && errno == EINTR) continue;
        return result;
    }
}

int wallpaper_zip_extract_entry(
    const char *archive_path,
    uint64_t data_offset,
    uint64_t compressed_size,
    uint16_t compression_method,
    const char *destination_path,
    uint64_t expected_size,
    uint32_t expected_crc32
) {
    if (!archive_path || !destination_path ||
        (compression_method != 0 && compression_method != 8)) return -1;

    int source = open(archive_path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (source < 0) return -2;
    int destination = open(
        destination_path,
        O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
        0600
    );
    if (destination < 0) {
        close(source);
        return -3;
    }

    int status = -4;
    uint64_t total_output = 0;
    uLong checksum = crc32(0L, Z_NULL, 0);
    unsigned char *input = malloc(WALLPAPER_ZIP_CHUNK);
    unsigned char *output = malloc(WALLPAPER_ZIP_CHUNK);
    if (!input || !output) goto cleanup;

    if (compression_method == 0) {
        if (compressed_size != expected_size) goto cleanup;
        uint64_t remaining = compressed_size;
        uint64_t cursor = data_offset;
        while (remaining > 0) {
            size_t requested = remaining > WALLPAPER_ZIP_CHUNK
                ? WALLPAPER_ZIP_CHUNK : (size_t)remaining;
            ssize_t count = read_at(source, input, requested, cursor);
            if (count <= 0 || (size_t)count != requested) goto cleanup;
            if (write_all(destination, input, requested) != 0) goto cleanup;
            checksum = crc32(checksum, input, (uInt)requested);
            total_output += requested;
            cursor += requested;
            remaining -= requested;
        }
    } else {
        z_stream stream;
        memset(&stream, 0, sizeof(stream));
        if (inflateInit2(&stream, -MAX_WBITS) != Z_OK) goto cleanup;

        uint64_t remaining = compressed_size;
        uint64_t cursor = data_offset;
        int inflate_status = Z_OK;
        while (inflate_status != Z_STREAM_END) {
            if (stream.avail_in == 0 && remaining > 0) {
                size_t requested = remaining > WALLPAPER_ZIP_CHUNK
                    ? WALLPAPER_ZIP_CHUNK : (size_t)remaining;
                ssize_t count = read_at(source, input, requested, cursor);
                if (count <= 0 || (size_t)count != requested) {
                    inflateEnd(&stream);
                    goto cleanup;
                }
                stream.next_in = input;
                stream.avail_in = (uInt)requested;
                cursor += requested;
                remaining -= requested;
            }

            stream.next_out = output;
            stream.avail_out = WALLPAPER_ZIP_CHUNK;
            inflate_status = inflate(&stream, Z_NO_FLUSH);
            if (inflate_status != Z_OK && inflate_status != Z_STREAM_END) {
                inflateEnd(&stream);
                goto cleanup;
            }
            size_t produced = WALLPAPER_ZIP_CHUNK - stream.avail_out;
            if (produced > 0) {
                if (total_output > expected_size ||
                    produced > expected_size - total_output ||
                    write_all(destination, output, produced) != 0) {
                    inflateEnd(&stream);
                    goto cleanup;
                }
                checksum = crc32(checksum, output, (uInt)produced);
                total_output += produced;
            }
            if (stream.avail_in == 0 && remaining == 0 &&
                inflate_status != Z_STREAM_END) {
                inflateEnd(&stream);
                goto cleanup;
            }
        }
        if (remaining != 0 || stream.avail_in != 0) {
            inflateEnd(&stream);
            goto cleanup;
        }
        inflateEnd(&stream);
    }

    if (total_output != expected_size || (uint32_t)checksum != expected_crc32) {
        goto cleanup;
    }
    if (fsync(destination) != 0) goto cleanup;
    status = 0;

cleanup:
    free(input);
    free(output);
    close(destination);
    close(source);
    if (status != 0) unlink(destination_path);
    return status;
}
