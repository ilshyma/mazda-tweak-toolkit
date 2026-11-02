#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <sys/stat.h>
#include "log.h"
#include "usb.h"

void tweaksd_log(const char *op, const char *tweak_id, const char *detail) {
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

    char lines[512][256];
    int total = 0;
    while (total < 512 && fgets(lines[total % 512], sizeof(lines[0]), f))
        total++;
    fclose(f);

    int start = total > last_n ? total - last_n : 0;
    int count = total - start;

    int pos = snprintf(out, outlen, "{\"log\":[");
    for (int i = start; i < total && pos < outlen - 300; i++) {
        lines[i % 512][strcspn(lines[i % 512], "\n\r")] = '\0';
        char esc[512];
        int ej = 0;
        for (int c = 0; lines[i % 512][c] && ej < (int)sizeof(esc) - 2; c++) {
            if (lines[i % 512][c] == '"' || lines[i % 512][c] == '\\')
                esc[ej++] = '\\';
            esc[ej++] = lines[i % 512][c];
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
