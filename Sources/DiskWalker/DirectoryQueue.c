#include "DirectoryQueue.h"

#include <unistd.h>

int directory_queue_init(DirectoryQueue *queue, SSControl *control, DirectoryJob root) {
    int error = pthread_mutex_init(&queue->lock, NULL);
    if (error) return error;
    error = pthread_cond_init(&queue->ready, NULL);
    if (error) {
        pthread_mutex_destroy(&queue->lock);
        return error;
    }
    queue->control = control;
    queue->head = 0;
    queue->count = 1;
    queue->active = 0;
    queue->pending[0] = root;
    atomic_init(&queue->error, 0);
    return 0;
}

void directory_queue_destroy(DirectoryQueue *queue) {
    // All workers have joined. Only undispatched jobs from a stopped scan remain.
    for (size_t i = 0; i < queue->count; i++) {
        DirectoryJob job = queue->pending[(queue->head + i) % directory_queue_capacity];
        if (job.folder != 0) close(job.fd);
    }
    pthread_cond_destroy(&queue->ready);
    pthread_mutex_destroy(&queue->lock);
}

static bool stopped(const DirectoryQueue *queue) {
    return atomic_load_explicit(&queue->error, memory_order_relaxed) || ss_is_cancelled(queue->control);
}

bool directory_queue_offer(DirectoryQueue *queue, DirectoryJob job) {
    pthread_mutex_lock(&queue->lock);
    bool accepted = queue->count < directory_queue_capacity && !stopped(queue);
    if (accepted) {
        size_t tail = (queue->head + queue->count) % directory_queue_capacity;
        queue->pending[tail] = job;
        queue->count++;
        pthread_cond_signal(&queue->ready);
    }
    pthread_mutex_unlock(&queue->lock);
    return accepted;
}

bool directory_queue_take(DirectoryQueue *queue, DirectoryJob *job) {
    pthread_mutex_lock(&queue->lock);
    while (queue->count == 0 && queue->active && !stopped(queue)) {
        pthread_cond_wait(&queue->ready, &queue->lock);
    }
    bool available = queue->count > 0 && !stopped(queue);
    if (available) {
        *job = queue->pending[queue->head];
        queue->head = (queue->head + 1) % directory_queue_capacity;
        queue->count--;
        queue->active++;
    }
    pthread_mutex_unlock(&queue->lock);
    return available;
}

void directory_queue_finish(DirectoryQueue *queue, int error) {
    pthread_mutex_lock(&queue->lock);
    if (error && !atomic_load_explicit(&queue->error, memory_order_relaxed)) {
        atomic_store_explicit(&queue->error, error, memory_order_relaxed);
    }
    queue->active--;
    if (!queue->active || stopped(queue)) pthread_cond_broadcast(&queue->ready);
    pthread_mutex_unlock(&queue->lock);
}
