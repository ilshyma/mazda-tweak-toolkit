#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dirent.h>
#include <sys/stat.h>
#include <unistd.h>
#include "tweaks.h"
#include "jsmn.h"
#include "usb.h"
#include "log.h"

static char firmware_version[32] = "";
static volatile int busy = 0;

static int validate_id(const char *id) {
    if (!id || !id[0]) return -1;
    for (int i = 0; id[i]; i++) {
        char c = id[i];
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
              (c >= '0' && c <= '9') || c == '-' || c == '_'))
            return -1;
    }
    return 0;
}

static void read_firmware_version(void) {
    FILE *f = fopen("/jci/version", "r");
    if (!f) { strcpy(firmware_version, "unknown"); return; }
    if (!fgets(firmware_version, sizeof(firmware_version), f))
        strcpy(firmware_version, "unknown");
    firmware_version[strcspn(firmware_version, "\n\r")] = '\0';
    fclose(f);
}

int tweaks_init(void) {
    mkdir(TWEAKS_DIR, 0755);
    mkdir(TWEAKS_BACKUPS, 0755);
    mkdir(TWEAKS_DIR "/installed", 0755);
    mkdir(TWEAKS_DIR "/available", 0755);
    read_firmware_version();
    return 0;
}

/* JSON helpers */
static int jsoneq(const char *json, jsmntok_t *tok, const char *s) {
    if (tok->type == JSMN_STRING &&
        (int)strlen(s) == tok->end - tok->start &&
        strncmp(json + tok->start, s, tok->end - tok->start) == 0)
        return 0;
    return -1;
}

static void json_strcpy(char *dst, int dstlen, const char *json, jsmntok_t *tok) {
    int len = tok->end - tok->start;
    if (len >= dstlen) len = dstlen - 1;
    memcpy(dst, json + tok->start, len);
    dst[len] = '\0';
}

int tweak_parse_json(const char *path, tweak_t *tweak) {
    FILE *f = fopen(path, "r");
    if (!f) return -1;

    fseek(f, 0, SEEK_END);
    long fsize = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (fsize > 16384 || fsize <= 0) { fclose(f); return -1; }

    char *json = malloc(fsize + 1);
    if (!json) { fclose(f); return -1; }
    fread(json, 1, fsize, f);
    json[fsize] = '\0';
    fclose(f);

    jsmn_parser parser;
    jsmntok_t tokens[256];
    jsmn_init(&parser);
    int r = jsmn_parse(&parser, json, fsize, tokens, 256);
    if (r < 1 || tokens[0].type != JSMN_OBJECT) { free(json); return -1; }

    memset(tweak, 0, sizeof(*tweak));

    for (int i = 1; i < r; i++) {
        if (jsoneq(json, &tokens[i], "id") == 0) {
            json_strcpy(tweak->id, sizeof(tweak->id), json, &tokens[i + 1]);
            i++;
        } else if (jsoneq(json, &tokens[i], "name") == 0) {
            json_strcpy(tweak->name, sizeof(tweak->name), json, &tokens[i + 1]);
            i++;
        } else if (jsoneq(json, &tokens[i], "version") == 0) {
            json_strcpy(tweak->version, sizeof(tweak->version), json, &tokens[i + 1]);
            i++;
        } else if (jsoneq(json, &tokens[i], "description") == 0) {
            json_strcpy(tweak->description, sizeof(tweak->description), json, &tokens[i + 1]);
            i++;
        } else if (jsoneq(json, &tokens[i], "author") == 0) {
            json_strcpy(tweak->author, sizeof(tweak->author), json, &tokens[i + 1]);
            i++;
        } else if (jsoneq(json, &tokens[i], "min_firmware") == 0) {
            json_strcpy(tweak->min_firmware, sizeof(tweak->min_firmware), json, &tokens[i + 1]);
            i++;
        } else if (jsoneq(json, &tokens[i], "max_firmware") == 0) {
            json_strcpy(tweak->max_firmware, sizeof(tweak->max_firmware), json, &tokens[i + 1]);
            i++;
        } else if (jsoneq(json, &tokens[i], "requires_reboot") == 0) {
            tweak->requires_reboot = (strncmp(json + tokens[i + 1].start, "true", 4) == 0);
            i++;
        } else if (jsoneq(json, &tokens[i], "regions") == 0) {
            int arr_size = tokens[i + 1].size;
            i += 2;
            for (int j = 0; j < arr_size && tweak->region_count < 8; j++) {
                json_strcpy(tweak->regions[tweak->region_count],
                           sizeof(tweak->regions[0]), json, &tokens[i]);
                tweak->region_count++;
                i++;
            }
            i--;
        } else if (jsoneq(json, &tokens[i], "modifies") == 0) {
            int arr_size = tokens[i + 1].size;
            i += 2;
            for (int j = 0; j < arr_size && tweak->modifies_count < MAX_MODIFIES; j++) {
                json_strcpy(tweak->modifies[tweak->modifies_count],
                           sizeof(tweak->modifies[0]), json, &tokens[i]);
                tweak->modifies_count++;
                i++;
            }
            i--;
        } else if (jsoneq(json, &tokens[i], "conflicts_with") == 0) {
            int arr_size = tokens[i + 1].size;
            i += 2;
            for (int j = 0; j < arr_size && tweak->conflicts_count < MAX_CONFLICTS; j++) {
                json_strcpy(tweak->conflicts_with[tweak->conflicts_count],
                           sizeof(tweak->conflicts_with[0]), json, &tokens[i]);
                tweak->conflicts_count++;
                i++;
            }
            i--;
        } else if (jsoneq(json, &tokens[i], "depends_on") == 0) {
            int arr_size = tokens[i + 1].size;
            i += 2;
            for (int j = 0; j < arr_size && tweak->depends_count < MAX_DEPENDS; j++) {
                json_strcpy(tweak->depends_on[tweak->depends_count],
                           sizeof(tweak->depends_on[0]), json, &tokens[i]);
                tweak->depends_count++;
                i++;
            }
            i--;
        }
    }
    free(json);
    return (tweak->id[0] && tweak->name[0] && tweak->version[0]) ? 0 : -1;
}

