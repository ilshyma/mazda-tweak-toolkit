#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <sys/stat.h>
#include "log.h"
#include "usb.h"

static void log_rotate(void) {
    struct stat st;
    if (stat(LOG_FILE, &st) != 0 || st.st_size < LOG_MAX_SIZE)
        return;
    /* keep last ~256KB */
    FILE *f = fopen(LOG_FILE, "r");
    if (!f) return;
    long keep = 256 * 1024;
    fseek(f, st.st_size - keep, SEEK_SET);
    /* align to next newline */
    int c;
    while ((c = fgetc(f)) != EOF && c != '\n') {}
    long start = ftell(f);
    long len = st.st_size - start;
    char *buf = malloc(len + 1);
    if (!buf) { fclose(f); return; }
    long n = fread(buf, 1, len, f);
    fclose(f);
    f = fopen(LOG_FILE, "w");
    if (f) {
        fprintf(f, "[LOG] rotated (%ld -> %ld bytes)\n", (long)st.st_size, n);
        fwrite(buf, 1, n, f);
        fclose(f);
    }
    free(buf);
}

void tweaksd_log(const char *op, const char *tweak_id, const char *detail) {
    log_rotate();
    FILE *f = fopen(LOG_FILE, "a");
    if (!f) return;

    time_t now = time(NULL);
    struct tm *tm = localtime(&now);
    char ts[32];
    strftime(ts, sizeof(ts), "%Y-%m-%d %H:%M:%S", tm);

    fprintf(f, "[%s] %s %s %s\n", ts, op, tweak_id ? tweak_id : "-", detail ? detail : "");
    fclose(f);
}

void tweaksd_log_output(const char *op, const char *tweak_id, const char *output) {
    if (!output || !output[0]) return;
    FILE *f = fopen(LOG_FILE, "a");
    if (!f) return;

    time_t now = time(NULL);
    struct tm *tm = localtime(&now);
    char ts[32];
    strftime(ts, sizeof(ts), "%Y-%m-%d %H:%M:%S", tm);

    const char *p = output;
    while (*p) {
        const char *eol = strchr(p, '\n');
        int len = eol ? (int)(eol - p) : (int)strlen(p);
        if (len > 0)
            fprintf(f, "[%s] %s %s | %.*s\n", ts, op, tweak_id ? tweak_id : "-", len, p);
        p = eol ? eol + 1 : p + len;
    }
    fclose(f);
}

int tweaksd_log_read(char *out, int outlen, int last_n) {
    FILE *f = fopen(LOG_FILE, "r");
    if (!f) {
        snprintf(out, outlen, "{\"log\":[]}");
        return 0;
    }

    char lines[128][256];
    int total = 0;
    while (total < 128 && fgets(lines[total % 128], sizeof(lines[0]), f))
        total++;
    fclose(f);

    int start = total > last_n ? total - last_n : 0;
    int count = total - start;

    int pos = snprintf(out, outlen, "{\"log\":[");
    for (int i = start; i < total && pos < outlen - 300; i++) {
        lines[i % 128][strcspn(lines[i % 128], "\n\r")] = '\0';
        char esc[512];
        int ej = 0;
        for (int c = 0; lines[i % 128][c] && ej < (int)sizeof(esc) - 2; c++) {
            if (lines[i % 128][c] == '"' || lines[i % 128][c] == '\\')
                esc[ej++] = '\\';
            esc[ej++] = lines[i % 128][c];
        }
        esc[ej] = '\0';
        if (i > start) out[pos++] = ',';
        pos += snprintf(out + pos, outlen - pos, "\"%s\"", esc);
    }
    snprintf(out + pos, outlen - pos, "],\"total\":%d,\"shown\":%d}", total, count);
    return 0;
}

int tweaksd_log_export(const char *usb_base) {
    struct stat st;
    if (stat(LOG_FILE, &st) != 0) return -1;

    char dst[MAX_PATH];
    snprintf(dst, sizeof(dst), "%s/tweaks-logs", usb_base);
    mkdir(dst, 0755);

    time_t now = time(NULL);
    struct tm *tm = localtime(&now);
    char ts[32];
    strftime(ts, sizeof(ts), "%Y%m%d_%H%M%S", tm);

    char cmd[1024];
    snprintf(cmd, sizeof(cmd), "cp '%s' '%s/tweaksd_%s.log'", LOG_FILE, dst, ts);
    return system(cmd) == 0 ? 0 : -1;
}
