#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <unistd.h>
#include <sys/stat.h>
#include "httpd.h"
#include "tweaks.h"
#include "dump.h"
#include "usb.h"
#include "log.h"

#define PID_FILE    "/tmp/tweaksd.pid"
#ifndef VERSION
#define VERSION     "1.1.0"
#endif

static tweak_list_t current_list;

static void refresh_tweak_list(void) {
    memset(&current_list, 0, sizeof(current_list));
    tweaks_scan_installed(&current_list);

    /* merge locally available tweaks (copied from USB earlier) */
    tweak_list_t *avail = malloc(sizeof(tweak_list_t));
    if (avail) {
        memset(avail, 0, sizeof(*avail));
        tweaks_scan_available(avail);
        tweaks_merge_lists(&current_list, avail);
        free(avail);
    }

    /* merge USB tweaks (if USB is mounted) */
    char usb_dir[MAX_PATH];
    if (usb_find_tweaks_dir(usb_dir, sizeof(usb_dir)) == 0) {
        tweak_list_t *usb_list = malloc(sizeof(tweak_list_t));
        if (usb_list) {
            memset(usb_list, 0, sizeof(*usb_list));
            tweaks_scan_usb(usb_list, usb_dir);
            tweaks_merge_lists(&current_list, usb_list);
            free(usb_list);
        }
    }
}

/* ─── API handlers ─── */

static void handle_list(http_request_t *req) {
    refresh_tweak_list();
    char *json = malloc(16384);
    if (!json) { http_respond_error(req, 500, "out of memory"); return; }
    tweaks_list_to_json(&current_list, json, 16384);
    http_respond_json(req, 200, json);
    free(json);
}

static void handle_setup(http_request_t *req) {
    const char *id = req->path + strlen("/api/tweaks/setup/");
    if (!id[0]) {
        http_respond_error(req, 400, "missing tweak id");
        return;
    }
    refresh_tweak_list();
    char result[4096];
    tweaks_setup(id, &current_list, result, sizeof(result));
    int ok = strstr(result, "\"ok\":true") != NULL;
    tweaksd_log("SETUP", id, ok ? "OK" : "FAIL");
    http_respond_json(req, ok ? 200 : 500, result);
}

static void handle_install(http_request_t *req) {
    if (!dump_exists()) {
        http_respond_json(req, 403,
            "{\"ok\":false,\"error\":\"system dump required before installing tweaks\"}");
        return;
    }

    const char *id = req->path + strlen("/api/tweaks/install/");
    if (!id[0]) {
        http_respond_error(req, 400, "missing tweak id");
        return;
    }

    refresh_tweak_list();

    /* check conflicts first */
    char conflicts[2048];
    tweaks_check_conflicts(id, &current_list, conflicts, sizeof(conflicts));
    if (strstr(conflicts, "\"type\"")) {
        char resp[4096];
        snprintf(resp, sizeof(resp),
                 "{\"ok\":false,\"error\":\"conflicts detected\",\"details\":%s}",
                 conflicts);
        http_respond_json(req, 409, resp);
        return;
    }

    char result[4096];
    tweaks_install(id, &current_list, result, sizeof(result));
    int ok = strstr(result, "\"ok\":true") != NULL;
    tweaksd_log("INSTALL", id, ok ? "OK" : "FAIL");
    http_respond_json(req, ok ? 200 : 500, result);
}

static void handle_uninstall(http_request_t *req) {
    const char *id = req->path + strlen("/api/tweaks/uninstall/");
    if (!id[0]) {
        http_respond_error(req, 400, "missing tweak id");
        return;
    }
    char result[4096];
    tweaks_uninstall(id, result, sizeof(result));
    int ok = strstr(result, "\"ok\":true") != NULL;
    tweaksd_log("UNINSTALL", id, ok ? "OK" : "FAIL");
    http_respond_json(req, ok ? 200 : 500, result);
}

static void handle_update(http_request_t *req) {
    if (!dump_exists()) {
        http_respond_json(req, 403,
            "{\"ok\":false,\"error\":\"system dump required\"}");
        return;
    }
    const char *id = req->path + strlen("/api/tweaks/update/");
    if (!id[0]) {
        http_respond_error(req, 400, "missing tweak id");
        return;
    }
    refresh_tweak_list();
    char result[4096];
    tweaks_update(id, &current_list, result, sizeof(result));
    int ok = strstr(result, "\"ok\":true") != NULL;
    tweaksd_log("UPDATE", id, ok ? "OK" : "FAIL");
    http_respond_json(req, ok ? 200 : 500, result);
}

