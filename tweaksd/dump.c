#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#include "dump.h"
#include "usb.h"

int dump_exists(void) {
    struct stat st;
    return stat(DUMP_STATE_FILE, &st) == 0;
}

int dump_create(const char *usb_dump_dir) {
    char dump_subdir[MAX_PATH];
    time_t now = time(NULL);
    struct tm *tm = localtime(&now);

    snprintf(dump_subdir, sizeof(dump_subdir),
             "%s/%04d%02d%02d_%02d%02d%02d",
             usb_dump_dir,
             tm->tm_year + 1900, tm->tm_mon + 1, tm->tm_mday,
             tm->tm_hour, tm->tm_min, tm->tm_sec);
    mkdir(dump_subdir, 0755);

    /* write a temp script to avoid shell-in-string quoting limits */
    FILE *sf = fopen("/tmp/tweaksd_dump.sh", "w");
    if (!sf) return -1;
    fprintf(sf,
        "#!/bin/sh\nD='%s'\n"
        "cat /jci/version > \"$D/version.txt\" 2>/dev/null\n"
        "cp /jci/sm/sm.conf \"$D/sm.conf\" 2>/dev/null\n"
        "cp /jci/sm/sm_WCP.conf \"$D/sm_WCP.conf\" 2>/dev/null\n"
        "cp /jci/opera/opera_dir/opera.ini \"$D/opera.ini\" 2>/dev/null\n"
        "mkdir -p \"$D/apps\"\n"
        "for a in system vehsettings syssettings; do\n"
        "  [ -d /jci/gui/apps/$a ] && cp -r /jci/gui/apps/$a/js \"$D/apps/${a}_js\" 2>/dev/null\n"
        "done\n"
        "cp /jci/nng/devmgr_config_master.xml \"$D/devmgr_config_master.xml\" 2>/dev/null\n"
        "mkdir -p \"$D/data_persist\"\n"
        "cp -r /data_persist/dev \"$D/data_persist/dev\" 2>/dev/null\n"
        "ps > \"$D/ps.txt\" 2>/dev/null\n"
        "df > \"$D/df.txt\" 2>/dev/null\n"
        "mount > \"$D/mount.txt\" 2>/dev/null\n"
        "uname -a > \"$D/uname.txt\" 2>/dev/null\n"
        "md5sum /usr/bin/svcjcinavi /usr/bin/blmjcicarplay "
        "/usr/bin/blmjciaapa /usr/bin/ipoddev_full_auth "
        "> \"$D/md5sums.txt\" 2>/dev/null\n"
        "grep LD_PRELOAD /jci/sm/sm.conf > \"$D/preloads.txt\" 2>/dev/null\n"
        "grep LD_PRELOAD /jci/sm/sm_WCP.conf >> \"$D/preloads.txt\" 2>/dev/null\n"
        "dmesg | tail -100 > \"$D/dmesg.txt\" 2>/dev/null\n"
        "/jci/scripts/get_board_type.sh > \"$D/board_type.txt\" 2>/dev/null\n"
        "echo $? >> \"$D/board_type.txt\"\n"
        "date > \"$D/dump_time.txt\"\n",
        dump_subdir);
    fclose(sf);

    int ret = system("sh /tmp/tweaksd_dump.sh");
    unlink("/tmp/tweaksd_dump.sh");
    if (ret != 0) return -1;

    /* mark dump as complete */
    mkdir("/data_persist/tweaks", 0755);
    FILE *f = fopen(DUMP_STATE_FILE, "w");
    if (f) {
        fprintf(f, "%s\n", dump_subdir);
        fclose(f);
    }
    return 0;
}

void dump_get_status(char *out, int outlen) {
    if (dump_exists()) {
        FILE *f = fopen(DUMP_STATE_FILE, "r");
        if (f) {
            char path[MAX_PATH];
            if (fgets(path, sizeof(path), f)) {
                path[strcspn(path, "\n")] = '\0';
                snprintf(out, outlen,
                    "{\"exists\":true,\"path\":\"%s\"}", path);
            }
            fclose(f);
            return;
        }
    }
    snprintf(out, outlen, "{\"exists\":false}");
}
