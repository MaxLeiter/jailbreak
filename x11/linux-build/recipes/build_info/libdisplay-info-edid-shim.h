#pragma once
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
struct di_edid;
struct di_edid_ext;
struct di_edid_vendor_product {
    char manufacturer[3];
    uint16_t product;
    uint32_t serial;
    uint8_t manufacture_week;
    uint16_t manufacture_year;
    uint16_t model_year;
};
struct di_edid_screen_size {
    int width_cm;
    int height_cm;
};
struct di_edid_chromaticity_coords {
    float red_x, red_y, green_x, green_y, blue_x, blue_y, white_x, white_y;
};
struct di_edid_detailed_timing_def {
    int horiz_image_mm;
    int vert_image_mm;
    int horiz_video;
    int vert_video;
};
const struct di_edid_detailed_timing_def *const *di_edid_get_detailed_timing_defs(const struct di_edid *edid);
const struct di_edid_screen_size *di_edid_get_screen_size(const struct di_edid *edid);
const struct di_edid_vendor_product *di_edid_get_vendor_product(const struct di_edid *edid);
const struct di_edid_chromaticity_coords *di_edid_get_chromaticity_coords(const struct di_edid *edid);
const struct di_edid_ext *const *di_edid_get_extensions(const struct di_edid *edid);
#ifdef __cplusplus
}
#endif
