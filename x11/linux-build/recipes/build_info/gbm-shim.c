#include <stddef.h>
#include <stdint.h>

struct gbm_device {
    int fd;
};
struct gbm_bo {
    uint32_t width;
    uint32_t height;
    uint32_t format;
    uint32_t stride;
    uint64_t modifier;
};

struct gbm_device *gbm_create_device(int fd) { (void)fd; return NULL; }
void gbm_device_destroy(struct gbm_device *gbm) { (void)gbm; }
int gbm_device_get_fd(struct gbm_device *gbm) { (void)gbm; return -1; }
struct gbm_bo *gbm_bo_create(struct gbm_device *gbm, uint32_t width, uint32_t height, uint32_t format, uint32_t flags) { (void)gbm; (void)width; (void)height; (void)format; (void)flags; return NULL; }
struct gbm_bo *gbm_bo_create_with_modifiers(struct gbm_device *gbm, uint32_t width, uint32_t height, uint32_t format, const uint64_t *modifiers, const unsigned int count) { (void)gbm; (void)width; (void)height; (void)format; (void)modifiers; (void)count; return NULL; }
void gbm_bo_destroy(struct gbm_bo *bo) { (void)bo; }
uint32_t gbm_bo_get_width(struct gbm_bo *bo) { return bo ? bo->width : 0; }
uint32_t gbm_bo_get_height(struct gbm_bo *bo) { return bo ? bo->height : 0; }
uint32_t gbm_bo_get_format(struct gbm_bo *bo) { return bo ? bo->format : 0; }
uint64_t gbm_bo_get_modifier(struct gbm_bo *bo) { return bo ? bo->modifier : 0; }
int gbm_bo_get_fd(struct gbm_bo *bo) { (void)bo; return -1; }
int gbm_bo_get_plane_count(struct gbm_bo *bo) { (void)bo; return 0; }
uint32_t gbm_bo_get_stride_for_plane(struct gbm_bo *bo, int plane) { (void)plane; return bo ? bo->stride : 0; }
uint32_t gbm_bo_get_offset(struct gbm_bo *bo, int plane) { (void)bo; (void)plane; return 0; }
void *gbm_bo_map(struct gbm_bo *bo, uint32_t x, uint32_t y, uint32_t width, uint32_t height, uint32_t flags, uint32_t *stride, void **map_data) { (void)bo; (void)x; (void)y; (void)width; (void)height; (void)flags; if (stride) *stride = 0; if (map_data) *map_data = NULL; return NULL; }
void gbm_bo_unmap(struct gbm_bo *bo, void *map_data) { (void)bo; (void)map_data; }