int tweaks_scan_installed(tweak_list_t *list) {
    DIR *d = opendir(TWEAKS_DIR "/installed");
    if (!d) return 0;

    struct dirent *ent;
    while ((ent = readdir(d)) != NULL && list->count < MAX_TWEAKS) {
        if (ent->d_name[0] == '.') continue;
        char path[MAX_PATH];
        snprintf(path, sizeof(path), "%s/installed/%s/tweak.json",
                 TWEAKS_DIR, ent->d_name);
        struct stat st;
        if (stat(path, &st) != 0) continue;

        if (tweak_parse_json(path, &list->tweaks[list->count]) == 0) {
            list->tweaks[list->count].installed = 1;
            strncpy(list->tweaks[list->count].installed_version,
                    list->tweaks[list->count].version, 31);
            list->count++;
        }
    }
    closedir(d);
    return list->count;
}

int tweaks_scan_available(tweak_list_t *list) {
    DIR *d = opendir(TWEAKS_DIR "/available");
    if (!d) return 0;

    struct dirent *ent;
    while ((ent = readdir(d)) != NULL && list->count < MAX_TWEAKS) {
        if (ent->d_name[0] == '.') continue;
        char path[MAX_PATH];
        snprintf(path, sizeof(path), "%s/available/%s/tweak.json",
                 TWEAKS_DIR, ent->d_name);
        struct stat st;
        if (stat(path, &st) != 0) continue;

        if (tweak_parse_json(path, &list->tweaks[list->count]) == 0) {
            list->tweaks[list->count].setup = 1;
            snprintf(list->tweaks[list->count].local_path,
                     sizeof(list->tweaks[0].local_path),
                     "%s/available/%s", TWEAKS_DIR, ent->d_name);
            list->count++;
        }
    }
    closedir(d);
    return list->count;
}

int tweaks_scan_usb(tweak_list_t *list, const char *usb_tweaks_dir) {
    DIR *d = opendir(usb_tweaks_dir);
    if (!d) return 0;

    struct dirent *ent;
    while ((ent = readdir(d)) != NULL && list->count < MAX_TWEAKS) {
        if (ent->d_name[0] == '.') continue;
        char path[MAX_PATH];
        snprintf(path, sizeof(path), "%s/%s/tweak.json",
                 usb_tweaks_dir, ent->d_name);
        struct stat st;
        if (stat(path, &st) != 0) continue;

        if (tweak_parse_json(path, &list->tweaks[list->count]) == 0) {
            snprintf(list->tweaks[list->count].source_path,
                     sizeof(list->tweaks[0].source_path),
                     "%s/%s", usb_tweaks_dir, ent->d_name);
            list->count++;
        }
    }
    closedir(d);
    return list->count;
}

