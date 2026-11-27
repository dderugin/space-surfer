#ifndef DiskWalker_h
#define DiskWalker_h

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/stat.h>

typedef struct SSScan SSScan;
typedef struct SSControl SSControl;

typedef enum : uint8_t {
    SSFile,
    SSDirectory,
    SSSymbolicLink,
    SSOther,
} SSKind;

typedef enum : uint8_t {
    SSContents,
    SSFolders,
    SSBiggestFiles,
} SSRanking;

typedef struct {
    uint64_t allocated;
    uint32_t parent;
    uint32_t first_child;
    uint32_t next_sibling;
    uint32_t name_offset;
    uint32_t descendants;
    uint16_t name_length;
    SSKind kind;
    uint8_t flags;
} SSItem;

static const uint32_t SSNoItem = UINT32_MAX;

typedef struct {
    uint64_t visited;
    uint64_t skipped;
} SSProgress;

SSControl *ss_control_create(void);
void ss_control_destroy(SSControl *control);
void ss_cancel(SSControl *control);
bool ss_is_cancelled(const SSControl *control);
SSProgress ss_progress(const SSControl *control);

// A scan supports concurrent reads during a single traversal. Item IDs remain
// valid for the scan's lifetime, including IDs held by a view during removal.
SSScan *ss_scan_create(int *error);
enum { SSDefaultWorkerCount = 4, SSMaxWorkerCount = 4 };
int ss_scan_walk(SSScan *scan, const char *path, SSControl *control, bool use_bulk);
// One worker runs the serial traversal. Larger counts are capped at SSMaxWorkerCount.
int ss_scan_walk_with_workers(SSScan *scan, const char *path, SSControl *control,
                              bool use_bulk, unsigned int worker_count);
void ss_scan_destroy(SSScan *scan);
SSItem ss_item(SSScan *scan, uint32_t id);
size_t ss_copy_name(SSScan *scan, uint32_t id, char *output, size_t capacity);
// Returns the required number of IDs and writes the root-to-item path if it fits.
size_t ss_copy_trail(SSScan *scan, uint32_t id, uint32_t *output, size_t capacity);
bool ss_item_is_attached(SSScan *scan, uint32_t id);
bool ss_item_matches(SSScan *scan, uint32_t id, const struct stat *attributes);
bool ss_scan_root_matches(SSScan *scan, int fd);
bool ss_forget_removed_item(SSScan *scan, uint32_t id);

// Returns the full match count and writes up to capacity IDs, largest first.
size_t ss_rank(SSScan *scan, uint32_t folder, SSRanking mode,
               uint32_t *output, size_t capacity, const SSControl *control);

typedef struct {
    size_t count;
    uint32_t next;
    bool complete;
} SSSearchResult;

// Find case-insensitive filename substrings in discovery order. Resume at next
// to search later discoveries, or to continue after filling the output page.
SSSearchResult ss_search(SSScan *scan, const char *query, uint32_t start,
                         uint32_t *output, size_t capacity, const SSControl *control);

#endif
