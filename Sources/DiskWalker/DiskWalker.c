#include "DiskWalkerInternal.h"
#include "DirectoryQueue.h"

#include <errno.h>
#include <fcntl.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <sys/attr.h>
#include <sys/param.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/vnode.h>
#include <unistd.h>
#include <dirent.h>

struct SSControl {
    atomic_bool cancelled;
    _Atomic uint64_t visited;
    _Atomic uint64_t skipped;
};

typedef struct {
    ino_t inode;
    dev_t device;
} FileIdentity;

typedef struct {
    pthread_mutex_t lock;
    FileIdentity *entries;
    size_t count;
    size_t capacity;
} HardLinks;

typedef struct {
    SSScan *scan;
    SSControl *control;
    DirectoryQueue *queue;
    HardLinks links;
    struct stat root;
    struct stat startup_data;
    bool has_startup_data;
    bool use_bulk;
} WalkContext;

typedef struct {
    WalkContext *context;
    unsigned char *buffer;
    SSEntry *batch;
    char child_name[MAXPATHLEN];
    SSProgress progress;
    SSProgress published;
} Walker;

enum {
    buffer_size = 64 * 1024,
    batch_capacity = buffer_size / (sizeof(uint32_t) + sizeof(attribute_set_t)),
    posix_batch_capacity = 128,
    bulk_identity_attributes = ATTR_CMN_DEVID | ATTR_CMN_CRTIME | ATTR_CMN_FILEID,
    bulk_file_attributes = ATTR_FILE_LINKCOUNT | ATTR_FILE_ALLOCSIZE,
};
static const int directory_flags = O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW;

typedef struct {
    char names[posix_batch_capacity][sizeof(((struct dirent *)0)->d_name)];
    SSEntry entries[posix_batch_capacity];
    uint32_t count;
    bool has_hard_links;
} PosixBatch;

typedef enum {
    bulk_entry_ready,
    bulk_entry_skipped,
    bulk_entry_invalid,
} BulkEntryResult;

SSControl *ss_control_create(void) {
    SSControl *control = malloc(sizeof(*control));
    if (control) {
        atomic_init(&control->cancelled, false);
        atomic_init(&control->visited, 0);
        atomic_init(&control->skipped, 0);
    }
    return control;
}

void ss_control_destroy(SSControl *control) { free(control); }

void ss_cancel(SSControl *control) {
    atomic_store_explicit(&control->cancelled, true, memory_order_relaxed);
}

bool ss_is_cancelled(const SSControl *control) {
    return atomic_load_explicit(&control->cancelled, memory_order_relaxed);
}

SSProgress ss_progress(const SSControl *control) {
    return (SSProgress){
        atomic_load_explicit(&control->visited, memory_order_relaxed),
        atomic_load_explicit(&control->skipped, memory_order_relaxed),
    };
}

static void publish_progress(Walker *walker) {
    SSControl *control = walker->context->control;
    uint64_t visited = walker->progress.visited - walker->published.visited;
    uint64_t skipped = walker->progress.skipped - walker->published.skipped;
    if (visited) atomic_fetch_add_explicit(&control->visited, visited, memory_order_relaxed);
    if (skipped) atomic_fetch_add_explicit(&control->skipped, skipped, memory_order_relaxed);
    walker->published = walker->progress;
}

static bool walk_stopped(const WalkContext *context) {
    return ss_is_cancelled(context->control) ||
           (context->queue && atomic_load_explicit(&context->queue->error, memory_order_relaxed));
}

static bool record_visit(Walker *walker) {
    if ((++walker->progress.visited & 1023) != 0) return true;
    return !walk_stopped(walker->context);
}

static bool fatal_error(int error) {
    return error == ECANCELED || error == ENOMEM || error == EOVERFLOW;
}

// Directory enumeration can ask a File Provider to download cloud-only items.
// Keep the scan local and let unavailable descendants use the normal skip path.
static int disable_materialization(void) {
    int previous = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD);
    if (previous < 0 || previous == IOPOL_MATERIALIZE_DATALESS_FILES_OFF) return -1;
    return setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD,
                          IOPOL_MATERIALIZE_DATALESS_FILES_OFF) == 0 ? previous : -1;
}

static void restore_materialization(int previous) {
    if (previous >= 0) {
        setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, previous);
    }
}

