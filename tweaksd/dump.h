#ifndef DUMP_H
#define DUMP_H

#define DUMP_STATE_FILE     "/data_persist/tweaks/dump_done"
#define DUMP_SCRIPT         "/data_persist/tweaks/scripts/create_dump.sh"

int  dump_exists(void);
int  dump_create(const char *usb_dump_dir);
void dump_get_status(char *out, int outlen);

#endif
