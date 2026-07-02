#pragma once
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
struct gbm_device;
struct gbm_bo;
#define GBM_BO_USE_SCANOUT   (1u << 0)
#define GBM_BO_USE_RENDERING (1u << 2)
#define GBM_BO_USE_LINEAR    (1u << 4)
#define GBM_BO_TRANSFER_READ  (1u << 0)
#define GBM_BO_TRANSFER_WRITE (1u << 1)
struct gbm_device *gbm_create_device(int fd);
void gbm_device_destroy(struct gbm_device *gbm);
int gbm_device_get_fd(struct gbm_device *gbm);
struct gbm_bo *gbm_bo_create(struct gbm_device *gbm, uint32_t width, uint32_t height, uint32_t format, uint32_t flags);
struct gbm_bo *gbm_bo_create_with_modifiers(struct gbm_device *gbm, uint32_t width, uint32_t height, uint32_t format, const uint64_t *modifiers, const unsigned int count);
void gbm_bo_destroy(struct gbm_bo *bo);
uint32_t gbm_bo_get_width(struct gbm_bo *bo);
uint32_t gbm_bo_get_height(struct gbm_bo *bo);
uint32_t gbm_bo_get_format(struct gbm_bo *bo);
uint64_t gbm_bo_get_modifier(struct gbm_bo *bo);
int gbm_bo_get_fd(struct gbm_bo *bo);
int gbm_bo_get_plane_count(struct gbm_bo *bo);
uint32_t gbm_bo_get_stride_for_plane(struct gbm_bo *bo, int plane);
uint32_t gbm_bo_get_offset(struct gbm_bo *bo, int plane);
void *gbm_bo_map(struct gbm_bo *bo, uint32_t x, uint32_t y, uint32_t width, uint32_t height, uint32_t flags, uint32_t *stride, void **map_data);
void gbm_bo_unmap(struct gbm_bo *bo, void *map_data);
#ifdef __cplusplus
}
#endif