static void handle_status(http_request_t *req) {
    const char *id = req->path + strlen("/api/tweaks/status/");
    if (!id[0]) {
        http_respond_error(req, 400, "missing tweak id");
        return;
    }
    char result[2048];
    tweaks_check_status(id, result, sizeof(result));
    http_respond_json(req, 200, result);
}

static void handle_conflicts(http_request_t *req) {
    const char *id = req->path + strlen("/api/tweaks/conflicts/");
    if (!id[0]) {
        http_respond_error(req, 400, "missing tweak id");
        return;
    }
    refresh_tweak_list();
    char result[4096];
    tweaks_check_conflicts(id, &current_list, result, sizeof(result));
    http_respond_json(req, 200, result);
}

static void handle_dump_status(http_request_t *req) {
    char result[512];
    dump_get_status(result, sizeof(result));
    http_respond_json(req, 200, result);
}

static void handle_dump_create(http_request_t *req) {
    char usb_dir[MAX_PATH];
    if (usb_ensure_dump_dir(usb_dir, sizeof(usb_dir)) != 0) {
        http_respond_json(req, 503,
            "{\"ok\":false,\"error\":\"no USB drive found\"}");
        return;
    }

    if (dump_create(usb_dir) == 0) {
        tweaksd_log("DUMP", NULL, "created");
        http_respond_json(req, 200, "{\"ok\":true}");
    } else {
        tweaksd_log("DUMP", NULL, "FAIL");
        http_respond_json(req, 500,
            "{\"ok\":false,\"error\":\"dump creation failed\"}");
    }
}

static void handle_usb_scan(http_request_t *req) {
    usb_mounts_t mounts;
    usb_scan_mounts(&mounts);

    char usb_dir[MAX_PATH];
    int has_tweaks = (usb_find_tweaks_dir(usb_dir, sizeof(usb_dir)) == 0);

    tweak_list_t *usb_list = malloc(sizeof(tweak_list_t));
    if (!usb_list) { http_respond_error(req, 500, "out of memory"); return; }
    memset(usb_list, 0, sizeof(*usb_list));
    if (has_tweaks) tweaks_scan_usb(usb_list, usb_dir);

    char *json = malloc(4096);
    if (!json) { free(usb_list); http_respond_error(req, 500, "out of memory"); return; }
    int pos = snprintf(json, 4096,
        "{\"usb_mounted\":%s,\"mount_count\":%d,\"tweaks_dir\":%s,\"new_tweaks\":[",
        mounts.count > 0 ? "true" : "false",
        mounts.count,
        has_tweaks ? "true" : "false");

    int first = 1;
    refresh_tweak_list();
    for (int u = 0; u < usb_list->count; u++) {
        int installed = 0;
        int update = 0;
        for (int i = 0; i < current_list.count; i++) {
            if (strcmp(current_list.tweaks[i].id, usb_list->tweaks[u].id) == 0) {
                installed = 1;
                if (version_compare(usb_list->tweaks[u].version,
                                    current_list.tweaks[i].installed_version) > 0)
                    update = 1;
                break;
            }
        }
        if (!first) json[pos++] = ',';
        first = 0;
        pos += snprintf(json + pos, 4096 - pos,
            "{\"id\":\"%s\",\"name\":\"%s\",\"version\":\"%s\","
            "\"installed\":%s,\"update\":%s}",
            usb_list->tweaks[u].id, usb_list->tweaks[u].name,
            usb_list->tweaks[u].version,
            installed ? "true" : "false",
            update ? "true" : "false");
    }

    snprintf(json + pos, 4096 - pos, "]}");
    http_respond_json(req, 200, json);
    free(json);
    free(usb_list);
}

static void handle_version(http_request_t *req) {
    char json[256];
    snprintf(json, sizeof(json),
        "{\"version\":\"%s\",\"dump_exists\":%s}",
        VERSION, dump_exists() ? "true" : "false");
    http_respond_json(req, 200, json);
}

