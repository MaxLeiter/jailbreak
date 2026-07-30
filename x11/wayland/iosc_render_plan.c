#include "iosc_render_plan.h"
#include "iosc_util.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

void iosc_render_plan_build(struct iosc_render_plan *plan,
                            int had_damage,
                            iosc_render_plan_consume_damage_fn consume_damage)
{
    memset(plan, 0, sizeof(*plan));
    plan->had_damage = had_damage;
    if (!had_damage)
        return;
    plan->damage_count = consume_damage(plan->damage, IOSC_MAX_OUTPUT_DAMAGE_RECTS,
                                        &plan->damage_x0, &plan->damage_y0,
                                        &plan->damage_x1, &plan->damage_y1);
}

void iosc_render_plan_log(const struct iosc_render_plan *plan,
                          const char *reason,
                          int reason_line,
                          int output_width,
                          int output_height)
{
    if (iosc_env_truthy(getenv("IOSC_DAMAGE_REASON")))
        fprintf(stderr, "iosc: recompose-reason %s:%d damage=%s\n",
                reason ? reason : "sync",
                reason_line,
                plan->had_damage ? "pending" : "none");
    if (!iosc_env_truthy(getenv("IOSC_DAMAGE_STATS")))
        return;
    if (!plan->had_damage) {
        fprintf(stderr, "iosc: output-damage rects=0 skipped\n");
        return;
    }
    fprintf(stderr, "iosc: output-damage rects=%d union=%d,%d %dx%d%s\n",
            plan->damage_count,
            plan->damage_x0, plan->damage_y0,
            plan->damage_x1 - plan->damage_x0,
            plan->damage_y1 - plan->damage_y0,
            (plan->damage_x0 == 0 && plan->damage_y0 == 0 &&
             plan->damage_x1 == output_width && plan->damage_y1 == output_height) ? " full" : "");
    if (plan->damage_count > 1) {
        for (int i = 0; i < plan->damage_count; i++)
            fprintf(stderr, "iosc: output-damage-rect %d %d,%d %dx%d\n",
                    i,
                    plan->damage[i].x0, plan->damage[i].y0,
                    plan->damage[i].x1 - plan->damage[i].x0,
                    plan->damage[i].y1 - plan->damage[i].y0);
    }
}
