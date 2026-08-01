#include "xios_output_queue.h"

#include <assert.h>
#include <stdint.h>
#include <stdio.h>

static void assert_acquire(struct xios_output_queue *queue, int rotate,
                           unsigned want_index, unsigned want_age,
                           uint64_t want_wait)
{
    unsigned index = 99;
    unsigned age = 99;
    uint64_t wait = UINT64_MAX;
    assert(xios_output_queue_acquire(queue, rotate, &index, &age, &wait));
    assert(index == want_index);
    assert(age == want_age);
    assert(wait == want_wait);
}

int main(void)
{
    struct xios_output_queue queue;
    const uint32_t app = 1u << 2;

    assert(xios_output_queue_reset(&queue, 3));

    /* Legacy framing never exposes or rotates away from primary slot zero. */
    assert_acquire(&queue, 0, 0, 0, 0);
    xios_output_queue_publish(&queue, 0, 0, 1);
    assert_acquire(&queue, 0, 0, 1, 0);
    xios_output_queue_cancel(&queue, 0);

    /* Stream-v2 rotates through all three allocations without CPU waits. */
    assert(xios_output_queue_reset(&queue, 3));
    assert_acquire(&queue, 1, 0, 0, 0);
    xios_output_queue_publish(&queue, 0, app, 1);
    assert_acquire(&queue, 1, 1, 0, 0);
    xios_output_queue_publish(&queue, 1, app, 2);
    assert_acquire(&queue, 1, 2, 0, 0);
    xios_output_queue_publish(&queue, 2, app, 3);
    assert(!xios_output_queue_acquire(&queue, 1, NULL, NULL, NULL));

    /* Wrong allocation, client, and stale generation cannot free ownership. */
    assert(!xios_output_queue_release(&queue, 0, app, 3));
    assert(!xios_output_queue_release(&queue, 1, 1u << 1, 2));
    assert(!xios_output_queue_release(&queue, 1, app, 1));

    /* Exact release makes the slot reusable and transfers its GPU wait once. */
    assert(xios_output_queue_release(&queue, 0, app, 1));
    assert_acquire(&queue, 1, 0, 3, 1);
    xios_output_queue_publish(&queue, 0, app, 4);
    assert(xios_output_queue_release(&queue, 1, app, 2));
    assert_acquire(&queue, 1, 1, 3, 2);
    xios_output_queue_cancel(&queue, 1);
    assert_acquire(&queue, 1, 1, 3, 0);
    xios_output_queue_cancel(&queue, 1);

    /* Disconnect quarantines uncertain GPU ownership instead of fabricating a
     * release value or immediately reusing the allocation. */
    xios_output_queue_drop_client(&queue, app);
    assert_acquire(&queue, 1, 1, 3, 0);
    xios_output_queue_cancel(&queue, 1);
    assert(!xios_output_queue_release(&queue, 2, app, 3));
    xios_output_queue_recover_abandoned(&queue);
    assert_acquire(&queue, 1, 2, 2, 0);
    xios_output_queue_cancel(&queue, 2);

    /* One-buffer stream-v2 producer with no release token never parks. */
    assert(xios_output_queue_reset(&queue, 1));
    assert_acquire(&queue, 1, 0, 0, 0);
    xios_output_queue_publish(&queue, 0, 0, 10);
    assert_acquire(&queue, 1, 0, 1, 0);

    puts("xios output-queue tests passed");
    return 0;
}