static size_t link_slot(const FileIdentity *links, size_t capacity, FileIdentity identity) {
    uint64_t hash = identity.inode ^ ((uint64_t)(uint32_t)identity.device << 32);
    hash ^= hash >> 33;
    hash *= UINT64_C(0xff51afd7ed558ccd);
    hash ^= hash >> 33;
    size_t slot = hash & (capacity - 1);
    while (links[slot].inode &&
           (links[slot].inode != identity.inode || links[slot].device != identity.device)) {
        slot = (slot + 1) & (capacity - 1);
    }
    return slot;
}

static int grow_link_table(HardLinks *links) {
    size_t capacity = links->capacity ? links->capacity * 2 : 128;
    FileIdentity *entries = calloc(capacity, sizeof(*entries));
    if (!entries) return ENOMEM;

    for (size_t i = 0; i < links->capacity; ++i) {
        FileIdentity link = links->entries[i];
        if (link.inode) entries[link_slot(entries, capacity, link)] = link;
    }
    free(links->entries);
    links->entries = entries;
    links->capacity = capacity;
    return 0;
}

static int account_hard_link(HardLinks *links, SSEntry *entry) {
    if (entry->kind != SSFile || entry->link_count <= 1 || !entry->identity.inode || !entry->allocated) return 0;
    if (links->count * 2 >= links->capacity) {
        int error = grow_link_table(links);
        if (error) return error;
    }

    FileIdentity identity = {entry->identity.inode, entry->identity.device};
    size_t slot = link_slot(links->entries, links->capacity, identity);
    if (links->entries[slot].inode) {
        entry->allocated = 0;
    } else {
        links->entries[slot] = identity;
        links->count++;
    }
    return 0;
}

static int commit_entries(Walker *walker, uint32_t folder,
                          SSEntry *entries, uint32_t count, bool has_hard_links) {
    WalkContext *context = walker->context;
    if (!has_hard_links) return ss_index_append_batch(context->scan, folder, entries, count);

    // Every worker shares this table. Keep its lock separate from the live index.
    uint32_t ready = 0;
    int error = 0;
    pthread_mutex_lock(&context->links.lock);
    for (; ready < count; ready++) {
        error = account_hard_link(&context->links, &entries[ready]);
        if (error) break;
    }
    pthread_mutex_unlock(&context->links.lock);
    int commit_error = ss_index_append_batch(context->scan, folder, entries, ready);
    return commit_error ? commit_error : error;
}

static bool read_stat(int fd, SSEntry *entry) {
    struct stat attributes;
    if (fstatat(fd, entry->name, &attributes, AT_SYMLINK_NOFOLLOW) == -1) return false;
    entry->identity = (SSFileIdentity){
        .inode = attributes.st_ino,
        .birth_seconds = attributes.st_birthtimespec.tv_sec,
        .birth_nanoseconds = (int32_t)attributes.st_birthtimespec.tv_nsec,
        .device = attributes.st_dev,
    };
    if (S_ISREG(attributes.st_mode)) {
        entry->kind = SSFile;
        entry->allocated = attributes.st_blocks > 0 ? (uint64_t)attributes.st_blocks * 512 : 0;
        entry->link_count = attributes.st_nlink;
    } else if (S_ISDIR(attributes.st_mode)) {
        entry->kind = SSDirectory;
    } else if (S_ISLNK(attributes.st_mode)) {
        entry->kind = SSSymbolicLink;
    } else {
        entry->kind = SSOther;
    }
    return true;
}

static DIR *open_directory_stream(int fd) {
    // Open a fresh descriptor because mixing bulk and POSIX offsets is undefined.
    int stream_fd = openat(fd, ".", directory_flags);
    if (stream_fd == -1) return NULL;
    DIR *directory = fdopendir(stream_fd);
    if (!directory) {
        int error = errno;
        close(stream_fd);
        errno = error;
    }
    return directory;
}

// A short batch with no error means readdir reached the end of the stream.
static int fill_posix_batch(Walker *walker, int fd, DIR *directory, PosixBatch *batch) {
    batch->count = 0;
    batch->has_hard_links = false;
    while (batch->count < posix_batch_capacity) {
        errno = 0;
        struct dirent *item = readdir(directory);
        if (!item) return errno;
        if (strcmp(item->d_name, ".") == 0 || strcmp(item->d_name, "..") == 0) continue;
        if (!record_visit(walker)) return ECANCELED;
        SSEntry entry = {.name = item->d_name, .name_length = item->d_namlen};
        if (!read_stat(fd, &entry)) {
            walker->progress.skipped++;
            continue;
        }
        // readdir owns d_name and can overwrite it on the next call.
        memcpy(batch->names[batch->count], item->d_name, entry.name_length + 1);
        entry.name = batch->names[batch->count];
        batch->entries[batch->count++] = entry;
        batch->has_hard_links |= entry.link_count > 1;
    }
    return 0;
}