int tweaks_merge_lists(tweak_list_t *installed, const tweak_list_t *usb) {
    for (int u = 0; u < usb->count; u++) {
        int found = 0;
        for (int i = 0; i < installed->count; i++) {
            if (strcmp(installed->tweaks[i].id, usb->tweaks[u].id) == 0) {
                found = 1;
                if (usb->tweaks[u].source_path[0])
                    strncpy(installed->tweaks[i].source_path,
                            usb->tweaks[u].source_path,
                            sizeof(installed->tweaks[0].source_path) - 1);
                if (usb->tweaks[u].local_path[0]) {
                    strncpy(installed->tweaks[i].local_path,
                            usb->tweaks[u].local_path,
                            sizeof(installed->tweaks[0].local_path) - 1);
                    installed->tweaks[i].setup = 1;
                }
                if (version_compare(usb->tweaks[u].version,
                                    installed->tweaks[i].installed_version) > 0) {
                    installed->tweaks[i].update_available = 1;
                    strncpy(installed->tweaks[i].version,
                            usb->tweaks[u].version, 31);
                    strncpy(installed->tweaks[i].description,
                            usb->tweaks[u].description,
                            sizeof(installed->tweaks[0].description) - 1);
                }
                break;
            }
        }
        if (!found && installed->count < MAX_TWEAKS) {
            memcpy(&installed->tweaks[installed->count], &usb->tweaks[u],
                   sizeof(tweak_t));
            installed->count++;
        }
    }
    return installed->count;
}

int tweaks_backup_files(const tweak_t *tweak) {
    char backup_dir[MAX_PATH];
    snprintf(backup_dir, sizeof(backup_dir), "%s/%s", TWEAKS_BACKUPS, tweak->id);
    mkdir(backup_dir, 0755);

    for (int i = 0; i < tweak->modifies_count; i++) {
        struct stat st;
        if (stat(tweak->modifies[i], &st) != 0) continue;

        char dst[MAX_PATH];
        const char *basename = strrchr(tweak->modifies[i], '/');
        basename = basename ? basename + 1 : tweak->modifies[i];
        snprintf(dst, sizeof(dst), "%s/%s", backup_dir, basename);

        char cmd[1024];
        if (S_ISDIR(st.st_mode)) {
            snprintf(cmd, sizeof(cmd), "rm -rf '%s' && cp -a '%s' '%s'", dst, tweak->modifies[i], dst);
        } else {
            snprintf(cmd, sizeof(cmd), "cp -a '%s' '%s'", tweak->modifies[i], dst);
        }
        if (system(cmd) != 0) return -1;
    }
    return 0;
}

int tweaks_restore_files(const char *id) {
    char backup_dir[MAX_PATH];
    snprintf(backup_dir, sizeof(backup_dir), "%s/%s", TWEAKS_BACKUPS, id);

    char tweak_path[MAX_PATH];
    snprintf(tweak_path, sizeof(tweak_path), "%s/installed/%s/tweak.json",
             TWEAKS_DIR, id);

    tweak_t tweak;
    if (tweak_parse_json(tweak_path, &tweak) != 0) return -1;

    for (int i = 0; i < tweak.modifies_count; i++) {
        const char *basename = strrchr(tweak.modifies[i], '/');
        basename = basename ? basename + 1 : tweak.modifies[i];

        char src[MAX_PATH];
        snprintf(src, sizeof(src), "%s/%s", backup_dir, basename);

        struct stat st;
        if (stat(src, &st) != 0) continue;

        char cmd[1024];
        if (S_ISDIR(st.st_mode)) {
            snprintf(cmd, sizeof(cmd), "cp -a '%s'/. '%s/'", src, tweak.modifies[i]);
        } else {
            snprintf(cmd, sizeof(cmd), "cp -a '%s' '%s'", src, tweak.modifies[i]);
        }
        system(cmd);
    }
    return 0;
}

