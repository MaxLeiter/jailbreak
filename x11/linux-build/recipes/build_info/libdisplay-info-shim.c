#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>

struct di_info;
struct di_edid;
struct di_edid_ext;
struct di_edid_cta;
struct di_cta_data_block;
struct di_cta_hdr_static_metadata_block;
struct di_cta_colorimetry_block;
struct di_edid_detailed_timing_def;
struct di_edid_screen_size { int width_cm; int height_cm; };
struct di_edid_vendor_product { char manufacturer[3]; uint16_t product; uint32_t serial; uint8_t manufacture_week; uint16_t manufacture_year; uint16_t model_year; };
struct di_edid_chromaticity_coords;

struct di_info *di_info_parse_edid(const void *data, size_t size) { (void)data; (void)size; return NULL; }
const struct di_edid *di_info_get_edid(const struct di_info *info) { (void)info; return NULL; }
char *di_info_get_model(const struct di_info *info) { (void)info; return NULL; }
char *di_info_get_serial(const struct di_info *info) { (void)info; return NULL; }
void di_info_destroy(struct di_info *info) { (void)info; }
const struct di_edid_detailed_timing_def *const *di_edid_get_detailed_timing_defs(const struct di_edid *edid) { (void)edid; return NULL; }
const struct di_edid_screen_size *di_edid_get_screen_size(const struct di_edid *edid) { static const struct di_edid_screen_size s = {0, 0}; (void)edid; return &s; }
const struct di_edid_vendor_product *di_edid_get_vendor_product(const struct di_edid *edid) { static const struct di_edid_vendor_product p = {{0, 0, 0}, 0, 0, 0, 0, 0}; (void)edid; return &p; }
const struct di_edid_chromaticity_coords *di_edid_get_chromaticity_coords(const struct di_edid *edid) { (void)edid; return NULL; }
const struct di_edid_ext *const *di_edid_get_extensions(const struct di_edid *edid) { static const struct di_edid_ext *exts[] = { NULL }; (void)edid; return exts; }
const struct di_edid_cta *di_edid_ext_get_cta(const struct di_edid_ext *ext) { (void)ext; return NULL; }
const struct di_cta_data_block *const *di_edid_cta_get_data_blocks(const struct di_edid_cta *cta) { static const struct di_cta_data_block *blocks[] = { NULL }; (void)cta; return blocks; }
const struct di_cta_hdr_static_metadata_block *di_cta_data_block_get_hdr_static_metadata(const struct di_cta_data_block *block) { (void)block; return NULL; }
const struct di_cta_colorimetry_block *di_cta_data_block_get_colorimetry(const struct di_cta_data_block *block) { (void)block; return NULL; }
