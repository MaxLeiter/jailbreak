/* iOS links-only stub of the Linux dma-buf uapi. The dmabuf sync/export ioctls are inert on iOS;
 * the GPU buffer path is replaced by IOSurface in the MetaBackendIOS compositor backend (iosc).
 * CANONICAL COPY: staged as <linux/dma-buf.h> into the cross sysroot by build-mutter.sh and onto
 * the device by gir-build-mutter-ondevice.sh — both builds must compile against this same stub. */
#ifndef _LINUX_DMA_BUF_H_IOS_STUB
#define _LINUX_DMA_BUF_H_IOS_STUB
#include <sys/ioctl.h>
#include <stdint.h>
struct dma_buf_sync { uint64_t flags; };
struct dma_buf_export_sync_file { uint32_t flags; int32_t fd; };
struct dma_buf_import_sync_file { uint32_t flags; int32_t fd; };
#define DMA_BUF_SYNC_READ      (1 << 0)
#define DMA_BUF_SYNC_WRITE     (2 << 0)
#define DMA_BUF_SYNC_RW        (DMA_BUF_SYNC_READ | DMA_BUF_SYNC_WRITE)
#define DMA_BUF_SYNC_START     (0 << 2)
#define DMA_BUF_SYNC_END       (1 << 2)
#define DMA_BUF_BASE           'b'
#define DMA_BUF_IOCTL_SYNC              _IOW(DMA_BUF_BASE, 0, struct dma_buf_sync)
#define DMA_BUF_IOCTL_EXPORT_SYNC_FILE  _IOWR(DMA_BUF_BASE, 2, struct dma_buf_export_sync_file)
#define DMA_BUF_IOCTL_IMPORT_SYNC_FILE  _IOW(DMA_BUF_BASE, 3, struct dma_buf_import_sync_file)
#endif