int tweaks_setup(const char *id, const tweak_list_t *list, char *result, int resultlen) {
    if (validate_id(id) != 0) {
        snprintf(result, resultlen, "{\"ok\":false,\"error\":\"invalid tweak id\"}");
        return -1;
    }
    if (busy) {
        snprintf(result, resultlen, "{\"ok\":false,\"error\":\"another operation in progress\"}");
        return -1;
    }

    const tweak_t *tweak = NULL;
    for (int i = 0; i < list->count; i++) {
        if (strcmp(list->tweaks[i].id, id) == 0) {
            tweak = &list->tweaks[i];
            break;
        }
    }
    if (!tweak) {
        snprintf(result, resultlen, "{\"ok\":false,\"error\":\"tweak not found\"}");
        return -1;
    }
    if (!tweak->source_path[0]) {
        snprintf(result, resultlen, "{\"ok\":false,\"error\":\"no source (USB not mounted?)\"}");
        return -1;
    }

    busy = 1;

    char dst[MAX_PATH];
    snprintf(dst, sizeof(dst), "%s/available/%s", TWEAKS_DIR, id);

    char cmd[1024];
    snprintf(cmd, sizeof(cmd), "rm -rf '%s' && cp -a '%s' '%s'",
             dst, tweak->source_path, dst);
    int ret = system(cmd);

    if (ret != 0) {
        snprintf(result, resultlen, "{\"ok\":false,\"error\":\"copy failed\"}");
        busy = 0;
        return -1;
    }

    tweaksd_log("SETUP", id, "copied from USB to CMU");
    snprintf(result, resultlen, "{\"ok\":true}");
    busy = 0;
    return 0;
}

int tweaks_install(const char *id, const tweak_list_t *list, char *result, int resultlen) {
    if (validate_id(id) != 0) {
        snprintf(result, resultlen, "{\"ok\":false,\"error\":\"invalid tweak id\"}");
        return -1;
    }
    if (busy) {
        snprintf(result, resultlen, "{\"ok\":false,\"error\":\"another operation in progress\"}");
        return -1;
    }

    const tweak_t *tweak = NULL;
    for (int i = 0; i < list->count; i++) {
        if (strcmp(list->tweaks[i].id, id) == 0) {
            tweak = &list->tweaks[i];
            break;
        }
    }
    if (!tweak) {
        snprintf(result, resultlen, "{\"ok\":false,\"error\":\"tweak not found\"}");
        return -1;
    }
    const char *script_dir = tweak->local_path[0] ? tweak->local_path : tweak->source_path;
    if (!script_dir[0]) {
        snprintf(result, resultlen, "{\"ok\":false,\"error\":\"not set up (run setup first)\"}");
        return -1;
    }

    busy = 1;

    /* remount rw */
    system("mount -o remount,rw /");

    /* backup files before modifying */
    if (tweak->modifies_count > 0) {
        if (tweaks_backup_files(tweak) != 0) {
            snprintf(result, resultlen, "{\"ok\":false,\"error\":\"backup failed\"}");
            system("mount -o remount,ro /");
            busy = 0;
            return -1;
        }
    }

    /* run install script from local copy (or USB fallback) */
    char cmd[1024];
    snprintf(cmd, sizeof(cmd), "NO_REBOOT=1 TWEAK_DIR='%s' TWEAKS_LIB='%s/lib/patch.sh' sh '%s/install.sh' 2>&1",
             script_dir, TWEAKS_DIR, script_dir);
    FILE *p = popen(cmd, "r");
    if (!p) {
        snprintf(result, resultlen, "{\"ok\":false,\"error\":\"cannot run install script\"}");
        system("mount -o remount,ro /");
        busy = 0;
        return -1;
    }

    char output[2048] = "";
    int olen = 0;
    char line[256];
    while (fgets(line, sizeof(line), p)) {
        int ll = strlen(line);
        if (olen + ll < (int)sizeof(output) - 1) {
            memcpy(output + olen, line, ll);
            olen += ll;
        }
    }
    output[olen] = '\0';
    int ret = pclose(p);

    if (olen >= (int)sizeof(output) - 256)
        tweaksd_log("WARN", id, "install script output may be truncated");
    tweaksd_log_output(ret == 0 ? "INSTALL_OUT" : "INSTALL_ERR", id, output);

    if (ret != 0) {
        snprintf(result, resultlen,
                 "{\"ok\":false,\"error\":\"install script failed (exit %d)\"}", ret);
        system("mount -o remount,ro /");
        busy = 0;
        return -1;
    }

    /* script may have left rootfs ro — re-mount for bookkeeping */
    system("mount -o remount,rw /");

    /* copy full tweak package to installed dir */
    char inst_dir[MAX_PATH];
    snprintf(inst_dir, sizeof(inst_dir), "%s/installed/%s", TWEAKS_DIR, id);
    snprintf(cmd, sizeof(cmd), "rm -rf '%s' && cp -a '%s' '%s'",
             inst_dir, script_dir, inst_dir);
    system(cmd);

    system("mount -o remount,ro /");

    snprintf(result, resultlen,
             "{\"ok\":true,\"reboot\":%s}",
             tweak->requires_reboot ? "true" : "false");

    busy = 0;
    return 0;
}

