#ifndef DirectoryQueue_h
#define DirectoryQueue_h

#include "DiskWalker.h"
#include <pthread.h>
#include <stdatomic.h>

typedef struct {
    int fd;
    uint32_t folder;
} DirectoryJob;

enum { directory_queue_capacity = 32 };

// A queued child owns its descriptor. If the queue fills, the producer walks
// the child locally instead of waiting for capacity. The caller owns the root.
typedef struct {
    pthread_mutex_t lock;
    pthread_cond_t ready;
    SSControl *control;
    DirectoryJob pending[directory_queue_capacity];
    size_t head;
    size_t count;
    size_t active;
    atomic_int error;
} DirectoryQueue;

int directory_queue_init(DirectoryQueue *queue, SSControl *control, DirectoryJob root);
void directory_queue_destroy(DirectoryQueue *queue);
bool directory_queue_offer(DirectoryQueue *queue, DirectoryJob job);
bool directory_queue_take(DirectoryQueue *queue, DirectoryJob *job);
void directory_queue_finish(DirectoryQueue *queue, int error);

#endif
