#ifndef IOSC_RENDER_PLAN_H
#define IOSC_RENDER_PLAN_H

#define IOSC_MAX_OUTPUT_DAMAGE_RECTS 16

struct iosc_rect {
    int x0, y0, x1, y1;
};

struct iosc_render_plan {
    int had_damage;
    int damage_count;
    int damage_x0, damage_y0, damage_x1, damage_y1;
    struct iosc_rect damage[IOSC_MAX_OUTPUT_DAMAGE_RECTS];
};

typedef int (*iosc_render_plan_consume_damage_fn)(struct iosc_rect *rects,
                                                  int max_rects,
                                                  int *x0,
                                                  int *y0,
                                                  int *x1,
                                                  int *y1);

void iosc_render_plan_build(struct iosc_render_plan *plan,
                            int had_damage,
                            iosc_render_plan_consume_damage_fn consume_damage);

void iosc_render_plan_log(const struct iosc_render_plan *plan,
                          const char *reason,
                          int reason_line,
                          int output_width,
                          int output_height);

#endif
