#ifndef TWEAKS_H
#define TWEAKS_H

#define TWEAKS_DIR          "/data_persist/tweaks"
#define TWEAKS_INSTALLED    "/data_persist/tweaks/installed.json"
#define TWEAKS_BACKUPS      "/data_persist/tweaks/backups"
#define MAX_TWEAKS          64
#define MAX_MODIFIES        32
#define MAX_CONFLICTS       16
#define MAX_DEPENDS         16

typedef struct {
    char id[64];
    char name[128];
    char version[32];
    char description[256];
    char author[64];
    char min_firmware[16];
    char max_firmware[16];
    char regions[8][8];
    int  region_count;
    char modifies[MAX_MODIFIES][256];
    int  modifies_count;
    char conflicts_with[MAX_CONFLICTS][64];
    int  conflicts_count;
    char depends_on[MAX_DEPENDS][64];
    int  depends_count;
    int  requires_reboot;
    /* runtime state */
    int  installed;
    char installed_version[32];
    char source_path[512];
    char local_path[512];
    int  setup;
    int  update_available;
} tweak_t;

typedef struct {
    tweak_t tweaks[MAX_TWEAKS];
    int count;
} tweak_list_t;

int  tweaks_init(void);
int  tweaks_scan_installed(tweak_list_t *list);
int  tweaks_scan_usb(tweak_list_t *list, const char *usb_tweaks_dir);
int  tweaks_merge_lists(tweak_list_t *installed, const tweak_list_t *usb);
int  tweaks_scan_available(tweak_list_t *list);
int  tweaks_setup(const char *id, const tweak_list_t *list, char *result, int resultlen);
int  tweaks_install(const char *id, const tweak_list_t *list, char *result, int resultlen);
int  tweaks_uninstall(const char *id, char *result, int resultlen);
int  tweaks_update(const char *id, const tweak_list_t *list, char *result, int resultlen);
int  tweaks_check_status(const char *id, char *result, int resultlen);
int  tweaks_check_conflicts(const char *id, const tweak_list_t *list, char *result, int resultlen);
int  tweaks_backup_files(const tweak_t *tweak);
int  tweaks_restore_files(const char *id);
void tweaks_list_to_json(const tweak_list_t *list, char *out, int outlen);
int  tweak_parse_json(const char *path, tweak_t *tweak);
int  version_compare(const char *a, const char *b);
int  tweaks_export_backups(const char *usb_base);

#endif