static int read_posix(Walker *walker, int fd, uint32_t folder) {
    DIR *directory = open_directory_stream(fd);
    if (!directory) return errno;

    PosixBatch batch;
    int error;
    do {
        if (walk_stopped(walker->context)) {
            error = ECANCELED;
            break;
        }
        error = fill_posix_batch(walker, fd, directory, &batch);
        if (!fatal_error(error) && batch.count) {
            int commit_error = commit_entries(walker, folder, batch.entries,
                                              batch.count, batch.has_hard_links);
            if (commit_error) error = commit_error;
        }
        publish_progress(walker);
    } while (!error && batch.count == posix_batch_capacity);

    closedir(directory);
    return error;
}

static bool read_field(const unsigned char **field, const unsigned char *end, void *value, size_t size) {
    if ((size_t)(end - *field) < size) return false;
    memcpy(value, *field, size);
    *field += size;
    return true;
}

static const unsigned char *next_bulk_record(const unsigned char *buffer, size_t *offset, uint32_t *length) {
    if (*offset > buffer_size - sizeof(*length)) return NULL;
    const unsigned char *start = buffer + *offset;
    memcpy(length, start, sizeof(*length));
    if (*length < sizeof(*length) + sizeof(attribute_set_t) || *length > buffer_size - *offset) return NULL;
    *offset += *length;
    return start;
}

static bool decode_bulk_name(const unsigned char *start, const unsigned char *end,
                             const unsigned char **field, SSEntry *entry) {
    attrreference_t name;
    int64_t name_offset = *field - start;
    if (!read_field(field, end, &name, sizeof(name))) return false;

    name_offset += name.attr_dataoffset;
    int64_t length = end - start;
    if (name_offset < *field - start || name_offset >= length || !name.attr_length ||
        name.attr_length > length - name_offset || start[name_offset + name.attr_length - 1] != '\0') {
        return false;
    }

    *entry = (SSEntry){.name = (const char *)start + name_offset, .name_length = name.attr_length - 1};
    return true;
}

static BulkEntryResult decode_bulk_attributes(int fd, const unsigned char *field, const unsigned char *end,
                                              attribute_set_t returned, SSEntry *entry) {
    if ((returned.commonattr & bulk_identity_attributes) != bulk_identity_attributes) {
        return read_stat(fd, entry) ? bulk_entry_ready : bulk_entry_skipped;
    }
    dev_t device;
    fsobj_type_t type = VNON;
    struct timespec birth;
    uint64_t inode;
    if (!read_field(&field, end, &device, sizeof(device)) ||
        ((returned.commonattr & ATTR_CMN_OBJTYPE) && !read_field(&field, end, &type, sizeof(type))) ||
        !read_field(&field, end, &birth, sizeof(birth)) || !read_field(&field, end, &inode, sizeof(inode))) {
        return bulk_entry_invalid;
    }
    if (!inode || type == VNON || (type == VREG && (returned.fileattr & bulk_file_attributes) != bulk_file_attributes)) {
        return read_stat(fd, entry) ? bulk_entry_ready : bulk_entry_skipped;
    }
    entry->identity = (SSFileIdentity){
        .inode = inode,
        .birth_seconds = birth.tv_sec,
        .birth_nanoseconds = (int32_t)birth.tv_nsec,
        .device = device,
    };
    if (type != VREG) {
        entry->kind = type == VDIR ? SSDirectory : type == VLNK ? SSSymbolicLink : SSOther;
        return bulk_entry_ready;
    }

    int64_t allocated;
    if (!read_field(&field, end, &entry->link_count, sizeof(entry->link_count)) ||
        !read_field(&field, end, &allocated, sizeof(allocated))) return bulk_entry_invalid;

    entry->kind = SSFile;
    entry->allocated = allocated > 0 ? (uint64_t)allocated : 0;
    return bulk_entry_ready;
}

static BulkEntryResult decode_bulk_entry(int fd, const unsigned char *start, uint32_t length, SSEntry *entry) {
    // Decode only returned attributes. read_field uses memcpy for Darwin's
    // 4-byte alignment, which can leave 64-bit fields unaligned.
    const unsigned char *field = start + sizeof(length);
    const unsigned char *end = start + length;
    attribute_set_t returned;
    if (!read_field(&field, end, &returned, sizeof(returned))) return bulk_entry_invalid;
    if (returned.commonattr & ATTR_CMN_ERROR) {
        uint32_t error;
        if (!read_field(&field, end, &error, sizeof(error))) return bulk_entry_invalid;
        if (error) return bulk_entry_skipped;
    }
    if (!(returned.commonattr & ATTR_CMN_NAME) || !decode_bulk_name(start, end, &field, entry)) {
        return bulk_entry_invalid;
    }
    return decode_bulk_attributes(fd, field, end, returned, entry);
}

