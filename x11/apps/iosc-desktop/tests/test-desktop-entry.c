#include "../src/xios-desktop-entry.h"

#include <assert.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
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

static void test_raw_touch_key(void)
{
    char dir[] = "/tmp/xios-desktop-entry-raw.XXXXXX";
    assert(mkdtemp(dir));
    char path[1024];
    snprintf(path, sizeof(path), "%s/org.example.Game.desktop", dir);

    struct xios_desktop_entry entry;
    char error[256];

    /* Absent key: the default, current behavior. */
    write_entry(path, "Game", "game", NULL);
    assert(xios_desktop_entry_parse(path, NULL, 0, &entry, error, sizeof(error)));
    assert(entry.raw_touch == 0);

    FILE *f = fopen(path, "a");
    assert(f);
    fputs("X-Xios-RawTouch=true\n", f);
    assert(fclose(f) == 0);
    assert(xios_desktop_entry_parse(path, NULL, 0, &entry, error, sizeof(error)));
    assert(entry.raw_touch == 1);

    /* Only an explicit true opts in, and only inside [Desktop Entry]. */
    f = fopen(path, "w");
    assert(f);
    fputs("[Desktop Entry]\nType=Application\nName=Game\nExec=game\n"
          "X-Xios-RawTouch=false\n"
          "[Desktop Action other]\nX-Xios-RawTouch=true\n", f);
    assert(fclose(f) == 0);
    assert(xios_desktop_entry_parse(path, NULL, 0, &entry, error, sizeof(error)));
    assert(entry.raw_touch == 0);

    assert(unlink(path) == 0);
    assert(rmdir(dir) == 0);
}

static void test_file_id_validation(void)
{
    char long_id[300];
    memset(long_id, 'a', sizeof(long_id) - 1);
    long_id[sizeof(long_id) - 1] = 0;
    assert(xios_desktop_file_id_valid("org.gnome.Console"));
    assert(xios_desktop_file_id_valid("kde5-foo_bar+x"));
    assert(!xios_desktop_file_id_valid(""));
    assert(!xios_desktop_file_id_valid(".."));
    assert(!xios_desktop_file_id_valid("../bin/sh"));
    assert(!xios_desktop_file_id_valid("a/b"));
    assert(!xios_desktop_file_id_valid("a..b"));
    assert(!xios_desktop_file_id_valid(".hidden"));
    assert(!xios_desktop_file_id_valid("-x"));
    assert(!xios_desktop_file_id_valid("bad id"));
    assert(!xios_desktop_file_id_valid("bad\tid"));
    assert(!xios_desktop_file_id_valid("kgx; reboot"));
    assert(!xios_desktop_file_id_valid(long_id));
}

static void test_lookup_file_id(void)
{
    char root[] = "/tmp/xios-desktop-entry-id.XXXXXX";
    assert(mkdtemp(root));
    char usr[1024], share[1024], apps[1024], outside[1024];
    char wm[1024], plain[1024], hidden[1024], term[1024];
    snprintf(usr, sizeof(usr), "%s/usr", root);
    snprintf(share, sizeof(share), "%s/usr/share", root);
    snprintf(apps, sizeof(apps), "%s/usr/share/applications", root);
    snprintf(outside, sizeof(outside), "%s/outside", root);
    make_dir(usr); make_dir(share); make_dir(apps); make_dir(outside);

    /* StartupWMClass makes the app id "wmclass"; the file id is the basename */
    snprintf(wm, sizeof(wm), "%s/org.example.Wm.desktop", apps);
    write_entry(wm, "Wm", "wm-app --flag", "wmclass");
    snprintf(plain, sizeof(plain), "%s/plain.desktop", outside);
    write_entry(plain, "Outside", "outside-app", NULL);
    snprintf(hidden, sizeof(hidden), "%s/org.example.Hidden.desktop", apps);
    write_entry(hidden, "Hidden", "hidden-app", NULL);
    FILE *f = fopen(hidden, "a");
    assert(f);
    fputs("NoDisplay=true\n", f);
    assert(fclose(f) == 0);
    snprintf(term, sizeof(term), "%s/org.example.Term.desktop", apps);
    f = fopen(term, "w");
    assert(f);
    fputs("[Desktop Entry]\nType=Application\nName=Term\nExec=top\nTerminal=true\n", f);
    assert(fclose(f) == 0);

    struct xios_desktop_entry entry;
    char error[256];
    assert(xios_desktop_entry_lookup_file_id("org.example.Wm", root, 0, &entry,
                                             error, sizeof(error)));
    assert(strcmp(entry.exec, "wm-app --flag") == 0);
    assert(strcmp(entry.app_id, "wmclass") == 0);
    /* LAUNCH's app-id resolver does not find it by basename */
    assert(!xios_desktop_entry_resolve("org.example.Wm", root, 0, &entry,
                                       error, sizeof(error)));

    /* ids that would leave the application dir never reach the filesystem */
    assert(!xios_desktop_entry_lookup_file_id("../../outside/plain", root, 0,
                                              &entry, error, sizeof(error)));
    assert(strstr(error, "invalid") != NULL);
    assert(!xios_desktop_entry_lookup_file_id("..", root, 0, &entry,
                                              error, sizeof(error)));
    assert(!xios_desktop_entry_lookup_file_id("missing", root, 0, &entry,
                                              error, sizeof(error)));

    /* same visibility rules as LAUNCH */
    assert(!xios_desktop_entry_lookup_file_id("org.example.Hidden", root, 0,
                                              &entry, error, sizeof(error)));
    assert(!xios_desktop_entry_lookup_file_id("org.example.Term", root, 0,
                                              &entry, error, sizeof(error)));

    /* trust mode. Host-created files are not root-owned, so off root this
     * only shows the refusal; as root it also checks group-writable. */
    if (geteuid() != 0) {
        assert(!xios_desktop_entry_lookup_file_id("org.example.Wm", root, 1,
                                                  &entry, error, sizeof(error)));
        assert(strstr(error, "not trusted") != NULL);
    } else {
        assert(chown(root, 0, 0) == 0 && chown(usr, 0, 0) == 0);
        assert(chown(share, 0, 0) == 0 && chown(apps, 0, 0) == 0);
        assert(chmod(root, 0755) == 0);
        assert(chown(wm, 0, 0) == 0);
        assert(xios_desktop_entry_lookup_file_id("org.example.Wm", root, 1,
                                                 &entry, error, sizeof(error)));
        assert(chmod(wm, 0664) == 0);
        assert(!xios_desktop_entry_lookup_file_id("org.example.Wm", root, 1,
                                                  &entry, error, sizeof(error)));
        assert(strstr(error, "group/other-writable") != NULL);
    }

    assert(unlink(wm) == 0);
    assert(unlink(hidden) == 0);
    assert(unlink(term) == 0);
    assert(unlink(plain) == 0);
    assert(rmdir(outside) == 0);
    assert(rmdir(apps) == 0);
    assert(rmdir(share) == 0);
    assert(rmdir(usr) == 0);
    assert(rmdir(root) == 0);
}

