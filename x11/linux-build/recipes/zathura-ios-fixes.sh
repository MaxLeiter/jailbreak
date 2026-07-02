#!/usr/bin/env bash
# zathura-ios-fixes.sh — apply the two iOS/cross porting patches to a freshly extracted zathura
# source tree. Called from recipes/zathura.mk's setup rule as:
#     bash /work/recipes/zathura-ios-fixes.sh $(BUILD_WORK)/zathura
#
# Patch 1 (darwin-ectomy): zathura's meson.build takes `if host_machine.system() == 'darwin'`
#   branches that require gtk-mac-integration-gtk3 and define -DGTKOSXAPPLICATION (pulling
#   <gtkosxapplication.h> + AppKit code into main.c). Our cross build is Mach-O but an X11 GTK3
#   build with no GtkOSX, so both branches must be skipped. Neutralise the condition string.
# Patch 2 (magic-ectomy): 0.5.12 makes dependency('libmagic') unconditional. libmagic is not in
#   our tree; drop it from meson.build and replace content-type.c with a libmagic-free version
#   that relies on zathura's existing GLib content-type fallback.
set -euo pipefail

SRC="${1:?usage: zathura-ios-fixes.sh <zathura-src-dir>}"
MB="$SRC/meson.build"
CT="$SRC/zathura/content-type.c"

[ -f "$MB" ] || { echo "ERROR: $MB not found"; exit 1; }
[ -f "$CT" ] || { echo "ERROR: $CT not found"; exit 1; }

echo "==> zathura patch 1/2: neutralising darwin (GtkOSX) meson branches"
# Both darwin conditionals become permanently false; leaves the endif/blocks harmless.
sed -i "s/host_machine.system() == 'darwin'/host_machine.system() == 'iosdisabled'/g" "$MB"

echo "==> zathura patch 2/2: removing libmagic dependency"
# Drop the `magic = dependency('libmagic')` line and remove `magic` from build_dependencies.
sed -i "/magic = dependency('libmagic')/d" "$MB"
sed -i 's/cairo, magic, json_glib/cairo, json_glib/' "$MB"

# Sanity: make sure no stray `magic` token remains in build_dependencies.
if grep -qE "build_dependencies = \[.*\bmagic\b" "$MB"; then
  echo "ERROR: 'magic' still present in build_dependencies after patch"; exit 1
fi

echo "==> zathura patch 2/2: swapping content-type.c for a libmagic-free version"
cat > "$CT" <<'ZEOF'
/* SPDX-License-Identifier: Zlib */
/* iOS cross build (recipes/zathura-ios-fixes.sh): libmagic removed. Content-type detection
 * falls back entirely to GLib's g_content_type_guess, which is sufficient to route documents
 * (e.g. .pdf) to the correct zathura backend plugin. */

#include "content-type.h"
#include "macros.h"

#include <gio/gio.h>
#include <girara/utils.h>
#include <glib.h>
#include <stdio.h>

struct zathura_content_type_context_s {
  int unused;
};

zathura_content_type_context_t* zathura_content_type_new(void) {
  return g_try_malloc0(sizeof(zathura_content_type_context_t));
}

void zathura_content_type_free(zathura_content_type_context_t* context) {
  g_free(context);
}

/** Read at most GT_MAX_READ bytes when sniffing content. */
static const size_t GT_MAX_READ = 1 << 16;

static char* guess_type_glib(const char* path) {
  gboolean uncertain = FALSE;
  char* content_type  = g_content_type_guess(path, NULL, 0, &uncertain);
  if (content_type == NULL) {
    girara_debug("g_content_type failed\n");
  } else {
    if (uncertain == FALSE) {
      girara_debug("g_content_type detected filetype: %s", content_type);
      return content_type;
    }
    girara_debug("g_content_type is uncertain, guess: %s", content_type);
  }

  FILE* f = fopen(path, "rb");
  if (f == NULL) {
    return NULL;
  }

  guchar* content = NULL;
  size_t length   = 0;
  while (uncertain == TRUE && length < GT_MAX_READ) {
    g_free(content_type);
    content_type = NULL;

    guchar* temp_content = g_try_realloc(content, length + BUFSIZ);
    if (temp_content == NULL) {
      break;
    }
    content = temp_content;

    size_t bytes_read = fread(content + length, 1, BUFSIZ, f);
    if (bytes_read == 0) {
      break;
    }

    length += bytes_read;
    content_type = g_content_type_guess(NULL, content, length, &uncertain);
    girara_debug("new guess: %s uncertain: %d, read: %zu", content_type, uncertain, length);
  }

  fclose(f);
  g_free(content);
  if (uncertain == FALSE) {
    return content_type;
  }

  g_free(content_type);
  return NULL;
}

static int compare_content_types(const void* lhs, const void* rhs) {
  return g_strcmp0(lhs, rhs);
}

char* zathura_content_type_guess(zathura_content_type_context_t* context, const char* path,
                                 const girara_list_t* supported_content_types) {
  (void)context;

  char* content_type = guess_type_glib(path);
  if (content_type != NULL) {
    if (supported_content_types == NULL ||
        girara_list_find(supported_content_types, compare_content_types, content_type) != NULL) {
      return content_type;
    }
    girara_debug("content type '%s' not supported", content_type);
    g_free(content_type);
  }
  return NULL;
}
ZEOF

echo "==> zathura iOS fixes applied."
