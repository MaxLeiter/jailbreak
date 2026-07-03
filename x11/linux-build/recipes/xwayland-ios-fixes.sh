#!/usr/bin/env bash
# xwayland-ios-fixes.sh — apply the iOS/ANGLE/IOSurface source edits to an
# extracted xwayland-23.2.x tree. Idempotent (safe to re-run). Called by
# xwayland.mk after EXTRACT_TAR. Two independent changes:
#   (A) rootless popen: /bin/sh -> /var/jb/bin/sh in os/utils.c (rootless has no
#       /bin/sh; xkbcomp is spawned via this — same fix as the tigervnc build,
#       ports/0001-xserver-popen-shell-rootless.patch).
#   (B) glamor IOSurface backend: a new EGL backend (xwayland-glamor-iosurface.c,
#       dropped in beside this script's cwd) wired into the pluggable
#       xwl_egl_backend vtable that xwayland <= 23.2 still has. No gbm/dma-buf.
#
# Arg $1 = the extracted xwayland source dir (contains hw/, os/, include/).
# Arg $2 = path to xwayland-glamor-iosurface.c to install.
# Arg $3 = path to iosc-iosurface.xml (the compositor's export protocol).
set -euo pipefail
SRC="${1:?source dir}"
BACKEND_C="${2:?backend .c}"
IOSC_XML="${3:?iosc-iosurface.xml}"

cp -v "$BACKEND_C" "$SRC/hw/xwayland/xwayland-glamor-iosurface.c"
cp -v "$IOSC_XML"  "$SRC/hw/xwayland/iosc-iosurface.xml"

python3 - "$SRC" <<'PY'
import re, sys, pathlib
root = pathlib.Path(sys.argv[1])

def edit(rel, fn):
    p = root / rel
    s = p.read_text()
    n = fn(s)
    if n != s:
        p.write_text(n); print(f"   patched {rel}")
    else:
        print(f"   (already patched) {rel}")

# (A) rootless popen shell — both execl sites in os/utils.c.
edit("os/utils.c", lambda s: s.replace(
    'execl("/bin/sh", "sh", "-c", command, (char *) NULL);',
    'execl("/var/jb/bin/sh", "sh", "-c", command, (char *) NULL);'))

# (B1) config: define XWL_HAS_IOSURFACE, and make XWL_HAS_GLAMOR true for the
# iosurface-only build (no gbm, no eglstream).
def cfg_in(s):
    if "XWL_HAS_IOSURFACE" in s:
        return s
    return s.replace(
        "/* Build eglstream support for Xwayland */\n#mesondefine XWL_HAS_EGLSTREAM\n",
        "/* Build eglstream support for Xwayland */\n#mesondefine XWL_HAS_EGLSTREAM\n\n"
        "/* Build the iOS IOSurface glamor backend (ANGLE-Metal) */\n"
        "#mesondefine XWL_HAS_IOSURFACE\n")
edit("include/xwayland-config.h.meson.in", cfg_in)

def cfg_meson(s):
    s = s.replace(
        "xwayland_data.set('XWL_HAS_GLAMOR', build_glamor and (gbm_dep.found() or build_eglstream) ? '1' : false)",
        "xwayland_data.set('XWL_HAS_GLAMOR', build_glamor ? '1' : false)")
    if "XWL_HAS_IOSURFACE" not in s:
        s = s.replace(
            "xwayland_data.set('XWL_HAS_EGLSTREAM', build_eglstream ? '1' : false)",
            "xwayland_data.set('XWL_HAS_EGLSTREAM', build_eglstream ? '1' : false)\n"
            "xwayland_data.set('XWL_HAS_IOSURFACE', build_iosurface ? '1' : false)")
    return s
edit("include/meson.build", cfg_meson)

# (B2) top-level meson: a build_iosurface option-ish flag (on when glamor is on
# and neither gbm nor eglstream is available — the iOS case). Also relax the
# hard libdrm/epoxy requirement message path (both are present as our shims).
def top_meson(s):
    if "build_iosurface" in s:
        return s
    # define build_iosurface right after build_eglstream is decided.
    anchor = "else\n    build_eglstream = false\nendif\n"
    if anchor not in s:
        # tolerate whitespace differences: fall back to a regex.
        s2 = re.sub(r"(build_eglstream = false\s*\nendif\n)",
                    r"\1\nbuild_iosurface = build_glamor and not gbm_dep.found() and not build_eglstream\n",
                    s, count=1)
        return s2
    return s.replace(anchor,
        anchor + "\nbuild_iosurface = build_glamor and not gbm_dep.found() and not build_eglstream\n")
edit("meson.build", top_meson)

# NB presentproto stays at the upstream '>= 1.3' gate. present.c genuinely uses a
# 1.3 symbol (PresentAllAsyncOptions / PresentOptionAsyncMayTear, in
# presenttokens.h), so we satisfy it by bumping xorgproto to 2024.1
# (recipes/xorgproto.mk, presentproto 1.4) rather than relaxing the gate.

