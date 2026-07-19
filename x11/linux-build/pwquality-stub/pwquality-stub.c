/* -*- mode: C; c-file-style: "gnu"; indent-tabs-mode: nil; -*- */
/*
 * pwquality-stub.c — an ABI-compatible libpwquality implementation for iOS.
 *
 * gnome-control-center's system>users password subpage links libpwquality to score password
 * strength. Upstream libpwquality pulls cracklib (a dictionary + zlib), which is a poor fit to
 * cross-build for a jailbroken iPad. This implementation exports the public ABI using the
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

/* All public settings round-trip. Dictionary checks stay disabled because this
 * backend deliberately does not ship cracklib's large word database. */
struct pwquality_settings {
  int ints[PWQ_SETTING_USER_SUBSTR + 1];
  char *dict_path;
  char *bad_words;
};

static int
is_string_setting (int setting)
{
  return setting == PWQ_SETTING_DICT_PATH || setting == PWQ_SETTING_BAD_WORDS;
}

static int
is_int_setting (int setting)
{
  return setting >= PWQ_SETTING_DIFF_OK && setting <= PWQ_SETTING_USER_SUBSTR &&
         setting != 2 && !is_string_setting (setting);
}

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

static int
char_class (unsigned char c)
{
  if (islower (c)) return 1;
  if (isupper (c)) return 2;
  if (isdigit (c)) return 3;
  return 4;
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
  if (pwq)
    {
      pwq->ints[PWQ_SETTING_DIFF_OK] = 1;
      pwq->ints[PWQ_SETTING_MIN_LENGTH] = 8;
      pwq->ints[PWQ_SETTING_DICT_CHECK] = 0;
      pwq->ints[PWQ_SETTING_USER_CHECK] = 1;
      pwq->ints[PWQ_SETTING_ENFORCING] = 1;
      pwq->ints[PWQ_SETTING_RETRY_TIMES] = 3;
    }
  return pwq;
}

void
pwquality_free_settings (pwquality_settings_t *pwq)
{
  if (!pwq) return;
  free (pwq->dict_path);
  free (pwq->bad_words);
  free (pwq);
}

int
pwquality_read_config (pwquality_settings_t *pwq, const char *cfgfile, void **auxerror)
{
  if (auxerror) *auxerror = NULL;
  if (!pwq) return PWQ_ERROR_FATAL_FAILURE;

  const char *path = cfgfile ? cfgfile : "/var/jb/etc/security/pwquality.conf";
  FILE *file = fopen (path, "r");
  if (!file)
    return cfgfile ? PWQ_ERROR_CFGFILE_OPEN : 0;

  char line[1024];
  while (fgets (line, sizeof line, file))
    {
      char *start = line;
      while (isspace ((unsigned char) *start)) start++;
      if (!*start || *start == '#') continue;
      char *comment = strchr (start, '#');
      if (comment) *comment = 0;
      char *end = start + strlen (start);
      while (end > start && isspace ((unsigned char) end[-1])) *--end = 0;
      if (!*start) continue;
      if (pwquality_set_option (pwq, start) != 0)
        { fclose (file); return PWQ_ERROR_CFGFILE_MALFORMED; }
    }
  fclose (file);
  return 0;
}

int
pwquality_set_int_value (pwquality_settings_t *pwq, int setting, int value)
{
  if (!pwq) return PWQ_ERROR_FATAL_FAILURE;
  if (is_string_setting (setting)) return PWQ_ERROR_NON_INT_SETTING;
  if (!is_int_setting (setting)) return PWQ_ERROR_UNKNOWN_SETTING;
  if (setting == PWQ_SETTING_MIN_LENGTH) value = clampi (value, 1, 128);
  pwq->ints[setting] = value;
  return 0;
}

int
pwquality_get_int_value (pwquality_settings_t *pwq, int setting, int *value)
{
  if (!pwq || !value) return PWQ_ERROR_FATAL_FAILURE;
  if (is_string_setting (setting)) return PWQ_ERROR_NON_INT_SETTING;
  if (!is_int_setting (setting)) return PWQ_ERROR_UNKNOWN_SETTING;
  *value = pwq->ints[setting];
  return 0;
}

