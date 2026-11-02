#ifndef USB_H
#define USB_H

#define USB_TWEAKS_DIR  "tweaks-manager/tweaks"
#define USB_DUMP_DIR    "tweaks-manager/dump"
#define MAX_USB_MOUNTS  8
#define MAX_PATH        512

typedef struct {
    char mount_points[MAX_USB_MOUNTS][MAX_PATH];
    int count;
} usb_mounts_t;

int  usb_scan_mounts(usb_mounts_t *mounts);
int  usb_find_tweaks_dir(char *out, int outlen);
int  usb_find_dump_dir(char *out, int outlen);
int  usb_ensure_dump_dir(char *out, int outlen);

#endif
