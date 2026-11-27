#include "DiskWalkerInternal.h"

#include <CoreFoundation/CoreFoundation.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>

enum {
    has_hard_links = 1 << 0,
    detached = 1 << 1,
};

_Static_assert(sizeof(SSItem) == 32, "Keep scan records compact");

static void read_lock(SSScan *scan) {
    pthread_rwlock_rdlock(&scan->lock);
}

static void write_lock(SSScan *scan) {
    pthread_rwlock_wrlock(&scan->lock);
}

static void unlock(SSScan *scan) {
    pthread_rwlock_unlock(&scan->lock);
}

static void *grow(void *storage, size_t *capacity, size_t needed, size_t element_size) {
    size_t new_capacity = *capacity ? *capacity : 4096;
    while (new_capacity < needed && new_capacity <= SIZE_MAX / 2) new_capacity *= 2;
    if (new_capacity < needed || new_capacity > SIZE_MAX / element_size) return NULL;
    void *resized = realloc(storage, new_capacity * element_size);
    if (resized) *capacity = new_capacity;
    return resized;
}

static int reserve_entry_storage(SSScan *scan, size_t names_needed) {
    if (scan->item_count == scan->item_capacity) {
        SSItem *items = grow(scan->items, &scan->item_capacity, scan->item_count + 1, sizeof(*items));
        if (!items) return ENOMEM;
        scan->items = items;
    }
    if (scan->item_count == scan->identity_capacity) {
        SSFileIdentity *identities = grow(scan->identities, &scan->identity_capacity, scan->item_count + 1,
                                          sizeof(*identities));
        if (!identities) return ENOMEM;
        scan->identities = identities;
    }
    if (names_needed > scan->name_capacity) {
        char *names = grow(scan->names, &scan->name_capacity, names_needed, 1);
        if (!names) return ENOMEM;
        scan->names = names;
    }
    return 0;
}

static int append_entry(SSScan *scan, uint32_t parent, SSEntry entry) {
    const size_t names_needed = scan->name_count + entry.name_length + 1;
    if (scan->item_count >= SSNoItem || names_needed > UINT32_MAX || entry.name_length > UINT16_MAX) {
        return EOVERFLOW;
    }
    int error = reserve_entry_storage(scan, names_needed);
    if (error) return error;

    const uint32_t id = (uint32_t)scan->item_count++;
    scan->identities[id] = entry.identity;
    scan->items[id] = (SSItem){
        .allocated = entry.allocated,
        .parent = parent,
        .first_child = SSNoItem,
        .next_sibling = parent == SSNoItem ? SSNoItem : scan->items[parent].first_child,
        .name_offset = (uint32_t)scan->name_count,
        .name_length = (uint16_t)entry.name_length,
        .kind = entry.kind,
        .flags = entry.kind == SSFile && entry.link_count > 1 ? has_hard_links : 0,
    };
    if (parent != SSNoItem) scan->items[parent].first_child = id;
    memcpy(scan->names + scan->name_count, entry.name, entry.name_length);
    scan->names[names_needed - 1] = '\0';
    scan->name_count = names_needed;
    return 0;
}

int ss_index_append_batch(SSScan *scan, uint32_t folder, const SSEntry *entries, uint32_t count) {
    if (count == 0) return 0;
    uint64_t allocated = 0;
    uint32_t appended = 0;
    uint8_t flags = 0;
    int error = 0;
    write_lock(scan);
    for (; appended < count; appended++) {
        error = append_entry(scan, folder, entries[appended]);
        if (error) break;
        allocated += scan->items[scan->item_count - 1].allocated;
        flags |= scan->items[scan->item_count - 1].flags;
    }
    // Publish names, child links and all ancestor totals in the same write.
    for (uint32_t ancestor = folder; ancestor != SSNoItem; ancestor = scan->items[ancestor].parent) {
        scan->items[ancestor].allocated += allocated;
        scan->items[ancestor].descendants += appended;
        scan->items[ancestor].flags |= flags;
    }
    unlock(scan);
    return error;
}

SSScan *ss_scan_create(int *error) {
    *error = 0;
    SSScan *scan = calloc(1, sizeof(*scan));
    if (!scan) {
        *error = ENOMEM;
        return NULL;
    }
    *error = pthread_rwlock_init(&scan->lock, NULL);
    if (*error) {
        free(scan);
        return NULL;
    }
    atomic_init(&scan->started, false);
    atomic_init(&scan->finished, false);
    *error = append_entry(scan, SSNoItem, (SSEntry){.name = "", .kind = SSDirectory});
    if (*error) {
        ss_scan_destroy(scan);
        return NULL;
    }
    return scan;
}

void ss_scan_destroy(SSScan *scan) {
    if (!scan) return;
    free(scan->items);
    free(scan->identities);
    free(scan->names);
    pthread_rwlock_destroy(&scan->lock);
    free(scan);
}

SSItem ss_item(SSScan *scan, uint32_t id) {
    read_lock(scan);
    SSItem item = scan->items[id];
    unlock(scan);
    return item;
}

