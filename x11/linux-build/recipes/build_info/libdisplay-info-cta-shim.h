#pragma once
#include <stdbool.h>
#ifdef __cplusplus
extern "C" {
#endif
struct di_edid_ext;
struct di_edid_cta;
struct di_cta_data_block;
struct di_cta_hdr_static_metadata_block {
    double desired_content_min_luminance;
    double desired_content_max_luminance;
    double desired_content_max_frame_avg_luminance;
    const struct {
        bool pq;
    } *eotfs;
};
struct di_cta_colorimetry_block {
    bool bt2020_rgb;
};
const struct di_edid_cta *di_edid_ext_get_cta(const struct di_edid_ext *ext);
const struct di_cta_data_block *const *di_edid_cta_get_data_blocks(const struct di_edid_cta *cta);
const struct di_cta_hdr_static_metadata_block *di_cta_data_block_get_hdr_static_metadata(const struct di_cta_data_block *block);
const struct di_cta_colorimetry_block *di_cta_data_block_get_colorimetry(const struct di_cta_data_block *block);
#ifdef __cplusplus
}
#endif
