/*
 * xios_output_queue.h — platform-neutral output-buffer ownership scheduler.
 *
 * The IOSurface and socket layers provide storage and transport. This helper
 * owns the part that must remain deterministic under load: round-robin
 * acquisition, consumer ownership, release-fence handoff, and EGL-style age.
 *
 * Header-only so every xios_surface consumer (iosc, Xorg, Mutter glue) gets the
 * same policy without adding another package/link dependency. The host unit
 * test includes this file directly and needs no Apple frameworks.
 */
#ifndef XIOS_OUTPUT_QUEUE_H
#define XIOS_OUTPUT_QUEUE_H

#include <limits.h>
#include <stdint.h>
#include <string.h>

#define XIOS_OUTPUT_QUEUE_MAX_BUFFERS 3

struct xios_output_queue_slot {
    int acquired;
    int abandoned;
    uint32_t pending_clients;
    uint64_t release_wait_value;
    uint64_t last_frame;
    uint64_t last_seq;
};

struct xios_output_queue {
    struct xios_output_queue_slot slots[XIOS_OUTPUT_QUEUE_MAX_BUFFERS];
    unsigned count;
    unsigned cursor;
    uint64_t frame;
};

static inline int
xios_output_queue_reset(struct xios_output_queue *queue, unsigned count)
{
    if (!queue || count > XIOS_OUTPUT_QUEUE_MAX_BUFFERS)
        return 0;
    memset(queue, 0, sizeof(*queue));
    queue->count = count;
    return 1;
}

/*
 * `rotate` is true only with a stream-v2 consumer. Legacy consumers know only
 * primary surface id 1, so they must remain on slot zero even when the producer
 * preallocated a larger queue.
 */
static inline int
xios_output_queue_acquire(struct xios_output_queue *queue, int rotate,
                          unsigned *index, unsigned *age,
                          uint64_t *release_wait_value)
{
    if (index)
        *index = 0;
    if (age)
        *age = 0;
    if (release_wait_value)
        *release_wait_value = 0;
    if (!queue || queue->count == 0 ||
        queue->count > XIOS_OUTPUT_QUEUE_MAX_BUFFERS)
        return 0;

    unsigned count = rotate ? queue->count : 1;
    for (unsigned n = 0; n < count; n++) {
        unsigned i = rotate ? (queue->cursor + n) % count : 0;
        struct xios_output_queue_slot *slot = &queue->slots[i];
        if (slot->acquired || slot->abandoned || slot->pending_clients)
            continue;

        slot->acquired = 1;
        queue->cursor = (i + 1) % count;
        if (index)
            *index = i;
        if (age && slot->last_frame != 0 &&
            queue->frame >= slot->last_frame) {
            uint64_t delta = queue->frame - slot->last_frame + 1;
            *age = delta > UINT_MAX ? UINT_MAX : (unsigned)delta;
        }
        if (release_wait_value)
            *release_wait_value = slot->release_wait_value;
        slot->release_wait_value = 0;
        return 1;
    }
    return 0;
}

static inline void
xios_output_queue_cancel(struct xios_output_queue *queue, unsigned index)
{
    if (queue && index < queue->count)
        queue->slots[index].acquired = 0;
}

/*
 * Publish transfers ownership to the successfully-notified v2 consumers.
 * A zero pending mask deliberately supports fixed one-buffer producers that
 * use surface-addressed framing but do not advertise a release timeline.
 */
static inline void
xios_output_queue_publish(struct xios_output_queue *queue, unsigned index,
                          uint32_t pending_clients, uint64_t seq)
{
    if (!queue || index >= queue->count)
        return;
    struct xios_output_queue_slot *slot = &queue->slots[index];
    slot->acquired = 0;
    slot->abandoned = 0;
    slot->pending_clients = pending_clients;
    slot->last_seq = seq;
    slot->last_frame = ++queue->frame;
}

/*
 * Accept only the exact generation still owned by this consumer. A late release
 * for a previous use of the same allocation must never unlock its current use.
 */
static inline int
xios_output_queue_release(struct xios_output_queue *queue, unsigned index,
                          uint32_t client_bit, uint64_t seq)
{
    if (!queue || index >= queue->count || client_bit == 0 || seq == 0)
        return 0;
    struct xios_output_queue_slot *slot = &queue->slots[index];
    if (!(slot->pending_clients & client_bit) || slot->last_seq != seq)
        return 0;
    slot->pending_clients &= ~client_bit;
    if (seq > slot->release_wait_value)
        slot->release_wait_value = seq;
    return 1;
}

static inline void
xios_output_queue_drop_client(struct xios_output_queue *queue,
                              uint32_t client_bit)
{
    if (!queue || client_bit == 0)
        return;
    for (unsigned i = 0; i < queue->count; i++) {
        struct xios_output_queue_slot *slot = &queue->slots[i];
        if (slot->pending_clients & client_bit)
            slot->abandoned = 1;
        slot->pending_clients &= ~client_bit;
    }
}

/*
 * A dropped socket is not a GPU release: the old app may still be sampling the
 * IOSurface while it notices EOF and tears its Metal texture down. Keep those
 * allocations quarantined until a subsequent successful app handshake proves
 * that the old consumer has completed teardown (or its process is gone).
 */
static inline void
xios_output_queue_recover_abandoned(struct xios_output_queue *queue)
{
    if (!queue)
        return;
    for (unsigned i = 0; i < queue->count; i++)
        queue->slots[i].abandoned = 0;
}

#endif