int tweaks_uninstall(const char *id, char *result, int resultlen) {
    if (validate_id(id) != 0) {
        snprintf(result, resultlen, "{\"ok\":false,\"error\":\"invalid tweak id\"}");
        return -1;
    }
    if (busy) {
        snprintf(result, resultlen, "{\"ok\":false,\"error\":\"another operation in progress\"}");
        return -1;
    }

    char inst_dir[MAX_PATH];
    snprintf(inst_dir, sizeof(inst_dir), "%s/installed/%s", TWEAKS_DIR, id);

    struct stat st;
    if (stat(inst_dir, &st) != 0) {
        snprintf(result, resultlen, "{\"ok\":false,\"error\":\"not installed\"}");
        return -1;
    }

    char tweak_path[MAX_PATH];
    snprintf(tweak_path, sizeof(tweak_path), "%s/tweak.json", inst_dir);
    tweak_t tweak;
    if (tweak_parse_json(tweak_path, &tweak) != 0) {
        snprintf(result, resultlen, "{\"ok\":false,\"error\":\"bad tweak.json\"}");
        return -1;
    }

    busy = 1;

    system("mount -o remount,rw /");

    int script_ret = 0;

    /* try uninstall script if source available */
    char usb_dir[MAX_PATH];
    int has_usb_script = 0;
    if (usb_find_tweaks_dir(usb_dir, sizeof(usb_dir)) == 0) {
        char script[MAX_PATH];
        snprintf(script, sizeof(script), "%s/%s/uninstall.sh", usb_dir, id);
        if (stat(script, &st) == 0) {
            has_usb_script = 1;
            char cmd[1024];
            snprintf(cmd, sizeof(cmd),
                     "NO_REBOOT=1 TWEAK_DIR='%s/%s' TWEAKS_LIB='%s/lib/patch.sh' sh '%s' 2>&1",
                     usb_dir, id, TWEAKS_DIR, script);
            script_ret = system(cmd);
        }
    }

    /* also check installed dir for uninstall script */
    if (!has_usb_script) {
        char script[MAX_PATH];
        snprintf(script, sizeof(script), "%s/uninstall.sh", inst_dir);
        if (stat(script, &st) == 0) {
            char cmd[1024];
            snprintf(cmd, sizeof(cmd),
                     "NO_REBOOT=1 TWEAK_DIR='%s' TWEAKS_LIB='%s/lib/patch.sh' sh '%s' 2>&1",
                     inst_dir, TWEAKS_DIR, script);
            script_ret = system(cmd);
        } else {
            /* no script — restore from backup */
            tweaks_restore_files(id);
        }
    }

    if (script_ret != 0) {
        snprintf(result, resultlen,
                 "{\"ok\":false,\"error\":\"uninstall script failed (exit %d)\"}", script_ret);
        system("mount -o remount,ro /");
        busy = 0;
        return -1;
    }

    /* script may have left rootfs ro — re-mount for bookkeeping */
    system("mount -o remount,rw /");

    /* remove installed record */
    char cmd[512];
    snprintf(cmd, sizeof(cmd), "rm -rf '%s'", inst_dir);
    system(cmd);

    system("mount -o remount,ro /");

    snprintf(result, resultlen,
             "{\"ok\":true,\"reboot\":%s}",
             tweak.requires_reboot ? "true" : "false");

    busy = 0;
    return 0;
}