size_t ss_copy_name(SSScan *scan, uint32_t id, char *output, size_t capacity) {
    read_lock(scan);
    SSItem item = scan->items[id];
    if (capacity > item.name_length) memcpy(output, scan->names + item.name_offset, item.name_length + 1);
    unlock(scan);
    return item.name_length;
}

uint32_t ss_index_next_directory(SSScan *scan, uint32_t *cursor, char *name, size_t capacity) {
    read_lock(scan);
    uint32_t id = *cursor;
    while (id != SSNoItem && scan->items[id].kind != SSDirectory) id = scan->items[id].next_sibling;
    if (id != SSNoItem) {
        const SSItem *item = &scan->items[id];
        *cursor = item->next_sibling;
        if (item->name_length < capacity) {
            memcpy(name, scan->names + item->name_offset, item->name_length + 1);
        } else {
            name[0] = '\0';
        }
    } else {
        *cursor = SSNoItem;
    }
    unlock(scan);
    return id;
}

size_t ss_copy_trail(SSScan *scan, uint32_t id, uint32_t *output, size_t capacity) {
    size_t count = 0;
    read_lock(scan);
    for (uint32_t current = id; current != SSNoItem; current = scan->items[current].parent) {
        if (count < capacity) output[count] = current;
        count++;
    }
    unlock(scan);
    if (count <= capacity) {
        for (size_t index = 0; index < count / 2; index++) {
            uint32_t item = output[index];
            output[index] = output[count - 1 - index];
            output[count - 1 - index] = item;
        }
    }
    return count;
}

void ss_index_set_root(SSScan *scan, const struct stat *attributes) {
    write_lock(scan);
    scan->root_attributes = *attributes;
    scan->has_root = true;
    unlock(scan);
}

bool ss_scan_root_matches(SSScan *scan, int fd) {
    struct stat current;
    if (fstat(fd, &current) != 0) return false;
    read_lock(scan);
    const struct stat original = scan->root_attributes;
    const bool has_root = scan->has_root;
    unlock(scan);
    return has_root && current.st_dev == original.st_dev && current.st_ino == original.st_ino &&
           current.st_birthtimespec.tv_sec == original.st_birthtimespec.tv_sec &&
           current.st_birthtimespec.tv_nsec == original.st_birthtimespec.tv_nsec;
}

static bool is_attached(const SSScan *scan, uint32_t id) {
    if (id >= scan->item_count) return false;
    for (uint32_t item = id; item != SSNoItem; item = scan->items[item].parent) {
        if (scan->items[item].flags & detached) return false;
    }
    return true;
}

bool ss_item_is_attached(SSScan *scan, uint32_t id) {
    read_lock(scan);
    bool attached = is_attached(scan, id);
    unlock(scan);
    return attached;
}

bool ss_item_matches(SSScan *scan, uint32_t id, const struct stat *attributes) {
    read_lock(scan);
    bool matches = false;
    if (is_attached(scan, id)) {
        SSFileIdentity identity = scan->identities[id];
        mode_t type = attributes->st_mode & S_IFMT;
        SSKind kind = scan->items[id].kind;
        matches = identity.inode && identity.inode == attributes->st_ino &&
                  identity.device == attributes->st_dev &&
                  identity.birth_seconds == attributes->st_birthtimespec.tv_sec &&
                  identity.birth_nanoseconds == attributes->st_birthtimespec.tv_nsec &&
                  ((kind == SSFile && type == S_IFREG) || (kind == SSDirectory && type == S_IFDIR) ||
                   (kind == SSSymbolicLink && type == S_IFLNK));
    }
    unlock(scan);
    return matches;
}

static void detach_branch(SSItem *items, uint32_t id) {
    SSItem *removed = &items[id];
    uint32_t *link = &items[removed->parent].first_child;
    while (*link != id) link = &items[*link].next_sibling;
    *link = removed->next_sibling;
    for (uint32_t ancestor = removed->parent; ancestor != SSNoItem; ancestor = items[ancestor].parent) {
        items[ancestor].allocated -= removed->allocated;
        items[ancestor].descendants -= 1 + removed->descendants;
    }
    // Keep ancestry for existing view references, but exclude the whole branch
    // from queries and subsequent file operations.
    removed->flags |= detached;
    removed->next_sibling = SSNoItem;
}

bool ss_forget_removed_item(SSScan *scan, uint32_t id) {
    if (id == 0 || !atomic_load_explicit(&scan->finished, memory_order_acquire)) return false;
    write_lock(scan);
    bool can_detach = is_attached(scan, id) && !(scan->items[id].flags & has_hard_links);
    if (can_detach) detach_branch(scan->items, id);
    unlock(scan);
    return can_detach;
}

static bool lower_priority(const SSItem *items, uint32_t left, uint32_t right) {
    if (items[left].allocated != items[right].allocated) return items[left].allocated < items[right].allocated;
    return left > right;
}