static void handle_backups_export(http_request_t *req) {
    usb_mounts_t mounts;
    usb_scan_mounts(&mounts);
    if (mounts.count == 0) {
        http_respond_json(req, 503,
            "{\"ok\":false,\"error\":\"no USB drive found\"}");
        return;
    }
    if (tweaks_export_backups(mounts.mount_points[0]) == 0) {
        tweaksd_log("EXPORT", NULL, "backups to USB");
        http_respond_json(req, 200, "{\"ok\":true}");
    } else {
        http_respond_json(req, 500,
            "{\"ok\":false,\"error\":\"backup export failed\"}");
    }
}

static void handle_log(http_request_t *req) {
    char *json = malloc(LOG_MAX_READ);
    if (!json) { http_respond_error(req, 500, "out of memory"); return; }
    tweaksd_log_read(json, LOG_MAX_READ, 100);
    http_respond_json(req, 200, json);
    free(json);
}

static void handle_reboot(http_request_t *req) {
    tweaksd_log("REBOOT", "-", "user requested reboot");
    http_respond_json(req, 200, "{\"ok\":true}");
    sync();
    sleep(2);
    system("reboot");
}

static void handle_log_export(http_request_t *req) {
    usb_mounts_t mounts;
    usb_scan_mounts(&mounts);
    if (mounts.count == 0) {
        http_respond_json(req, 503,
            "{\"ok\":false,\"error\":\"no USB drive found\"}");
        return;
    }
    if (tweaksd_log_export(mounts.mount_points[0]) == 0) {
        http_respond_json(req, 200, "{\"ok\":true}");
    } else {
        http_respond_json(req, 500,
            "{\"ok\":false,\"error\":\"log export failed\"}");
    }
}

/* ─── Lifecycle ─── */

static void write_pidfile(void) {
    FILE *f = fopen(PID_FILE, "w");
    if (f) { fprintf(f, "%d\n", getpid()); fclose(f); }
}

static void cleanup(int sig) {
    (void)sig;
    unlink(PID_FILE);
    httpd_stop();
    _exit(0);
}

static void daemonize(void) {
    pid_t pid = fork();
    if (pid < 0) exit(1);
    if (pid > 0) exit(0);
    setsid();
    pid = fork();
    if (pid < 0) exit(1);
    if (pid > 0) exit(0);
    close(STDIN_FILENO);
    close(STDOUT_FILENO);
    close(STDERR_FILENO);
}

int main(int argc, char **argv) {
    int foreground = 0;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-f") == 0) foreground = 1;
    }

    if (!foreground) daemonize();

    signal(SIGTERM, cleanup);
    signal(SIGINT, cleanup);
    signal(SIGPIPE, SIG_IGN);

    write_pidfile();
    tweaks_init();
    tweaksd_log("START", "-", "tweaksd v" VERSION " started");

    if (httpd_init() != 0) {
        fprintf(stderr, "tweaksd: cannot bind to port %d\n", HTTP_PORT);
        return 1;
    }

    httpd_add_route("/api/tweaks/setup/",      HTTP_POST, handle_setup);
    httpd_add_route("/api/tweaks/install/",    HTTP_POST, handle_install);
    httpd_add_route("/api/tweaks/uninstall/",  HTTP_POST, handle_uninstall);
    httpd_add_route("/api/tweaks/update/",     HTTP_POST, handle_update);
    httpd_add_route("/api/tweaks/status/",     HTTP_GET,  handle_status);
    httpd_add_route("/api/tweaks/conflicts/",  HTTP_GET,  handle_conflicts);
    httpd_add_route("/api/tweaks/list",        HTTP_GET,  handle_list);
    httpd_add_route("/api/dump/status",        HTTP_GET,  handle_dump_status);
    httpd_add_route("/api/dump/create",        HTTP_POST, handle_dump_create);
    httpd_add_route("/api/usb/scan",           HTTP_GET,  handle_usb_scan);
    httpd_add_route("/api/backups/export",     HTTP_POST, handle_backups_export);
    httpd_add_route("/api/log",                HTTP_GET,  handle_log);
    httpd_add_route("/api/log/export",         HTTP_POST, handle_log_export);
    httpd_add_route("/api/version",            HTTP_GET,  handle_version);
    httpd_add_route("/api/system/reboot",      HTTP_POST, handle_reboot);

    httpd_run();
    return 0;
}
