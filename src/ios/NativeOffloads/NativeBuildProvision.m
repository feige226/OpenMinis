#import "NativeBuildProvision.h"
#include "NativeBuildExtract.h"

NSDictionary *NBExtractArchive(NSString *archivePath, NSString *destDir,
                               NSString *stripFirstComponent) {
    if (!archivePath.length || !destDir.length)
        return @{ @"ok": @NO, @"entries": @0, @"bytes": @0,
                  @"stage": @"arguments", @"path": @"", @"errno": @(EINVAL),
                  @"error": @"missing arguments" };
    NSError *error = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:destDir
                                  withIntermediateDirectories:YES attributes:nil error:&error]) {
        return @{ @"ok": @NO, @"entries": @0, @"bytes": @0,
                  @"stage": @"dest_mkdir", @"path": destDir,
                  @"error": error.localizedDescription ?: @"destination creation failed",
                  @"error_domain": error.domain ?: @"", @"error_code": @(error.code) };
    }
    NBExtractResult r = NBExtractCore(archivePath.fileSystemRepresentation,
                                     destDir.fileSystemRepresentation,
                                     stripFirstComponent.UTF8String);
    NSString *stage = [NSString stringWithUTF8String:r.stage] ?: @"";
    NSString *path = [NSString stringWithUTF8String:r.path] ?: @"<invalid UTF-8>";
    NSString *detail = [NSString stringWithUTF8String:r.detail] ?: @"<invalid UTF-8>";
    return @{ @"ok": @(r.ok), @"entries": @(r.entries), @"bytes": @(r.bytes),
              @"directories": @(r.directories), @"symlinks": @(r.symlinks),
              @"stage": stage, @"path": path, @"errno": @(r.error_number),
              @"error": r.ok ? @"" : [NSString stringWithFormat:@"%@: %@ (errno=%d): %@",
                                      stage, path, r.error_number, detail] };
}