static void sift_down(const SSItem *items, uint32_t *heap, size_t length, size_t index) {
    uint32_t value = heap[index];
    for (size_t child = 2 * index + 1; child < length; child = 2 * index + 1) {
        if (child + 1 < length && lower_priority(items, heap[child + 1], heap[child])) child++;
        if (!lower_priority(items, heap[child], value)) break;
        heap[index] = heap[child];
        index = child;
    }
    heap[index] = value;
}

// A min-heap keeps only the requested page, even for a full scan.
static size_t offer_ranked_item(const SSItem *items, uint32_t *heap, size_t capacity, size_t count, uint32_t id) {
    if (count == capacity) {
        if (count > 0 && lower_priority(items, heap[0], id)) {
            heap[0] = id;
            sift_down(items, heap, count, 0);
        }
        return count;
    }

    size_t index = count;
    while (index > 0 && lower_priority(items, id, heap[(index - 1) / 2])) {
        heap[index] = heap[(index - 1) / 2];
        index = (index - 1) / 2;
    }
    heap[index] = id;
    return count + 1;
}

static void sort_ranked_items(const SSItem *items, uint32_t *heap, size_t count) {
    for (size_t end = count; end > 1; ) {
        uint32_t lowest = heap[0];
        heap[0] = heap[--end];
        heap[end] = lowest;
        sift_down(items, heap, end, 0);
    }
}

static uint32_t next_ranked_item(const SSItem *items, uint32_t folder, uint32_t id, bool recursive) {
    if (recursive && items[id].first_child != SSNoItem) return items[id].first_child;
    // Stop at the requested folder when backtracking through a subtree.
    while (items[id].next_sibling == SSNoItem && items[id].parent != folder) id = items[id].parent;
    return items[id].next_sibling;
}

static size_t collect_ranked_items(const SSItem *items, uint32_t folder, SSRanking mode,
                                  uint32_t *output, size_t capacity, const SSControl *control) {
    const bool recursive = mode == SSBiggestFiles;
    size_t matches = 0, heap_count = 0, visited = 0;
    for (uint32_t id = items[folder].first_child; id != SSNoItem;
         id = next_ranked_item(items, folder, id, recursive)) {
        if ((visited++ & 1023) == 0 && ss_is_cancelled(control)) break;
        if (mode == SSContents || (mode == SSFolders && items[id].kind == SSDirectory) ||
            (recursive && items[id].kind == SSFile)) {
            matches++;
            heap_count = offer_ranked_item(items, output, capacity, heap_count, id);
        }
    }
    sort_ranked_items(items, output, heap_count);
    return matches;
}

size_t ss_rank(SSScan *scan, uint32_t folder, SSRanking mode,
               uint32_t *output, size_t capacity, const SSControl *control) {
    read_lock(scan);
    size_t matches = is_attached(scan, folder)
        ? collect_ranked_items(scan->items, folder, mode, output, capacity, control)
        : 0;
    unlock(scan);
    return matches;
}

static bool matches_filename(const char *name, const char *query, CFStringRef unicode_query) {
    if (strcasestr(name, query)) return true;
    for (const unsigned char *byte = (const unsigned char *)name; *byte; byte++) {
        if (*byte < 128) continue;
        CFStringRef unicode_name = CFStringCreateWithCString(NULL, name, kCFStringEncodingUTF8);
        if (!unicode_name) return false;
        bool matches = CFStringFind(unicode_name, unicode_query,
                                    kCFCompareCaseInsensitive | kCFCompareNonliteral).location != kCFNotFound;
        CFRelease(unicode_name);
        return matches;
    }
    return false;
}

static bool search_batch(SSScan *scan, const char *query, CFStringRef unicode_query,
                         SSSearchResult *result, uint32_t *output, size_t capacity) {
    read_lock(scan);
    // Load completion before inspecting the index so a final batch cannot be missed.
    bool finished = atomic_load_explicit(&scan->finished, memory_order_acquire);
    size_t end = (size_t)result->next + 1024;
    if (end > scan->item_count) end = scan->item_count;
    while (result->next < end && result->count < capacity) {
        uint32_t id = result->next++;
        const char *name = scan->names + scan->items[id].name_offset;
        if (matches_filename(name, query, unicode_query) && is_attached(scan, id)) {
            output[result->count++] = id;
        }
    }
    bool caught_up = result->next >= scan->item_count;
    result->complete = finished && caught_up;
    unlock(scan);
    return caught_up;
}

SSSearchResult ss_search(SSScan *scan, const char *query, uint32_t start,
                         uint32_t *output, size_t capacity, const SSControl *control) {
    SSSearchResult result = {.next = start > 0 ? start : 1};
    if (!*query || !capacity) return result;
    CFStringRef unicode_query = CFStringCreateWithCString(NULL, query, kCFStringEncodingUTF8);
    if (!unicode_query) return result;
    while (result.count < capacity && !ss_is_cancelled(control)) {
        if (search_batch(scan, query, unicode_query, &result, output, capacity)) break;
    }
    CFRelease(unicode_query);
    return result;
}
