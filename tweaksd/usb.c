#include <stdio.h>
#include <string.h>
#include <dirent.h>
#include <sys/stat.h>
#include "usb.h"

static const char *mount_prefixes[] = {
    "/tmp/mnt/sd",
    "/mnt/sd",
    NULL
};

static const char *mount_suffixes[] = {
    "a1", "b1", "c1", "d1",
    NULL
};

int usb_scan_mounts(usb_mounts_t *mounts) {
    struct stat st;
    mounts->count = 0;

    for (int p = 0; mount_prefixes[p]; p++) {
        for (int s = 0; mount_suffixes[s]; s++) {
            if (mounts->count >= MAX_USB_MOUNTS) return mounts->count;
            char path[MAX_PATH];
            snprintf(path, sizeof(path), "%s%s", mount_prefixes[p], mount_suffixes[s]);
            if (stat(path, &st) == 0 && S_ISDIR(st.st_mode)) {
                strncpy(mounts->mount_points[mounts->count], path, MAX_PATH - 1);
                mounts->count++;
            }
        }
    }
    return mounts->count;
}

int usb_find_tweaks_dir(char *out, int outlen) {
    usb_mounts_t mounts;
    struct stat st;

    usb_scan_mounts(&mounts);
    for (int i = 0; i < mounts.count; i++) {
        char path[MAX_PATH];
        snprintf(path, sizeof(path), "%s/%s", mounts.mount_points[i], USB_TWEAKS_DIR);
        if (stat(path, &st) == 0 && S_ISDIR(st.st_mode)) {
            snprintf(out, outlen, "%s", path);
            return 0;
        }
    }
    return -1;
}

int usb_find_dump_dir(char *out, int outlen) {
    usb_mounts_t mounts;
    struct stat st;

    usb_scan_mounts(&mounts);
    for (int i = 0; i < mounts.count; i++) {
        char path[MAX_PATH];
        snprintf(path, sizeof(path), "%s/%s", mounts.mount_points[i], USB_DUMP_DIR);
        if (stat(path, &st) == 0 && S_ISDIR(st.st_mode)) {
            snprintf(out, outlen, "%s", path);
            return 0;
        }
    }
    return -1;
}

int usb_ensure_dump_dir(char *out, int outlen) {
    usb_mounts_t mounts;
    usb_scan_mounts(&mounts);
    if (mounts.count == 0) return -1;

    char base[MAX_PATH];
    snprintf(base, sizeof(base), "%s/tweaks-manager", mounts.mount_points[0]);
    mkdir(base, 0755);

    snprintf(out, outlen, "%s/dump", base);
    mkdir(out, 0755);
    return 0;
}
