#include "iosc_render_plan.h"

#include <assert.h>
#include <stdio.h>

static int consume_calls;

static int consume_one(struct iosc_rect *rects, int max_rects,
                       int *x0, int *y0, int *x1, int *y1)
{
    consume_calls++;
    assert(max_rects >= 1);
    rects[0] = (struct iosc_rect) { 10, 20, 30, 40 };
    *x0 = 10;
    *y0 = 20;
    *x1 = 30;
    *y1 = 40;
    return 1;
}

int main(void)
{
    struct iosc_render_plan plan;

    iosc_render_plan_build(&plan, 0, consume_one);
    assert(consume_calls == 0);
    assert(plan.had_damage == 0);
    assert(plan.damage_count == 0);

    iosc_render_plan_build(&plan, 1, consume_one);
    assert(consume_calls == 1);
    assert(plan.had_damage == 1);
    assert(plan.damage_count == 1);
    assert(plan.damage[0].x0 == 10);
    assert(plan.damage[0].y0 == 20);
    assert(plan.damage[0].x1 == 30);
    assert(plan.damage[0].y1 == 40);

    puts("iosc render-plan tests passed");
    return 0;
}
