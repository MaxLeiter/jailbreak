#pragma once
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
struct di_info;
struct di_edid;
struct di_info *di_info_parse_edid(const void *data, size_t size);
const struct di_edid *di_info_get_edid(const struct di_info *info);
char *di_info_get_model(const struct di_info *info);
char *di_info_get_serial(const struct di_info *info);
void di_info_destroy(struct di_info *info);
#ifdef __cplusplus
}
#endif