static int commit_bulk_batch(Walker *walker, int fd, uint32_t folder, int count) {
    size_t offset = 0;
    uint32_t batch_count = 0;
    bool has_hard_links = false;
    for (int i = 0; i < count; ++i) {
        uint32_t length;
        const unsigned char *record = next_bulk_record(walker->buffer, &offset, &length);
        if (!record) return EIO;
        if (!record_visit(walker)) return ECANCELED;

        SSEntry *entry = &walker->batch[batch_count];
        BulkEntryResult result = decode_bulk_entry(fd, record, length, entry);
        if (result == bulk_entry_invalid) return EIO;
        if (result == bulk_entry_skipped) {
            walker->progress.skipped++;
            continue;
        }
        batch_count++;
        has_hard_links |= entry->link_count > 1;
    }
    int error = commit_entries(walker, folder, walker->batch, batch_count, has_hard_links);
    publish_progress(walker);
    return error;
}

static int read_bulk(Walker *walker, int fd, uint32_t folder) {
    struct attrlist request = {
        .bitmapcount = ATTR_BIT_MAP_COUNT,
        .commonattr = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_ERROR | ATTR_CMN_NAME |
                      ATTR_CMN_OBJTYPE | bulk_identity_attributes,
        .fileattr = bulk_file_attributes,
    };
    bool first_batch = true;
    for (;;) {
        if (walk_stopped(walker->context)) return ECANCELED;
        int count = getattrlistbulk(fd, &request, walker->buffer, buffer_size, 0);
        if (count == 0) return 0;
        if (count < 0) {
            int error = errno;
            if (error == EINTR) continue;
            if (first_batch && (error == ENOTSUP || error == EINVAL || error == ENOSYS)) {
                return read_posix(walker, fd, folder);
            }
            return error;
        }
        first_batch = false;

        int error = commit_bulk_batch(walker, fd, folder, count);
        if (error) return error;
    }
}

static bool same_identity(struct stat a, struct stat b) {
    return a.st_dev == b.st_dev && a.st_ino == b.st_ino;
}

static bool can_traverse(const WalkContext *context, struct stat attributes) {
    if (context->has_startup_data && same_identity(attributes, context->startup_data)) return false;
    return attributes.st_dev == context->root.st_dev ||
           (context->has_startup_data && attributes.st_dev == context->startup_data.st_dev);
}

static bool open_child_job(Walker *walker, int fd, uint32_t folder, DirectoryJob *job) {
    int child_fd = openat(fd, walker->child_name, directory_flags);
    struct stat attributes;
    if (child_fd != -1 && fstat(child_fd, &attributes) == 0 && can_traverse(walker->context, attributes)) {
        *job = (DirectoryJob){.fd = child_fd, .folder = folder};
        return true;
    }
    if (child_fd != -1) close(child_fd);
    walker->progress.skipped++;
    return false;
}

static int walk_folder(Walker *walker, DirectoryJob job);

static int walk_children(Walker *walker, DirectoryJob parent) {
    WalkContext *context = walker->context;
    uint32_t cursor = ss_item(context->scan, parent.folder).first_child;
    while (cursor != SSNoItem) {
        if (walk_stopped(context)) return ECANCELED;
        uint32_t child = ss_index_next_directory(context->scan, &cursor, walker->child_name,
                                                 sizeof(walker->child_name));
        if (child == SSNoItem) break;

        DirectoryJob job;
        if (!open_child_job(walker, parent.fd, child, &job)) continue;
        if (context->queue && directory_queue_offer(context->queue, job)) continue;
        int error = walk_folder(walker, job);
        close(job.fd);
        if (error) return error;
    }
    return 0;
}

static int walk_folder(Walker *walker, DirectoryJob job) {
    if (walk_stopped(walker->context)) return ECANCELED;
    int error = walker->context->use_bulk
        ? read_bulk(walker, job.fd, job.folder)
        : read_posix(walker, job.fd, job.folder);
    if (error && (job.folder == 0 || fatal_error(error))) return error;
    if (error) walker->progress.skipped++;
    return walk_children(walker, job);
}

