/* -*- mode: C; c-file-style: "gnu"; indent-tabs-mode: nil; -*- */

/*
 * MetaSelection <-> Xios clipboard adapter for MetaBackendIOS.
 *
 * Transport/framing stays in iosc-clipboard-bridge.c; this unit only maps
 * Mutter's compositor-wide clipboard model to the four representations carried
 * by the strict private protocol.
 */
#pragma once

typedef struct _MetaBackend MetaBackend;
typedef struct _MetaClipboardIOS MetaClipboardIOS;

MetaClipboardIOS *meta_clipboard_ios_new  (MetaBackend *backend,
                                           const char  *socket_path);
void              meta_clipboard_ios_free (MetaClipboardIOS *clipboard);