# (B3) hw/xwayland/meson.build: build the iosurface source + codegen the iosc
# protocol when build_iosurface. Insert inside the `if build_glamor` block.
def hw_meson(s):
    if "xwayland-glamor-iosurface.c" in s:
        return s
    ins = (
        "    if build_iosurface\n"
        "        srcs += 'xwayland-glamor-iosurface.c'\n"
        "        srcs += client_header.process('iosc-iosurface.xml')\n"
        "        srcs += code.process('iosc-iosurface.xml')\n"
        "        # IOSurface/CoreFoundation C APIs used by the backend.\n"
        "        xwayland_dep += declare_dependency(link_args: [\n"
        "            '-Wl,-framework,IOSurface', '-Wl,-framework,CoreFoundation'])\n"
        "    endif\n")
    # place right after the eglstream block's `endif` inside build_glamor,
    # before `if build_xv`.
    return s.replace("    if build_xv\n        srcs += 'xwayland-glamor-xv.c'\n    endif\n",
                     ins + "    if build_xv\n        srcs += 'xwayland-glamor-xv.c'\n    endif\n", 1)
edit("hw/xwayland/meson.build", hw_meson)

# (B4) screen struct: add the iosurface_backend slot.
def screen_h(s):
    if "iosurface_backend" in s:
        return s
    return s.replace(
        "    struct xwl_egl_backend gbm_backend;\n"
        "    struct xwl_egl_backend eglstream_backend;\n",
        "    struct xwl_egl_backend gbm_backend;\n"
        "    struct xwl_egl_backend eglstream_backend;\n"
        "    struct xwl_egl_backend iosurface_backend;\n")
edit("hw/xwayland/xwayland-screen.h", screen_h)

# (B5) glamor.h: declare the init entrypoint.
def glamor_h(s):
    if "xwl_glamor_init_iosurface" in s:
        return s
    return s.replace(
        "void xwl_glamor_init_backends(struct xwl_screen *xwl_screen,\n"
        "                              Bool use_eglstream);",
        "void xwl_glamor_init_backends(struct xwl_screen *xwl_screen,\n"
        "                              Bool use_eglstream);\n"
        "#ifdef XWL_HAS_IOSURFACE\n"
        "void xwl_glamor_init_iosurface(struct xwl_screen *xwl_screen);\n"
        "#endif")
edit("hw/xwayland/xwayland-glamor.h", glamor_h)