int tweaks_update(const char *id, const tweak_list_t *list, char *result, int resultlen) {
    if (validate_id(id) != 0) {
        snprintf(result, resultlen, "{\"ok\":false,\"error\":\"invalid tweak id\"}");
        return -1;
    }
    if (busy) {
        snprintf(result, resultlen, "{\"ok\":false,\"error\":\"another operation in progress\"}");
        return -1;
    }

    char inst_dir[MAX_PATH];
    snprintf(inst_dir, sizeof(inst_dir), "%s/installed/%s", TWEAKS_DIR, id);

    struct stat st;
    if (stat(inst_dir, &st) != 0) {
        snprintf(result, resultlen, "{\"ok\":false,\"error\":\"not installed\"}");
        return -1;
    }

    const tweak_t *tweak = NULL;
    for (int i = 0; i < list->count; i++) {
        if (strcmp(list->tweaks[i].id, id) == 0) {
            tweak = &list->tweaks[i];
            break;
        }
    }
    if (!tweak || !tweak->source_path[0]) {
        snprintf(result, resultlen, "{\"ok\":false,\"error\":\"no source (USB not mounted?)\"}");
        return -1;
    }

    busy = 1;
    system("mount -o remount,rw /");

    /* Step 1: run uninstall with NO_REBOOT=1 */
    int uninstall_ok = 0;
    char usb_dir[MAX_PATH];
    if (usb_find_tweaks_dir(usb_dir, sizeof(usb_dir)) == 0) {
        char script[MAX_PATH];
        snprintf(script, sizeof(script), "%s/%s/uninstall.sh", usb_dir, id);
        if (stat(script, &st) == 0) {
            char cmd[1024];
            snprintf(cmd, sizeof(cmd),
                     "NO_REBOOT=1 TWEAK_DIR='%s/%s' TWEAKS_LIB='%s/lib/patch.sh' sh '%s' 2>&1",
                     usb_dir, id, TWEAKS_DIR, script);
            uninstall_ok = (system(cmd) == 0);
        }
    }
    if (!uninstall_ok) {
        snprintf(inst_dir, sizeof(inst_dir), "%s/installed/%s/uninstall.sh", TWEAKS_DIR, id);
        if (stat(inst_dir, &st) == 0) {
            char cmd[1024];
            snprintf(cmd, sizeof(cmd),
                     "NO_REBOOT=1 TWEAK_DIR='%s/installed/%s' TWEAKS_LIB='%s/lib/patch.sh' sh '%s' 2>&1",
                     TWEAKS_DIR, id, TWEAKS_DIR, inst_dir);
            uninstall_ok = (system(cmd) == 0);
        } else {
            tweaks_restore_files(id);
            uninstall_ok = 1;
        }
    }

    if (!uninstall_ok) {
        snprintf(result, resultlen, "{\"ok\":false,\"error\":\"uninstall step failed\"}");
        system("mount -o remount,ro /");
        busy = 0;
        return -1;
    }

    tweaksd_log("UPDATE", id, "uninstall done, installing new");

    /* remove old installed record */
    system("mount -o remount,rw /");
    snprintf(inst_dir, sizeof(inst_dir), "%s/installed/%s", TWEAKS_DIR, id);
    char rmcmd[512];
    snprintf(rmcmd, sizeof(rmcmd), "rm -rf '%s'", inst_dir);
    system(rmcmd);

    /* Step 2: run install */
    if (tweak->modifies_count > 0)
        tweaks_backup_files(tweak);

    char cmd[1024];
    snprintf(cmd, sizeof(cmd),
             "NO_REBOOT=1 TWEAK_DIR='%s' TWEAKS_LIB='%s/lib/patch.sh' sh '%s/install.sh' 2>&1",
             tweak->source_path, TWEAKS_DIR, tweak->source_path);
    FILE *p = popen(cmd, "r");
    if (!p) {
        snprintf(result, resultlen, "{\"ok\":false,\"error\":\"cannot run install script\"}");
        system("mount -o remount,ro /");
        busy = 0;
        return -1;
    }

    char output[2048] = "";
    int olen = 0;
    char line[256];
    while (fgets(line, sizeof(line), p)) {
        int ll = strlen(line);
        if (olen + ll < (int)sizeof(output) - 1) {
            memcpy(output + olen, line, ll);
            olen += ll;
        }
    }
    output[olen] = '\0';
    int ret = pclose(p);

    if (olen >= (int)sizeof(output) - 256)
        tweaksd_log("WARN", id, "update install output may be truncated");
    tweaksd_log_output(ret == 0 ? "UPDATE_OUT" : "UPDATE_ERR", id, output);

    if (ret != 0) {
        snprintf(result, resultlen,
                 "{\"ok\":false,\"error\":\"install step failed (exit %d)\"}", ret);
        system("mount -o remount,ro /");
        busy = 0;
        return -1;
    }

    system("mount -o remount,rw /");

    snprintf(inst_dir, sizeof(inst_dir), "%s/installed/%s", TWEAKS_DIR, id);
    snprintf(cmd, sizeof(cmd), "rm -rf '%s' && cp -a '%s' '%s'",
             inst_dir, tweak->source_path, inst_dir);
    system(cmd);

    system("mount -o remount,ro /");

    snprintf(result, resultlen,
             "{\"ok\":true,\"reboot\":%s}",
             tweak->requires_reboot ? "true" : "false");

    busy = 0;
    return 0;
}