static void configure_startup_data(WalkContext *context, const char *path) {
    // At the startup root, include Data-volume firmlinks but skip the Data
    // mount itself, where the same trees would otherwise be counted twice.
    if (strcmp(path, "/") == 0) {
        context->has_startup_data = stat("/System/Volumes/Data", &context->startup_data) == 0 &&
                                    !same_identity(context->root, context->startup_data);
    }
}

static void run_worker(Walker *walker) {
    DirectoryQueue *queue = walker->context->queue;
    DirectoryJob job;
    while (directory_queue_take(queue, &job)) {
        int error = walk_folder(walker, job);
        if (job.folder != 0) close(job.fd);
        publish_progress(walker);
        directory_queue_finish(queue, error);
    }
}

static void *run_scan_thread(void *argument) {
    int previous = disable_materialization();
    run_worker(argument);
    restore_materialization(previous);
    return NULL;
}

static int run_parallel_walk(WalkContext *context, Walker *walkers, unsigned count, DirectoryJob root) {
    DirectoryQueue queue;
    if (directory_queue_init(&queue, context->control, root)) return walk_folder(&walkers[0], root);

    context->queue = &queue;
    pthread_t threads[SSMaxWorkerCount - 1];
    unsigned started = 0;
    while (started + 1 < count && !pthread_create(&threads[started], NULL, run_scan_thread, &walkers[started + 1])) {
        started++;
    }
    // The caller also walks directories. If thread creation fails, it drains
    // the same bounded queue with whatever workers were started successfully.
    run_worker(&walkers[0]);
    for (unsigned i = 0; i < started; i++) pthread_join(threads[i], NULL);

    int error = atomic_load_explicit(&queue.error, memory_order_relaxed);
    context->queue = NULL;
    directory_queue_destroy(&queue);
    return error;
}

static unsigned prepare_walkers(Walker *walkers, WalkContext *context, unsigned limit) {
    unsigned ready = 0;
    for (; ready < limit; ready++) {
        Walker *walker = &walkers[ready];
        *walker = (Walker){.context = context};
        if (!context->use_bulk) continue;
        walker->buffer = malloc(buffer_size);
        walker->batch = malloc(batch_capacity * sizeof(*walker->batch));
        if (!walker->buffer || !walker->batch) {
            free(walker->buffer);
            free(walker->batch);
            break;
        }
    }
    return ready;
}

static int walk_from_root(WalkContext *context, int fd, unsigned worker_count) {
    Walker walkers[SSMaxWorkerCount];
    unsigned ready = prepare_walkers(walkers, context, worker_count);
    if (!ready) return ENOMEM;

    DirectoryJob root = {.fd = fd, .folder = 0};
    int error = ready == 1 ? walk_folder(&walkers[0], root) : run_parallel_walk(context, walkers, ready, root);
    for (unsigned i = 0; i < ready; i++) {
        publish_progress(&walkers[i]);
        free(walkers[i].buffer);
        free(walkers[i].batch);
    }
    return error;
}

static int walk_scan(SSScan *scan, const char *path, SSControl *control, bool use_bulk, unsigned worker_count) {
    if (ss_is_cancelled(control)) return ECANCELED;
    int fd = open(path, directory_flags);
    if (fd == -1) return errno;
    WalkContext context = {.scan = scan, .control = control, .use_bulk = use_bulk};
    if (fstat(fd, &context.root) == -1) {
        int error = errno;
        close(fd);
        return error;
    }
    ss_index_set_root(scan, &context.root);
    configure_startup_data(&context, path);

    unsigned limit = worker_count == 0 ? 1 : worker_count > SSMaxWorkerCount ? SSMaxWorkerCount : worker_count;
    int error = pthread_mutex_init(&context.links.lock, NULL);
    if (!error) {
        error = walk_from_root(&context, fd, limit);
        pthread_mutex_destroy(&context.links.lock);
    }
    close(fd);
    free(context.links.entries);
    return error;
}

int ss_scan_walk_with_workers(SSScan *scan, const char *path, SSControl *control,
                              bool use_bulk, unsigned int worker_count) {
    if (atomic_exchange_explicit(&scan->started, true, memory_order_relaxed)) return EINVAL;
    int previous = disable_materialization();
    int error = walk_scan(scan, path, control, use_bulk, worker_count);
    restore_materialization(previous);
    atomic_store_explicit(&scan->finished, true, memory_order_release);
    return !error && ss_is_cancelled(control) ? ECANCELED : error;
}

int ss_scan_walk(SSScan *scan, const char *path, SSControl *control, bool use_bulk) {
    return ss_scan_walk_with_workers(scan, path, control, use_bulk, SSDefaultWorkerCount);
}
