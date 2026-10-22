/* Minimal zstd decompressor for BlueFish.
 *
 * Reads concatenated zstd frames from stdin (or the first non-flag file
 * argument) and writes the decompressed bytes to stdout. This lets the app
 * stay self-contained and avoids depending on a Homebrew zstd install.
 *
 *   clang -O2 -I/opt/homebrew/opt/zstd/include zstd_helper.c \
 *         /opt/homebrew/opt/zstd/lib/libzstd.a -o zstd-helper
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <zstd.h>

int main(int argc, char **argv) {
    const char *path = NULL;
    for (int i = 1; i < argc; i++) {
        if (argv[i][0] != '-') {
            path = argv[i];
            break;
        }
    }

    FILE *in = stdin;
    if (path) {
        in = fopen(path, "rb");
        if (!in) return 1;
    }

    ZSTD_DStream *ds = ZSTD_createDStream();
    if (!ds) return 2;
    ZSTD_initDStream(ds);

    size_t inCap = ZSTD_DStreamInSize();
    size_t outCap = ZSTD_DStreamOutSize();
    void *inBuf = malloc(inCap);
    void *outBuf = malloc(outCap);
    if (!inBuf || !outBuf) return 2;

    for (;;) {
        size_t n = fread(inBuf, 1, inCap, in);
        ZSTD_inBuffer input = { inBuf, n, 0 };
        while (input.pos < input.size) {
            ZSTD_outBuffer output = { outBuf, outCap, 0 };
            size_t ret = ZSTD_decompressStream(ds, &output, &input);
            if (ZSTD_isError(ret)) {
                /* A partially written final frame: keep what we decoded. */
                goto done;
            }
            if (output.pos) {
                fwrite(outBuf, 1, output.pos, stdout);
            }
            if (ret == 0 && input.pos == input.size) {
                /* Frame finished exactly at the end of this chunk. */
            }
        }
        if (n < inCap) break;
    }

done:
    fflush(stdout);
    ZSTD_freeDStream(ds);
    free(inBuf);
    free(outBuf);
    if (path) fclose(in);
    return 0;
}
