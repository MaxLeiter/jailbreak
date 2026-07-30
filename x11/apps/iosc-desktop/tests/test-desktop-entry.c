#include "../src/xios-desktop-entry.h"

#include <assert.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static void make_dir(const char *path)
{
    assert(mkdir(path, 0755) == 0 || errno == EEXIST);
}

static void write_entry(const char *path, const char *name,
                        const char *exec, const char *startup)
{
    FILE *f = fopen(path, "w");
    assert(f);
    fprintf(f, "[Desktop Entry]\nType=Application\nName=%s\nExec=%s\n",
            name, exec);
    if (startup) fprintf(f, "StartupWMClass=%s\n", startup);
    assert(fclose(f) == 0);
    assert(chmod(path, 0644) == 0);
}

static void test_app_id_validation(void)
{
    assert(xios_desktop_app_id_valid("org.gnome.Console"));
    assert(!xios_desktop_app_id_valid(""));
    assert(!xios_desktop_app_id_valid("../bin/sh"));
    assert(!xios_desktop_app_id_valid("bad\tid"));
    assert(!xios_desktop_app_id_valid("bad id"));
}

static void test_exec_parser(void)
{
    struct xios_desktop_entry entry = {0};
    strcpy(entry.exec,
           "demo --name \"two words\" --class 'literal class' %% %c %k %%f %U");
    strcpy(entry.name, "Demo App");
    strcpy(entry.desktop_path, "/trusted/demo.desktop");

    char *argv[XIOS_DESKTOP_ARG_MAX];
    char storage[XIOS_DESKTOP_ARG_STORAGE];
    char error[256];
    int argc = xios_desktop_entry_argv(&entry, argv, XIOS_DESKTOP_ARG_MAX,
                                       storage, sizeof(storage), error, sizeof(error));
    assert(argc == 9);
    assert(strcmp(argv[0], "demo") == 0);
    assert(strcmp(argv[2], "two words") == 0);
    assert(strcmp(argv[4], "literal class") == 0);
    assert(strcmp(argv[5], "%") == 0);
    assert(strcmp(argv[6], "Demo App") == 0);
    assert(strcmp(argv[7], "/trusted/demo.desktop") == 0);
    assert(strcmp(argv[8], "%f") == 0);
    assert(argv[9] == NULL);
}

static void test_no_shell_interpretation(void)
{
    struct xios_desktop_entry entry = {0};
    strcpy(entry.exec, "demo \"$(touch /tmp/owned)\" ';reboot'");
    char *argv[XIOS_DESKTOP_ARG_MAX];
    char storage[XIOS_DESKTOP_ARG_STORAGE];
    char error[256];
    int argc = xios_desktop_entry_argv(&entry, argv, XIOS_DESKTOP_ARG_MAX,
                                       storage, sizeof(storage), error, sizeof(error));
    assert(argc == 3);
    assert(strcmp(argv[1], "$(touch /tmp/owned)") == 0);
    assert(strcmp(argv[2], ";reboot") == 0);
}

static void test_rejects_bad_field_code(void)
{
    struct xios_desktop_entry entry = {0};
    strcpy(entry.exec, "demo %Z");
    char *argv[XIOS_DESKTOP_ARG_MAX];
    char storage[XIOS_DESKTOP_ARG_STORAGE];
    char error[256];
    assert(xios_desktop_entry_argv(&entry, argv, XIOS_DESKTOP_ARG_MAX,
                                   storage, sizeof(storage), error, sizeof(error)) == 0);
    assert(strstr(error, "unsupported") != NULL);
}

static void test_parse_and_resolve(void)
{
    char root[] = "/tmp/xios-desktop-entry.XXXXXX";
    assert(mkdtemp(root));
    char usr[1024], local[1024], share[1024], apps[1024], path[1024];

    snprintf(usr, sizeof(usr), "%s/usr", root);
    snprintf(local, sizeof(local), "%s/usr/local", root);
    snprintf(share, sizeof(share), "%s/usr/local/share", root);
    snprintf(apps, sizeof(apps), "%s/usr/local/share/applications", root);
    make_dir(usr); make_dir(local); make_dir(share); make_dir(apps);

    snprintf(path, sizeof(path), "%s/org.example.Demo.desktop", apps);
    write_entry(path, "Demo", "demo --safe", NULL);

    struct xios_desktop_entry entry;
    char error[256];
    assert(xios_desktop_entry_resolve("org.example.Demo", root, 0, &entry,
                                      error, sizeof(error)));
    assert(strcmp(entry.exec, "demo --safe") == 0);
    assert(!xios_desktop_entry_resolve("../bin/sh", root, 0, &entry,
                                       error, sizeof(error)));

    /* Host-created files are intentionally rejected by the daemon trust mode. */
    if (geteuid() != 0)
        assert(!xios_desktop_entry_resolve("org.example.Demo", root, 1, &entry,
                                           error, sizeof(error)));

    assert(unlink(path) == 0);
    assert(rmdir(apps) == 0);
    assert(rmdir(share) == 0);
    assert(rmdir(local) == 0);
    assert(rmdir(usr) == 0);
    assert(rmdir(root) == 0);
}

int main(void)
{
    test_app_id_validation();
    test_exec_parser();
    test_no_shell_interpretation();
    test_rejects_bad_field_code();
    test_parse_and_resolve();
    puts("desktop-entry tests: ok");
    return 0;
}
