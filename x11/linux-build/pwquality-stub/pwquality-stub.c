/* -*- mode: C; c-file-style: "gnu"; indent-tabs-mode: nil; -*- */
/*
 * pwquality-stub.c — an ABI-compatible STUB of libpwquality for iOS.
 *
 * gnome-control-center's system>users password subpage links libpwquality to score password
 * strength. Upstream libpwquality pulls cracklib (a dictionary + zlib), which is a poor fit to
 * cross-build for a jailbroken iPad. This stub exports the libpwquality public ABI using the
 * real upstream pwquality.h, so gcc compiles/links/runs unchanged. It provides local strength
 * scoring and random password generation, but no dictionary/cracklib checks.
 *
 * pwquality_check() returns 0..100 like the real library (or a negative PWQ_ERROR on bad args);
 * gcc's pw-utils.c maps that onto the strength bar. GPL-2.0+ (matches libpwquality).
 */
#include "pwquality.h"
#include <ctype.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

/* Opaque settings: we keep only min-length so get/set round-trip sensibly. */
struct pwquality_settings { int min_length; };

static int
clampi (int v, int lo, int hi)
{
  return v < lo ? lo : v > hi ? hi : v;
}

static int
ascii_contains_ci (const char *haystack, const char *needle)
{
  if (!haystack || !needle || !*needle)
    return 0;
  size_t nl = strlen (needle);
  for (const char *h = haystack; *h; h++)
    {
      size_t i = 0;
      while (i < nl && h[i] &&
             tolower ((unsigned char) h[i]) == tolower ((unsigned char) needle[i]))
        i++;
      if (i == nl)
        return 1;
    }
  return 0;
}

static unsigned
rnd (unsigned n)
{
  return n ? arc4random_uniform (n) : 0;
}

pwquality_settings_t *
pwquality_default_settings (void)
{
  pwquality_settings_t *pwq = calloc (1, sizeof *pwq);
  if (pwq) pwq->min_length = 8;
  return pwq;
}

void
pwquality_free_settings (pwquality_settings_t *pwq)
{
  free (pwq);
}

int
pwquality_read_config (pwquality_settings_t *pwq, const char *cfgfile, void **auxerror)
{
  (void) pwq; (void) cfgfile;
  if (auxerror) *auxerror = NULL;
  return 0;  /* success; no config file on iOS */
}

int
pwquality_set_int_value (pwquality_settings_t *pwq, int setting, int value)
{
  if (!pwq) return PWQ_ERROR_FATAL_FAILURE;
  if (setting == PWQ_SETTING_MIN_LENGTH) pwq->min_length = clampi (value, 1, 128);
  return 0;
}

int
pwquality_get_int_value (pwquality_settings_t *pwq, int setting, int *value)
{
  if (!pwq || !value) return PWQ_ERROR_FATAL_FAILURE;
  *value = (setting == PWQ_SETTING_MIN_LENGTH) ? pwq->min_length : 0;
  return 0;
}

int
pwquality_set_str_value (pwquality_settings_t *pwq, int setting, const char *value)
{
  (void) setting; (void) value;
  return pwq ? 0 : PWQ_ERROR_FATAL_FAILURE;
}

int
pwquality_get_str_value (pwquality_settings_t *pwq, int setting, const char **value)
{
  (void) setting;
  if (!pwq || !value) return PWQ_ERROR_FATAL_FAILURE;
  *value = NULL;
  return 0;
}

int
pwquality_set_option (pwquality_settings_t *pwq, const char *option)
{
  if (!pwq || !option) return PWQ_ERROR_FATAL_FAILURE;
  if (strncmp (option, "minlen=", 7) == 0 || strncmp (option, "min_length=", 11) == 0)
    {
      const char *eq = strchr (option, '=');
      pwq->min_length = clampi (atoi (eq + 1), 1, 128);
    }
  return 0;
}