/* Run `bash -c "exec <text>"` (how xios-session runs an app's command line)
 * and collect the words the command received, NUL-separated. */
static size_t bash_words(const char *text, char *out, size_t out_len)
{
    char script[16384];
    int pipefd[2];
    snprintf(script, sizeof(script), "exec %s", text);
    assert(pipe(pipefd) == 0);
    pid_t pid = fork();
    assert(pid >= 0);
    if (pid == 0) {
        dup2(pipefd[1], 1);
        close(pipefd[0]);
        close(pipefd[1]);
        execl("/bin/bash", "bash", "-c", script, (char *)NULL);
        _exit(127);
    }
    close(pipefd[1]);
    size_t got = 0;
    ssize_t n;
    while ((n = read(pipefd[0], out + got, out_len - got)) > 0) got += (size_t)n;
    close(pipefd[0]);
    int status = 0;
    assert(waitpid(pid, &status, 0) == pid);
    assert(WIFEXITED(status) && WEXITSTATUS(status) == 0);
    return got;
}

static void test_shell_text_round_trip(void)
{
    char *argv[] = {
        "/usr/bin/printf", "%s\\0",
        "two words", "it's", "\"double\"", "$HOME", "${PATH}", "`id`",
        "$(touch /tmp/xios-owned)", "line1\nline2", "a;b", "a&&b|c>d<e",
        "", "*", "~", "#comment", "back\\slash", "--opt=1", "plain", NULL,
    };
    char text[4096], words[4096], expect[4096];
    assert(xios_desktop_argv_shell_text(argv, text, sizeof(text)));
    size_t got = bash_words(text, words, sizeof(words));
    size_t want = 0;
    for (int i = 2; argv[i]; i++) {
        size_t n = strlen(argv[i]) + 1;
        memcpy(expect + want, argv[i], n);
        want += n;
    }
    assert(got == want && memcmp(words, expect, want) == 0);
    assert(access("/tmp/xios-owned", F_OK) != 0);

    /* a one-word command stays bare, so xios-session's app aliases still match */
    char *one[] = { "kgx", NULL };
    assert(xios_desktop_argv_shell_text(one, text, sizeof(text)));
    assert(strcmp(text, "kgx") == 0);
    char *two[] = { "gnome-text-editor", "--new-window", NULL };
    assert(xios_desktop_argv_shell_text(two, text, sizeof(text)));
    assert(strcmp(text, "gnome-text-editor --new-window") == 0);

    /* each quote takes four bytes: refuse rather than truncate */
    char *quotes[] = { "a'b'c'd'e", NULL };
    char small[16];
    assert(!xios_desktop_argv_shell_text(quotes, small, sizeof(small)));
    assert(xios_desktop_argv_shell_text(quotes, text, sizeof(text)));
    assert(strcmp(text, "'a'\\''b'\\''c'\\''d'\\''e'") == 0);
}

int main(void)
{
    test_app_id_validation();
    test_exec_parser();
    test_no_shell_interpretation();
    test_rejects_bad_field_code();
    test_parse_and_resolve();
    test_raw_touch_key();
    test_file_id_validation();
    test_lookup_file_id();
    test_shell_text_round_trip();
    puts("desktop-entry tests: ok");
    return 0;
}
