#import "NativeBuildProvision.h"
#include <sys/stat.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>

/* libarchive is already linked (ZIP export uses it). No <archive.h> in this SDK,
 * so the handful of entry points are declared here. */
struct archive;
struct archive_entry;
extern struct archive *archive_read_new(void);
extern int archive_read_support_filter_all(struct archive *);
extern int archive_read_support_format_tar(struct archive *);
extern int archive_read_open_filename(struct archive *, const char *, size_t);
extern int archive_read_next_header(struct archive *, struct archive_entry **);
extern const char *archive_entry_pathname(struct archive_entry *);
extern long archive_read_data(struct archive *, void *, size_t);
extern const char *archive_error_string(struct archive *);
extern int archive_errno(struct archive *);
extern int archive_read_close(struct archive *);
extern int archive_read_free(struct archive *);
extern unsigned int archive_entry_filetype(struct archive_entry *);
extern unsigned int archive_entry_perm(struct archive_entry *);

static BOOL NBUnsafePath(NSString *rel) {
    if (rel.length == 0) return YES;
    if ([rel hasPrefix:@"/"]) return YES;
    for (NSString *c in rel.pathComponents)
        if ([c isEqualToString:@".."]) return YES;
    return NO;
}

NSDictionary *NBExtractArchive(NSString *archivePath, NSString *destDir,
                               NSString *stripFirstComponent) {
    NSMutableDictionary *out = [@{ @"ok": @NO, @"entries": @0, @"bytes": @0,
                                   @"error": @"" } mutableCopy];
    if (!archivePath || !destDir) { out[@"error"] = @"missing arguments"; return out; }
    if (![[NSFileManager defaultManager] fileExistsAtPath:archivePath]) {
        out[@"error"] = @"archive not bundled"; return out;
    }

    struct archive *a = archive_read_new();
    if (!a) { out[@"error"] = @"archive_init_failed"; return out; }
    archive_read_support_filter_all(a);
    archive_read_support_format_tar(a);
    if (archive_read_open_filename(a, archivePath.fileSystemRepresentation, 1 << 16) != 0) {
        out[@"error"] = [NSString stringWithFormat:@"open: %s",
                         archive_error_string(a) ?: "unknown"];
        archive_read_free(a);
        return out;
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *mkdirError = nil;
    if (![fm createDirectoryAtPath:destDir withIntermediateDirectories:YES
                           attributes:nil error:&mkdirError]) {
        out[@"error"] = [NSString stringWithFormat:@"dest: %@", mkdirError.localizedDescription];
        archive_read_free(a);
        return out;
    }

    unsigned long long entries = 0, bytes = 0;
    struct archive_entry *entry = NULL;
    int rc = 0;
    BOOL ok = YES;
    char buf[1 << 16];

    while (ok && (rc = archive_read_next_header(a, &entry)) == 0) {
        const char *raw = archive_entry_pathname(entry);
        NSString *rel = raw ? [NSString stringWithUTF8String:raw] : nil;
        if (!rel) { ok = NO; break; }

        /* Drop the archive's leading component (e.g. "Toolchain/"). */
        NSArray<NSString *> *parts = rel.pathComponents;
        if (stripFirstComponent.length && parts.count &&
            [parts.firstObject isEqualToString:stripFirstComponent]) {
            parts = [parts subarrayWithRange:NSMakeRange(1, parts.count - 1)];
        }
        if (parts.count == 0) continue;              /* the root dir entry itself */
        NSString *sub = [parts componentsJoinedByString:@"/"];
        if (NBUnsafePath(sub)) { ok = NO; break; }   /* refuse traversal */

        NSString *target = [destDir stringByAppendingPathComponent:sub];
        unsigned type = archive_entry_filetype(entry);

        if (type == S_IFDIR || [rel hasSuffix:@"/"]) {
            if (![fm createDirectoryAtPath:target withIntermediateDirectories:YES
                                attributes:nil error:nil]) { ok = NO; break; }
            continue;
        }

        if (![fm createDirectoryAtPath:target.stringByDeletingLastPathComponent
                  withIntermediateDirectories:YES attributes:nil error:nil]) { ok = NO; break; }

        FILE *f = fopen(target.fileSystemRepresentation, "wb");
        if (!f) { ok = NO; break; }
        long n;
        while ((n = archive_read_data(a, buf, sizeof(buf))) > 0) {
            if (fwrite(buf, 1, (size_t)n, f) != (size_t)n) { ok = NO; break; }
            bytes += (unsigned long long)n;
        }
        if (n < 0) ok = NO;
        if (fclose(f) != 0) ok = NO;

        /* Preserve the executable bit: an extracted compiler without +x is a
         * deployment that "succeeded" and still cannot run. */
        unsigned perm = archive_entry_perm(entry) & 0777;
        if (!perm) perm = (type == S_IFREG) ? 0644 : 0755;
        chmod(target.fileSystemRepresentation, perm);
        entries++;
    }
    if (ok && rc != 1) {                            /* 1 == ARCHIVE_EOF */
        out[@"error"] = [NSString stringWithFormat:@"read: %s",
                         archive_error_string(a) ?: "unknown"];
        ok = NO;
    }
    if (!ok && [out[@"error"] length] == 0) {
        out[@"error"] = [NSString stringWithFormat:@"extract stopped (errno=%d): %s",
                         archive_errno(a), archive_error_string(a) ?: "unknown"];
    }
    archive_read_close(a);
    archive_read_free(a);

    out[@"ok"] = @(ok);
    out[@"entries"] = @(entries);
    out[@"bytes"] = @(bytes);
    return out;
}