int tweaks_check_status(const char *id, char *result, int resultlen) {
    char check_path[MAX_PATH];
    /* try USB source first */
    char usb_dir[MAX_PATH];
    int found = 0;

    if (usb_find_tweaks_dir(usb_dir, sizeof(usb_dir)) == 0) {
        snprintf(check_path, sizeof(check_path), "%s/%s/check.sh", usb_dir, id);
        struct stat st;
        if (stat(check_path, &st) == 0) found = 1;
    }

    if (!found) {
        snprintf(check_path, sizeof(check_path),
                 "%s/installed/%s/check.sh", TWEAKS_DIR, id);
        struct stat st;
        if (stat(check_path, &st) != 0) {
            /* no check script — just report installed/not */
            char inst_dir[MAX_PATH];
            snprintf(inst_dir, sizeof(inst_dir), "%s/installed/%s", TWEAKS_DIR, id);
            struct stat st2;
            snprintf(result, resultlen,
                     "{\"installed\":%s}",
                     stat(inst_dir, &st2) == 0 ? "true" : "false");
            return 0;
        }
    }

    char cmd[1024];
    snprintf(cmd, sizeof(cmd), "sh '%s' 2>&1", check_path);
    FILE *p = popen(cmd, "r");
    if (!p) {
        snprintf(result, resultlen, "{\"error\":\"cannot run check\"}");
        return -1;
    }

    char output[1024] = "";
    int olen = 0;
    char line[256];
    while (fgets(line, sizeof(line), p)) {
        int ll = strlen(line);
        if (olen + ll < (int)sizeof(output) - 1) {
            memcpy(output + olen, line, ll);
            olen += ll;
        }
    }
    output[olen] = '\0';
    int ret = pclose(p);

    snprintf(result, resultlen,
             "{\"installed\":%s,\"active\":%s}",
             ret == 0 ? "true" : "false",
             ret == 0 ? "true" : "false");
    return 0;
}

int tweaks_check_conflicts(const char *id, const tweak_list_t *list,
                            char *result, int resultlen) {
    const tweak_t *tweak = NULL;
    for (int i = 0; i < list->count; i++) {
        if (strcmp(list->tweaks[i].id, id) == 0) {
            tweak = &list->tweaks[i];
            break;
        }
    }
    if (!tweak) {
        snprintf(result, resultlen, "{\"conflicts\":[]}");
        return 0;
    }

    char conflicts[2048] = "[";
    int clen = 1;

    /* check declared conflicts */
    for (int c = 0; c < tweak->conflicts_count; c++) {
        for (int i = 0; i < list->count; i++) {
            if (list->tweaks[i].installed &&
                strcmp(list->tweaks[i].id, tweak->conflicts_with[c]) == 0) {
                if (clen > 1) conflicts[clen++] = ',';
                clen += snprintf(conflicts + clen, sizeof(conflicts) - clen,
                    "{\"type\":\"declared\",\"tweak\":\"%s\"}",
                    list->tweaks[i].id);
            }
        }
    }

    /* check file-level conflicts */
    for (int m = 0; m < tweak->modifies_count; m++) {
        for (int i = 0; i < list->count; i++) {
            if (!list->tweaks[i].installed) continue;
            if (strcmp(list->tweaks[i].id, id) == 0) continue;
            for (int om = 0; om < list->tweaks[i].modifies_count; om++) {
                if (strcmp(tweak->modifies[m], list->tweaks[i].modifies[om]) == 0) {
                    if (clen > 1) conflicts[clen++] = ',';
                    clen += snprintf(conflicts + clen, sizeof(conflicts) - clen,
                        "{\"type\":\"file\",\"tweak\":\"%s\",\"file\":\"%s\"}",
                        list->tweaks[i].id, tweak->modifies[m]);
                }
            }
        }
    }

    strcat(conflicts, "]");
    snprintf(result, resultlen, "{\"conflicts\":%s}", conflicts);
    return 0;
}

