#ifndef DiskWalkerInternal_h
#define DiskWalkerInternal_h

#include "DiskWalker.h"
#include <pthread.h>
#include <stdatomic.h>
#include <sys/stat.h>

typedef struct {
    ino_t inode;
    time_t birth_seconds;
    int32_t birth_nanoseconds;
    dev_t device;
} SSFileIdentity;

// Workers append batches. Readers and post-scan removals use lock
// so arena reallocations never invalidate a pointer held by the browser.
struct SSScan {
    SSItem *items;
    SSFileIdentity *identities;
    char *names;
    size_t item_count, item_capacity, identity_capacity, name_count, name_capacity;
    pthread_rwlock_t lock;
    atomic_bool started;
    atomic_bool finished;
    struct stat root_attributes;
    bool has_root;
};

typedef struct {
    const char *name;
    uint64_t allocated;
    SSFileIdentity identity;
    size_t name_length;
    uint32_t link_count;
    SSKind kind;
} SSEntry;

void ss_index_set_root(SSScan *scan, const struct stat *attributes);
int ss_index_append_batch(SSScan *scan, uint32_t folder, const SSEntry *entries, uint32_t count);
// Advance through a folder's child list and copy the next directory's name.
// A name too long for the buffer is returned as an empty string.
uint32_t ss_index_next_directory(SSScan *scan, uint32_t *cursor, char *name, size_t capacity);

#endif