# (B6) glamor.c: init + select + registry wiring, and the make_current fallback.
def glamor_c(s):
    # make_current fallback surface (surfaceless is fine on ANGLE, but if it
    # ever isn't, the backend leaves a 1x1 pbuffer here).
    if "xwl_iosurface_fallback_surface" not in s:
        s = s.replace(
            "static void\n"
            "glamor_egl_make_current(struct glamor_context *glamor_ctx)\n"
            "{\n"
            "    eglMakeCurrent(glamor_ctx->display, EGL_NO_SURFACE,\n"
            "                   EGL_NO_SURFACE, EGL_NO_CONTEXT);\n"
            "    if (!eglMakeCurrent(glamor_ctx->display,\n"
            "                        EGL_NO_SURFACE, EGL_NO_SURFACE,\n"
            "                        glamor_ctx->ctx))\n"
            "        FatalError(\"Failed to make EGL context current\\n\");\n"
            "}",
            "#ifdef XWL_HAS_IOSURFACE\n"
            "extern EGLSurface xwl_iosurface_fallback_surface;\n"
            "#endif\n\n"
            "static void\n"
            "glamor_egl_make_current(struct glamor_context *glamor_ctx)\n"
            "{\n"
            "    EGLSurface s = EGL_NO_SURFACE;\n"
            "#ifdef XWL_HAS_IOSURFACE\n"
            "    s = xwl_iosurface_fallback_surface;\n"
            "#endif\n"
            "    eglMakeCurrent(glamor_ctx->display, EGL_NO_SURFACE,\n"
            "                   EGL_NO_SURFACE, EGL_NO_CONTEXT);\n"
            "    if (!eglMakeCurrent(glamor_ctx->display, s, s,\n"
            "                        glamor_ctx->ctx))\n"
            "        FatalError(\"Failed to make EGL context current\\n\");\n"
            "}")

    # init_backends: add iosurface init at the end of the function.
    if "xwl_glamor_init_iosurface(xwl_screen)" not in s:
        s = s.replace(
            "#ifdef XWL_HAS_EGLSTREAM\n"
            "    xwl_glamor_init_eglstream(xwl_screen);\n"
            "    if (!xwl_screen->eglstream_backend.is_available && use_eglstream)\n"
            "        ErrorF(\"Xwayland glamor: EGLStream backend requested but not available\\n\");\n"
            "#endif\n"
            "}",
            "#ifdef XWL_HAS_EGLSTREAM\n"
            "    xwl_glamor_init_eglstream(xwl_screen);\n"
            "    if (!xwl_screen->eglstream_backend.is_available && use_eglstream)\n"
            "        ErrorF(\"Xwayland glamor: EGLStream backend requested but not available\\n\");\n"
            "#endif\n"
            "#ifdef XWL_HAS_IOSURFACE\n"
            "    xwl_glamor_init_iosurface(xwl_screen);\n"
            "    if (!xwl_screen->iosurface_backend.is_available)\n"
            "        ErrorF(\"Xwayland glamor: IOSurface backend is not available\\n\");\n"
            "#endif\n"
            "}")

    # a select helper + call it when nothing else was chosen.
    if "xwl_glamor_select_iosurface_backend" not in s:
        s = s.replace(
            "void\n"
            "xwl_glamor_select_backend(struct xwl_screen *xwl_screen, Bool use_eglstream)\n"
            "{",
            "#ifdef XWL_HAS_IOSURFACE\n"
            "static Bool\n"
            "xwl_glamor_select_iosurface_backend(struct xwl_screen *xwl_screen)\n"
            "{\n"
            "    if (xwl_screen->iosurface_backend.is_available &&\n"
            "        xwl_glamor_has_wl_interfaces(xwl_screen, &xwl_screen->iosurface_backend)) {\n"
            "        xwl_screen->egl_backend = &xwl_screen->iosurface_backend;\n"
            "        LogMessageVerb(X_INFO, 3, \"glamor: Using IOSurface backend\\n\");\n"
            "        return TRUE;\n"
            "    }\n"
            "    else\n"
            "        LogMessageVerb(X_INFO, 3,\n"
            "                       \"Missing Wayland requirements for glamor IOSurface backend\\n\");\n"
            "    return FALSE;\n"
            "}\n"
            "#endif\n\n"
            "void\n"
            "xwl_glamor_select_backend(struct xwl_screen *xwl_screen, Bool use_eglstream)\n"
            "{")
        s = s.replace(
            "    if (!xwl_glamor_select_eglstream_backend(xwl_screen)) {\n"
            "        if (!use_eglstream)\n"
            "            xwl_glamor_select_gbm_backend(xwl_screen);\n"
            "    }\n"
            "}",
            "    if (!xwl_glamor_select_eglstream_backend(xwl_screen)) {\n"
            "        if (!use_eglstream)\n"
            "            xwl_glamor_select_gbm_backend(xwl_screen);\n"
            "    }\n"
            "#ifdef XWL_HAS_IOSURFACE\n"
            "    if (xwl_screen->egl_backend == NULL)\n"
            "        xwl_glamor_select_iosurface_backend(xwl_screen);\n"
            "#endif\n"
            "}")

    # init_wl_registry: consult the iosurface backend too.
    if "iosurface_backend.init_wl_registry" not in s:
        s = s.replace(
            "    } else if (xwl_screen->eglstream_backend.is_available &&\n"
            "               xwl_screen->eglstream_backend.init_wl_registry(xwl_screen,\n"
            "                                                              registry,\n"
            "                                                              id,\n"
            "                                                              interface,\n"
            "                                                              version)) {\n"
            "        /* no-op */\n"
            "    }\n"
            "}",
            "    } else if (xwl_screen->eglstream_backend.is_available &&\n"
            "               xwl_screen->eglstream_backend.init_wl_registry(xwl_screen,\n"
            "                                                              registry,\n"
            "                                                              id,\n"
            "                                                              interface,\n"
            "                                                              version)) {\n"
            "        /* no-op */\n"
            "    } else if (xwl_screen->iosurface_backend.is_available &&\n"
            "               xwl_screen->iosurface_backend.init_wl_registry(xwl_screen,\n"
            "                                                              registry,\n"
            "                                                              id,\n"
            "                                                              interface,\n"
            "                                                              version)) {\n"
            "        /* no-op */\n"
            "    }\n"
            "}")
    return s
edit("hw/xwayland/xwayland-glamor.c", glamor_c)

# (B7) glamor core: ANGLE/Metal on A10 iOS exposes neither OES nor EXT texture
# border clamp, but rejecting the context here prevents us from exercising the
# IOSurface 2D path at all. Keep the diagnostic, but do not force a software
# fallback solely for this sampler-edge capability.
def glamor_core_c(s):
    old = (
        '        if (!epoxy_has_gl_extension("GL_OES_texture_border_clamp")) {\n'
        '            ErrorF("GL_OES_texture_border_clamp required\\n");\n'
        '            goto fail;\n'
        '        }\n')
    new = (
        '        if (!epoxy_has_gl_extension("GL_OES_texture_border_clamp") &&\n'
        '            !epoxy_has_gl_extension("GL_EXT_texture_border_clamp")) {\n'
        '            LogMessageVerb(X_WARNING, 0,\n'
        '                           "glamor/iosurface: no texture_border_clamp; continuing\\n");\n'
        '        }\n')
    s = s.replace(old, new)
    return s.replace(
        '        if (!epoxy_has_gl_extension("GL_OES_texture_border_clamp") &&\n'
        '            !epoxy_has_gl_extension("GL_EXT_texture_border_clamp")) {\n'
        '            ErrorF("GL_{OES,EXT}_texture_border_clamp required\\n");\n'
        '            goto fail;\n'
        '        }\n',
        new)
edit("glamor/glamor.c", glamor_core_c)
print("xwayland-ios-fixes: done")
PY