/* Local strength score in [0,100]. No dictionary check, but catches common weak cases. */
int
pwquality_check (pwquality_settings_t *pwq, const char *password,
                 const char *oldpassword, const char *user, void **auxerror)
{
  if (auxerror) *auxerror = NULL;
  if (!password) return PWQ_ERROR_EMPTY_PASSWORD;
  size_t len = strlen (password);
  if (len == 0) return PWQ_ERROR_EMPTY_PASSWORD;
  if (oldpassword && strcmp (password, oldpassword) == 0)
    return PWQ_ERROR_SAME_PASSWORD;
  if (user && strlen (user) >= 3 && ascii_contains_ci (password, user))
    return PWQ_ERROR_USER_CHECK;
  int min = pwq ? pwq->min_length : 8;
  if ((int) len < min) return PWQ_ERROR_MIN_LENGTH;

  int lower = 0, upper = 0, digit = 0, other = 0, repeats = 0;
  unsigned char seen[256] = {0};
  int unique = 0;
  for (size_t i = 0; i < len; i++)
    {
      unsigned char c = (unsigned char) password[i];
      if (!seen[c]++) unique++;
      if (i > 0 && password[i] == password[i - 1]) repeats++;
      if (islower (c)) lower = 1;
      else if (isupper (c)) upper = 1;
      else if (isdigit (c)) digit = 1;
      else other = 1;
    }

  int classes = lower + upper + digit + other;
  if (classes < 2 && len < 14)
    return PWQ_ERROR_MIN_CLASSES;

  int score = 0;
  score += clampi ((int) len * 5, 0, 45);
  score += classes * 12;
  score += clampi (unique * 2, 0, 20);
  score -= repeats * 5;
  return clampi (score, 0, 100);
}

int
pwquality_generate (pwquality_settings_t *pwq, int entropy_bits, char **password)
{
  if (!password) return PWQ_ERROR_FATAL_FAILURE;
  *password = NULL;

  int min = pwq ? pwq->min_length : 8;
  int bits = entropy_bits > 0 ? entropy_bits : PWQ_MIN_ENTROPY_BITS;
  bits = clampi (bits, PWQ_MIN_ENTROPY_BITS, PWQ_MAX_ENTROPY_BITS);
  size_t len = (size_t) clampi ((bits + 4) / 5, min > 12 ? min : 12, 64);

  static const char lower[] = "abcdefghijkmnopqrstuvwxyz";
  static const char upper[] = "ABCDEFGHJKLMNPQRSTUVWXYZ";
  static const char digit[] = "23456789";
  static const char symbol[] = "!@#$%+-_=?:";
  static const char all[] =
    "abcdefghijkmnopqrstuvwxyz"
    "ABCDEFGHJKLMNPQRSTUVWXYZ"
    "23456789"
    "!@#$%+-_=?:";

  char *out = calloc (len + 1, 1);
  if (!out) return PWQ_ERROR_MEM_ALLOC;
  out[0] = lower[rnd ((unsigned) strlen (lower))];
  out[1] = upper[rnd ((unsigned) strlen (upper))];
  out[2] = digit[rnd ((unsigned) strlen (digit))];
  out[3] = symbol[rnd ((unsigned) strlen (symbol))];
  for (size_t i = 4; i < len; i++)
    out[i] = all[rnd ((unsigned) strlen (all))];
  for (size_t i = len - 1; i > 0; i--)
    {
      size_t j = rnd ((unsigned) (i + 1));
      char t = out[i]; out[i] = out[j]; out[j] = t;
    }
  *password = out;
  return 0;
}

const char *
pwquality_strerror (char *buf, size_t len, int errcode, void *auxerror)
{
  (void) auxerror;
  const char *msg;
  switch (errcode)
    {
    case PWQ_ERROR_EMPTY_PASSWORD: msg = "The password is empty"; break;
    case PWQ_ERROR_MIN_LENGTH:     msg = "The password is too short"; break;
    case PWQ_ERROR_MIN_CLASSES:    msg = "The password does not contain enough character classes"; break;
    case PWQ_ERROR_SAME_PASSWORD:  msg = "The password is unchanged"; break;
    case PWQ_ERROR_USER_CHECK:     msg = "The password contains the user name"; break;
    case PWQ_ERROR_MEM_ALLOC:      msg = "Memory allocation failed"; break;
    default:                       msg = "Password quality check unavailable"; break;
    }
  if (buf && len) { strncpy (buf, msg, len - 1); buf[len - 1] = 0; return buf; }
  return msg;
}