int
pwquality_set_str_value (pwquality_settings_t *pwq, int setting, const char *value)
{
  if (!pwq) return PWQ_ERROR_FATAL_FAILURE;
  if (is_int_setting (setting)) return PWQ_ERROR_NON_STR_SETTING;
  if (!is_string_setting (setting)) return PWQ_ERROR_UNKNOWN_SETTING;
  char **field = setting == PWQ_SETTING_DICT_PATH ? &pwq->dict_path : &pwq->bad_words;
  char *copy = value ? strdup (value) : NULL;
  if (value && !copy) return PWQ_ERROR_MEM_ALLOC;
  free (*field);
  *field = copy;
  return 0;
}

int
pwquality_get_str_value (pwquality_settings_t *pwq, int setting, const char **value)
{
  if (!pwq || !value) return PWQ_ERROR_FATAL_FAILURE;
  if (is_int_setting (setting)) return PWQ_ERROR_NON_STR_SETTING;
  if (!is_string_setting (setting)) return PWQ_ERROR_UNKNOWN_SETTING;
  *value = setting == PWQ_SETTING_DICT_PATH ? pwq->dict_path : pwq->bad_words;
  return 0;
}

int
pwquality_set_option (pwquality_settings_t *pwq, const char *option)
{
  if (!pwq || !option) return PWQ_ERROR_FATAL_FAILURE;
  char *copy = strdup (option);
  if (!copy) return PWQ_ERROR_MEM_ALLOC;
  char *eq = strchr (copy, '=');
  if (eq) *eq++ = 0;
  char *key = copy;
  while (isspace ((unsigned char) *key)) key++;
  char *key_end = key + strlen (key);
  while (key_end > key && isspace ((unsigned char) key_end[-1])) *--key_end = 0;
  if (eq) while (isspace ((unsigned char) *eq)) eq++;

  struct { const char *name; int setting; } const names[] = {
    {"difok", PWQ_SETTING_DIFF_OK}, {"minlen", PWQ_SETTING_MIN_LENGTH},
    {"dcredit", PWQ_SETTING_DIG_CREDIT}, {"ucredit", PWQ_SETTING_UP_CREDIT},
    {"lcredit", PWQ_SETTING_LOW_CREDIT}, {"ocredit", PWQ_SETTING_OTH_CREDIT},
    {"minclass", PWQ_SETTING_MIN_CLASS}, {"maxrepeat", PWQ_SETTING_MAX_REPEAT},
    {"dictpath", PWQ_SETTING_DICT_PATH}, {"maxclassrepeat", PWQ_SETTING_MAX_CLASS_REPEAT},
    {"gecoscheck", PWQ_SETTING_GECOS_CHECK}, {"badwords", PWQ_SETTING_BAD_WORDS},
    {"maxsequence", PWQ_SETTING_MAX_SEQUENCE}, {"dictcheck", PWQ_SETTING_DICT_CHECK},
    {"usercheck", PWQ_SETTING_USER_CHECK}, {"enforcing", PWQ_SETTING_ENFORCING},
    {"retry", PWQ_SETTING_RETRY_TIMES}, {"enforceroot", PWQ_SETTING_ENFORCE_ROOT},
    {"localusers", PWQ_SETTING_LOCAL_USERS}, {"usersubstr", PWQ_SETTING_USER_SUBSTR},
  };
  int rc = PWQ_ERROR_UNKNOWN_SETTING;
  for (size_t i = 0; i < sizeof names / sizeof names[0]; i++)
    if (strcmp (key, names[i].name) == 0)
      {
        if (is_string_setting (names[i].setting))
          rc = eq ? pwquality_set_str_value (pwq, names[i].setting, eq) : PWQ_ERROR_NON_STR_SETTING;
        else
          rc = pwquality_set_int_value (pwq, names[i].setting, eq ? atoi (eq) : 1);
        break;
      }
  free (copy);
  return rc;
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
  if (oldpassword && pwq && pwq->ints[PWQ_SETTING_DIFF_OK] > 0)
    {
      size_t oldlen = strlen (oldpassword);
      size_t common = len < oldlen ? len : oldlen;
      int different = (int) (len > oldlen ? len - oldlen : oldlen - len);
      for (size_t i = 0; i < common; i++)
        if (password[i] != oldpassword[i]) different++;
      if (different < pwq->ints[PWQ_SETTING_DIFF_OK])
        return PWQ_ERROR_TOO_SIMILAR;
    }
  if ((!pwq || pwq->ints[PWQ_SETTING_USER_CHECK]) &&
      user && strlen (user) >= 3 && ascii_contains_ci (password, user))
    return PWQ_ERROR_USER_CHECK;
  int min = pwq ? pwq->ints[PWQ_SETTING_MIN_LENGTH] : 8;
  if ((int) len < min) return PWQ_ERROR_MIN_LENGTH;

  int lower = 0, upper = 0, digit = 0, other = 0, repeated_pairs = 0;
  int same_run = 1, max_same_run = 1;
  int class_run = 1, max_class_run = 1;
  int sequence_run = 1, max_sequence_run = 1, sequence_delta = 0;
  unsigned char seen[256] = {0};
  int unique = 0;
  for (size_t i = 0; i < len; i++)
    {
      unsigned char c = (unsigned char) password[i];
      if (!seen[c]++) unique++;
      if (i > 0)
        {
          unsigned char previous = (unsigned char) password[i - 1];
          if (c == previous)
            { repeated_pairs++; same_run++; }
          else
            same_run = 1;
          if (same_run > max_same_run) max_same_run = same_run;

          if (char_class (c) == char_class (previous)) class_run++;
          else class_run = 1;
          if (class_run > max_class_run) max_class_run = class_run;

          int delta = (int) tolower (c) - (int) tolower (previous);
          if ((delta == 1 || delta == -1) && (sequence_delta == 0 || delta == sequence_delta))
            sequence_run++;
          else
            sequence_run = 1;
          sequence_delta = (delta == 1 || delta == -1) ? delta : 0;
          if (sequence_run > max_sequence_run) max_sequence_run = sequence_run;
        }
      if (islower (c)) lower = 1;
      else if (isupper (c)) upper = 1;
      else if (isdigit (c)) digit = 1;
      else other = 1;
    }

  int classes = lower + upper + digit + other;
  if (pwq && pwq->ints[PWQ_SETTING_MIN_CLASS] > 0 &&
      classes < pwq->ints[PWQ_SETTING_MIN_CLASS])
    return PWQ_ERROR_MIN_CLASSES;
  if (classes < 2 && len < 14)
    return PWQ_ERROR_MIN_CLASSES;
  if (pwq && pwq->ints[PWQ_SETTING_MAX_REPEAT] > 0 &&
      max_same_run > pwq->ints[PWQ_SETTING_MAX_REPEAT])
    return PWQ_ERROR_MAX_CONSECUTIVE;
  if (pwq && pwq->ints[PWQ_SETTING_MAX_CLASS_REPEAT] > 0 &&
      max_class_run > pwq->ints[PWQ_SETTING_MAX_CLASS_REPEAT])
    return PWQ_ERROR_MAX_CLASS_REPEAT;
  if (pwq && pwq->ints[PWQ_SETTING_MAX_SEQUENCE] > 0 &&
      max_sequence_run > pwq->ints[PWQ_SETTING_MAX_SEQUENCE])
    return PWQ_ERROR_MAX_SEQUENCE;
  if (pwq && pwq->bad_words && *pwq->bad_words)
    {
      char *words = strdup (pwq->bad_words);
      if (!words) return PWQ_ERROR_MEM_ALLOC;
      for (char *word = strtok (words, " ,;:\t"); word; word = strtok (NULL, " ,;:\t"))
        if (*word && ascii_contains_ci (password, word))
          { free (words); return PWQ_ERROR_BAD_WORDS; }
      free (words);
    }

  int score = 0;
  score += clampi ((int) len * 5, 0, 45);
  score += classes * 12;
  score += clampi (unique * 2, 0, 20);
  score -= repeated_pairs * 5;
  return clampi (score, 0, 100);
}

int
pwquality_generate (pwquality_settings_t *pwq, int entropy_bits, char **password)
{
  if (!password) return PWQ_ERROR_FATAL_FAILURE;
  *password = NULL;

  int min = pwq ? pwq->ints[PWQ_SETTING_MIN_LENGTH] : 8;
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
    case PWQ_ERROR_TOO_SIMILAR:    msg = "The password is too similar to the old password"; break;
    case PWQ_ERROR_USER_CHECK:     msg = "The password contains the user name"; break;
    case PWQ_ERROR_MAX_CONSECUTIVE: msg = "The password contains too many repeated characters"; break;
    case PWQ_ERROR_MAX_CLASS_REPEAT: msg = "The password contains too many characters of the same class"; break;
    case PWQ_ERROR_MAX_SEQUENCE:   msg = "The password contains a sequence that is too long"; break;
    case PWQ_ERROR_MEM_ALLOC:      msg = "Memory allocation failed"; break;
    default:                       msg = "Password quality check unavailable"; break;
    }
  if (buf && len) { strncpy (buf, msg, len - 1); buf[len - 1] = 0; return buf; }
  return msg;
}
