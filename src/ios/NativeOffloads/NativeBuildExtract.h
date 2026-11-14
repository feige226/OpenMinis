/* Shared by the iOS wrapper and host regression harness. */
#ifndef NB_EXTRACT_H
#define NB_EXTRACT_H
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <limits.h>
#include <stdlib.h>
struct archive;
struct archive_entry;
extern struct archive *archive_read_new(void);
extern int archive_read_support_filter_all(struct archive *);
extern int archive_read_support_format_tar(struct archive *);
extern int archive_read_open_filename(struct archive *, const char *, size_t);
extern int archive_read_next_header(struct archive *, struct archive_entry **);
extern const char *archive_entry_pathname(struct archive_entry *);
extern const char *archive_entry_symlink(struct archive_entry *);
extern const char *archive_entry_hardlink(struct archive_entry *);
extern ssize_t archive_read_data(struct archive *, void *, size_t);
extern const char *archive_error_string(struct archive *);
extern int archive_errno(struct archive *);
extern int archive_read_close(struct archive *);
extern int archive_read_free(struct archive *);
extern mode_t archive_entry_filetype(struct archive_entry *);
extern mode_t archive_entry_perm(struct archive_entry *);
typedef struct {
    int ok, error_number;
    unsigned long long entries, bytes, directories, symlinks;
    char stage[64], path[PATH_MAX], detail[512];
} NBExtractResult;
static void NBFailure(NBExtractResult *r, const char *stage, const char *path,
                      int err, const char *detail) {
    if (r->stage[0]) return; /* retain the first error before cleanup */
    snprintf(r->stage, sizeof(r->stage), "%s", stage);
    snprintf(r->path, sizeof(r->path), "%s", path ? path : "");
    r->error_number = err;
    snprintf(r->detail, sizeof(r->detail), "%s", detail ? detail : strerror(err));
}
/* Validate BEFORE stripping; discard empty slash components, never '..'. */
static int NBRelative(const char *raw, const char *strip, char *out) {
    if (!raw || !*raw || *raw == '/') return EINVAL;
    if (strlen(raw) >= PATH_MAX) return ENAMETOOLONG;
    char copy[PATH_MAX], *save = NULL;
    strcpy(copy, raw); out[0] = 0;
    int first = 1;
    for (char *p = strtok_r(copy, "/", &save); p; p = strtok_r(NULL, "/", &save)) {
        if (!strcmp(p, "..")) return EINVAL;
        if (!strcmp(p, ".")) continue;
        if (first && strip && *strip && !strcmp(p, strip)) { first = 0; continue; }
        first = 0;
        if (*out) strcat(out, "/");
        strcat(out, p);
    }
    return 0;
}
/* Relative symlinks may use '..' only while remaining within extraction root. */
static int NBLinkSafe(const char *sub, const char *link) {
    if (!link || !*link || *link == '/' || strlen(link) >= PATH_MAX) return 0;
    int depth = 0;
    for (const char *p = sub; *p; p++) if (*p == '/') depth++;
    char copy[PATH_MAX], *save = NULL; strcpy(copy, link);
    for (char *p = strtok_r(copy, "/", &save); p; p = strtok_r(NULL, "/", &save)) {
        if (!strcmp(p, "..")) { if (--depth < 0) return 0; }
        else if (strcmp(p, ".")) depth++;
    }
    return 1;
}
/* Every parent is opened without following links, including pre-existing ones. */
static int NBParent(int root, char *path, char **leaf) {
    int fd = dup(root);
    if (fd < 0) return -1;
    char *p = path, *slash;
    while ((slash = strchr(p, '/'))) {
        *slash = 0;
        if (mkdirat(fd, p, 0755) && errno != EEXIST) goto fail;
        int next = openat(fd, p, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        if (next < 0) goto fail;
        close(fd); fd = next; p = slash + 1;
    }
    *leaf = p; return fd;
fail: { int err = errno; close(fd); errno = err; return -1; }
}
static NBExtractResult NBExtractCore(const char *archivePath, const char *dest, const char *strip) {
    NBExtractResult r = {0};
    struct archive *a = archive_read_new();
    int root = -1, rc = 0;
    const char *raw = archivePath;
    if (!a) { NBFailure(&r, "archive_init", raw, ENOMEM, NULL); return r; }
#define NB_SYS(stage) NBFailure(&r, stage, raw, errno, NULL)
#define NB_AR(stage) NBFailure(&r, stage, raw, archive_errno(a), archive_error_string(a))
    if (archive_read_support_filter_all(a) < 0 || archive_read_support_format_tar(a) < 0) { NB_AR("archive_support"); goto done; }
    if (archive_read_open_filename(a, archivePath, 65536) != 0) { NB_AR("archive_open"); goto done; }
    root = open(dest, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (root < 0) { NB_SYS("dest_open"); goto done; }
    struct archive_entry *entry;
    while ((rc = archive_read_next_header(a, &entry)) == 0) {
        raw = archive_entry_pathname(entry);
        char sub[PATH_MAX];
        int err = NBRelative(raw, strip, sub);
        if (err) { NBFailure(&r, "path_validate", raw, err, "unsafe archive path"); break; }
        unsigned type = archive_entry_filetype(entry);
        if (!*sub) {
            if (type == S_IFDIR) { r.directories++; continue; }
            NBFailure(&r, "root_type", raw, EINVAL, "root entry is not a directory"); break;
        }
        if (archive_entry_hardlink(entry) || (type != S_IFDIR && type != S_IFREG && type != S_IFLNK)) {
            NBFailure(&r, "entry_type", raw, EINVAL, "unsupported entry type or hardlink"); break;
        }
        const char *link = archive_entry_symlink(entry);
        if (type == S_IFLNK && !NBLinkSafe(sub, link)) {
            NBFailure(&r, "symlink_validate", raw, EINVAL, "symlink escapes extraction root"); break;
        }
        char parents[PATH_MAX], *leaf; strcpy(parents, sub);
        int parent = NBParent(root, parents, &leaf);
        if (parent < 0) { NB_SYS("parent_open"); break; }
        if (type == S_IFDIR) {
            if (mkdirat(parent, leaf, 0755) && errno != EEXIST) NB_SYS("mkdir");
            else {
                int d = openat(parent, leaf, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
                if (d < 0) NB_SYS("directory_open");
                else { close(d); r.directories++; }
            }
        } else if (type == S_IFLNK) {
            /* Unlink only the leaf: never follow an old symlink during retries. */
            if (unlinkat(parent, leaf, 0) && errno != ENOENT) NB_SYS("symlink_unlink");
            else if (symlinkat(link, parent, leaf)) NB_SYS("symlink_create");
            else { r.symlinks++; r.entries++; }
        } else {
            /* Replace leaf rather than truncate an existing hardlink outside root. */
            if (unlinkat(parent, leaf, 0) && errno != ENOENT) NB_SYS("file_unlink");
            else {
                int f = openat(parent, leaf, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
                if (f < 0) NB_SYS("file_open");
                else {
                    char buf[65536]; ssize_t n;
                    while ((n = archive_read_data(a, buf, sizeof(buf))) > 0) {
                        ssize_t pos = 0;
                        while (pos < n) {
                            ssize_t w = write(f, buf + pos, (size_t)(n - pos));
                            if (w < 0 && errno == EINTR) continue;
                            if (w <= 0) { if (!w) errno = EIO; NB_SYS("file_write"); break; }
                            pos += w; r.bytes += (unsigned long long)w;
                        }
                        if (r.stage[0]) break;
                    }
                    if (n < 0) NB_AR("archive_data");
                    if (!r.stage[0] && fchmod(f, archive_entry_perm(entry) & 0777)) NB_SYS("file_chmod");
                    if (close(f)) NB_SYS("file_close");
                    if (!r.stage[0]) r.entries++;
                }
            }
        }
        close(parent);
        if (r.stage[0]) break;
    }
    if (!r.stage[0] && rc != 1) NB_AR("archive_header");
done:
    if (root >= 0) close(root);
    if (archive_read_close(a) != 0 && !r.stage[0]) NB_AR("archive_close");
    archive_read_free(a);
    r.ok = !r.stage[0];
#undef NB_SYS
#undef NB_AR
    return r;
}
#endif
