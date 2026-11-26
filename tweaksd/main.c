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
#define VERSION     "2.0.0"
#endif

static tweak_list_t current_list;

static void refresh_tweak_list(void) {
    memset(&current_list, 0, sizeof(current_list));
    tweaks_scan_installed(&current_list);

    tweak_list_t *avail = malloc(sizeof(tweak_list_t));
    if (avail) {
        memset(avail, 0, sizeof(*avail));
        tweaks_scan_available(avail);
        tweaks_merge_lists(&current_list, avail);
        free(avail);
    }

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

/* ─── Firewall ─── */

static void open_firewall_port(int port) {
    char cmd[192];
    snprintf(cmd, sizeof(cmd),
        "iptables -C INPUT -i wlan0 -p tcp --dport %d -j ACCEPT 2>/dev/null || "
        "iptables -I INPUT -i wlan0 -p tcp --dport %d -j ACCEPT 2>/dev/null",
        port, port);
    system(cmd);
}

/* ─── Status API ─── */

static void handle_ssh_check(http_request_t *req) {
    int port22_listening = 0;
    struct stat st;
    if (stat("/var/run/sshd_tweaks.pid", &st) == 0) {
        char pidbuf[16] = "";
        FILE *f = fopen("/var/run/sshd_tweaks.pid", "r");
        if (f) { fgets(pidbuf, sizeof(pidbuf), f); fclose(f); }
        int pid = atoi(pidbuf);
        if (pid > 0 && kill(pid, 0) == 0)
            port22_listening = 1;
    }

    int port36000_listening = 0;
    if (stat("/var/run/sshd.pid", &st) == 0)
        port36000_listening = 1;

    char json[256];
    snprintf(json, sizeof(json),
        "{\"port_22\":%s,\"port_36000\":%s}",
        port22_listening ? "true" : "false",
        port36000_listening ? "true" : "false");
    http_respond_json(req, 200, json);
}

static void handle_wifi_status(http_request_t *req) {
    int wifi_up = 0;
    struct stat st;
    if (stat("/sys/class/net/wlan0", &st) == 0)
        wifi_up = 1;

    char json[256];
    snprintf(json, sizeof(json),
        "{\"wifi_ap\":%s,\"ip\":\"192.168.53.1\"}",
        wifi_up ? "true" : "false");
    http_respond_json(req, 200, json);
}

static void handle_firewall_open(http_request_t *req) {
    const char *port_str = req->path + strlen("/api/firewall/open/");
    int port = atoi(port_str);
    if (port < 1 || port > 65535) {
        http_respond_error(req, 400, "invalid port");
        return;
    }
    open_firewall_port(port);
    tweaksd_log("FIREWALL", "-", "opened port");
    char json[128];
    snprintf(json, sizeof(json), "{\"ok\":true,\"port\":%d}", port);
    http_respond_json(req, 200, json);
}

/* ─── Tweak management API ─── */

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

    int json_cap = 16384;
    char *json = malloc(json_cap);
    if (!json) { free(usb_list); http_respond_error(req, 500, "out of memory"); return; }
    int pos = snprintf(json, json_cap,
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
        if (pos >= json_cap - 256) break;
        if (!first) json[pos++] = ',';
        first = 0;
        pos += snprintf(json + pos, json_cap - pos,
            "{\"id\":\"%s\",\"name\":\"%s\",\"version\":\"%s\","
            "\"installed\":%s,\"update\":%s}",
            usb_list->tweaks[u].id, usb_list->tweaks[u].name,
            usb_list->tweaks[u].version,
            installed ? "true" : "false",
            update ? "true" : "false");
    }

    snprintf(json + pos, json_cap - pos, "]}");
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
    if (fork() == 0) {
        sync();
        sleep(2);
        system("reboot");
        _exit(0);
    }
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

    /* Check if another instance is already running */
    {
        FILE *pf = fopen(PID_FILE, "r");
        if (pf) {
            char pidbuf[16] = "";
            fgets(pidbuf, sizeof(pidbuf), pf);
            fclose(pf);
            int old_pid = atoi(pidbuf);
            if (old_pid > 0 && kill(old_pid, 0) == 0) {
                fprintf(stderr, "tweaksd: already running (pid %d)\n", old_pid);
                return 1;
            }
        }
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

    /* Status API */
    httpd_add_route("/api/ssh/check",          HTTP_GET,  handle_ssh_check);
    httpd_add_route("/api/wifi/status",        HTTP_GET,  handle_wifi_status);
    httpd_add_route("/api/firewall/open/",     HTTP_POST, handle_firewall_open);

    /* Tweak management API */
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
