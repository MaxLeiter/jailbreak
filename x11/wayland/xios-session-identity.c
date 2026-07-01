/* -*- mode: C; c-file-style: "gnu"; indent-tabs-mode: nil; -*- */

/*
 * xios-session-identity.c — resolve the real logged-in user once for the session stubs.
 * See xios-session-identity.h. GPL-2.0+.
 */
#include "xios-session-identity.h"

#include <glib.h>
#include <pwd.h>
#include <string.h>
#include <unistd.h>
#include <dlfcn.h>
#include <CoreFoundation/CoreFoundation.h>

/* Ask MobileGestalt for the user-assigned device name ("Max's iPad"). dlopen'd so we need no
 * private headers and it degrades cleanly on any device. Returned string is g_malloc'd. */
static char *
mobilegestalt_device_name (void)
{
  typedef CFStringRef (*mg_copy_answer_fn) (CFStringRef);
  void *handle;
  mg_copy_answer_fn MGCopyAnswer;
  CFStringRef key, answer;
  char *result = NULL;

  handle = dlopen ("/usr/lib/libMobileGestalt.dylib", RTLD_LAZY | RTLD_GLOBAL);
  if (!handle)
    return NULL;
  MGCopyAnswer = (mg_copy_answer_fn) dlsym (handle, "MGCopyAnswer");
  if (!MGCopyAnswer)
    return NULL;   /* leave handle open: process-lifetime, unloading CF providers is unsafe */

  key = CFStringCreateWithCString (NULL, "UserAssignedDeviceName", kCFStringEncodingUTF8);
  if (!key)
    return NULL;
  answer = MGCopyAnswer (key);
  if (answer && CFGetTypeID (answer) == CFStringGetTypeID ())
    {
      CFIndex len = CFStringGetLength (answer);
      CFIndex cap = CFStringGetMaximumSizeForEncoding (len, kCFStringEncodingUTF8) + 1;
      char *buf = g_malloc0 (cap);

      if (CFStringGetCString (answer, buf, cap, kCFStringEncodingUTF8) && *buf)
        result = buf;
      else
        g_free (buf);
    }
  if (answer)
    CFRelease (answer);
  CFRelease (key);
  return result;
}

/* Generic / impersonal account names we would rather replace with the device name. */
static gboolean
name_is_generic (const char *s)
{
  static const char *generic[] = {
    "root", "mobile", "Mobile User", "System Administrator", "Administrator",
    "Daemon", "System Services", "unknown", NULL
  };

  if (!s || !*s)
    return TRUE;
  for (int i = 0; generic[i]; i++)
    if (g_ascii_strcasecmp (s, generic[i]) == 0)
      return TRUE;
  return FALSE;
}

static const char *
resolve_realname (const struct passwd *pw)
{
  const char *env = g_getenv ("XIOS_REAL_NAME");
  char *gecos = NULL, *dev, *host;

  if (env && *env)
    return g_strdup (env);

  /* passwd GECOS, first comma-field, if it is a real personal name. */
  if (pw && pw->pw_gecos && *pw->pw_gecos)
    {
      gecos = g_strdup (pw->pw_gecos);
      char *comma = strchr (gecos, ',');
      if (comma)
        *comma = '\0';
      g_strstrip (gecos);
      if (!name_is_generic (gecos))
        return gecos;   /* meaningful real name wins */
    }
  g_free (gecos);

  /* The device's user-assigned name is the most personal thing we have. */
  dev = mobilegestalt_device_name ();
  if (dev && *dev)
    return dev;
  g_free (dev);

  host = g_malloc0 (256);
  if (gethostname (host, 255) == 0 && *host && g_ascii_strcasecmp (host, "localhost") != 0)
    return host;
  g_free (host);

  return g_strdup ("iOS User");
}

const XiosIdentity *
xios_identity (void)
{
  static XiosIdentity id;
  static gboolean initialized = FALSE;
  struct passwd *pw;
  const char *lang;
  char *iconpath;

  if (initialized)
    return &id;

  id.uid = getuid ();
  pw = getpwuid (id.uid);

  id.username = (pw && pw->pw_name && *pw->pw_name) ? g_strdup (pw->pw_name) : "mobile";
  id.home     = (pw && pw->pw_dir && *pw->pw_dir)   ? g_strdup (pw->pw_dir)  : "/var/mobile";
  id.shell    = (pw && pw->pw_shell && *pw->pw_shell) ? g_strdup (pw->pw_shell) : "/bin/sh";
  id.realname = resolve_realname (pw);

  /* Avatar: ~/.face if the user placed one, else empty (shell draws a default). */
  iconpath = g_build_filename (id.home, ".face", NULL);
  if (g_file_test (iconpath, G_FILE_TEST_EXISTS))
    id.icon_file = iconpath;
  else
    {
      g_free (iconpath);
      id.icon_file = "";
    }

  /* Session locale for the Accounts Language property. */
  lang = g_getenv ("LANG");
  if (!lang || !*lang)
    lang = g_getenv ("LC_MESSAGES");
  if (!lang || !*lang)
    lang = g_getenv ("LC_ALL");
  id.language = (lang && *lang) ? g_strdup (lang) : "";

  initialized = TRUE;
  return &id;
}
