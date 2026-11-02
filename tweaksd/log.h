#ifndef LOG_H
#define LOG_H

#define LOG_FILE        "/data_persist/tweaks/tweaksd.log"
#define LOG_MAX_READ    32768

void tweaksd_log(const char *op, const char *tweak_id, const char *detail);
void tweaksd_log_output(const char *op, const char *tweak_id, const char *output);
int  tweaksd_log_read(char *out, int outlen, int last_n);
int  tweaksd_log_export(const char *usb_dir);

#endif