int version_compare(const char *a, const char *b) {
    int a1 = 0, a2 = 0, a3 = 0;
    int b1 = 0, b2 = 0, b3 = 0;
    sscanf(a, "%d.%d.%d", &a1, &a2, &a3);
    sscanf(b, "%d.%d.%d", &b1, &b2, &b3);
    if (a1 != b1) return a1 - b1;
    if (a2 != b2) return a2 - b2;
    return a3 - b3;
}

static void json_escape(const char *src, char *dst, int dstlen) {
    int j = 0;
    for (int i = 0; src[i] && j < dstlen - 2; i++) {
        if (src[i] == '"' || src[i] == '\\') {
            dst[j++] = '\\';
        } else if (src[i] == '\n') {
            dst[j++] = '\\'; dst[j++] = 'n'; continue;
        } else if (src[i] == '\r') {
            continue;
        }
        dst[j++] = src[i];
    }
    dst[j] = '\0';
}

void tweaks_list_to_json(const tweak_list_t *list, char *out, int outlen) {
    int pos = 0;
    pos += snprintf(out + pos, outlen - pos, "{\"tweaks\":[");

    for (int i = 0; i < list->count && pos < outlen - 512; i++) {
        const tweak_t *t = &list->tweaks[i];
        char esc_id[128], esc_name[256], esc_ver[64], esc_desc[512], esc_author[128], esc_iver[64];
        json_escape(t->id, esc_id, sizeof(esc_id));
        json_escape(t->name, esc_name, sizeof(esc_name));
        json_escape(t->version, esc_ver, sizeof(esc_ver));
        json_escape(t->description, esc_desc, sizeof(esc_desc));
        json_escape(t->author, esc_author, sizeof(esc_author));
        json_escape(t->installed_version, esc_iver, sizeof(esc_iver));

        if (i > 0) out[pos++] = ',';
        pos += snprintf(out + pos, outlen - pos,
            "{"
            "\"id\":\"%s\","
            "\"name\":\"%s\","
            "\"version\":\"%s\","
            "\"description\":\"%s\","
            "\"author\":\"%s\","
            "\"installed\":%s,"
            "\"installed_version\":\"%s\","
            "\"update_available\":%s,"
            "\"requires_reboot\":%s,"
            "\"has_source\":%s,"
            "\"setup\":%s"
            "}",
            esc_id, esc_name, esc_ver, esc_desc, esc_author,
            t->installed ? "true" : "false",
            esc_iver,
            t->update_available ? "true" : "false",
            t->requires_reboot ? "true" : "false",
            t->source_path[0] ? "true" : "false",
            t->setup ? "true" : "false");
    }

    char esc_fw[64];
    json_escape(firmware_version, esc_fw, sizeof(esc_fw));
    pos += snprintf(out + pos, outlen - pos,
        "],\"firmware\":\"%s\",\"count\":%d}",
        esc_fw, list->count);
}

int tweaks_export_backups(const char *usb_base) {
    char dst[MAX_PATH];
    snprintf(dst, sizeof(dst), "%s/tweaks-manager", usb_base);
    mkdir(dst, 0755);
    snprintf(dst, sizeof(dst), "%s/tweaks-manager/backups", usb_base);
    mkdir(dst, 0755);

    struct stat st;
    if (stat(TWEAKS_BACKUPS, &st) != 0) return -1;

    char cmd[1024];
    snprintf(cmd, sizeof(cmd), "cp -a '%s'/. '%s/'", TWEAKS_BACKUPS, dst);
    return system(cmd) == 0 ? 0 : -1;
}
