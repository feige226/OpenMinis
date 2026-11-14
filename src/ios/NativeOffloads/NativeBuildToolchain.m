#import "NativeBuildToolchain.h"
#include <unistd.h>
#include <sys/stat.h>

#include "NativeBuildMachO.inc"

static BOOL NBExecutableFile(NSString *path) {
    if (path.length == 0) return NO;
    const char *p = path.fileSystemRepresentation;
    struct stat st;
    if (stat(p, &st) != 0 || !S_ISREG(st.st_mode)) return NO;
    return access(p, X_OK) == 0;
}

NSString *NBToolchainRoot(void) {
    // Same writable location used by the provision command.
    NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:@"minis-toolchain"];
    return root;
}

NBToolchainProbe NBToolchainCheck(NSString *root) {
    NBToolchainProbe r = {0};
    if (root.length == 0) root = NBToolchainRoot();
    if (root.length == 0) return r;
    r.clang = NBExecutableFile([root stringByAppendingPathComponent:@"bin/clang"]);
    r.ld    = NBExecutableFile([root stringByAppendingPathComponent:@"bin/ld"]);
    r.ldid  = NBExecutableFile([root stringByAppendingPathComponent:@"bin/ldid"]);
    // Provision retains the SDK directory under the writable toolchain root.
    NSString *archive = [root stringByAppendingPathComponent:@"iPhoneOS16.5.sdk/SDKSettings.plist"];
    r.sdk = archive.length > 0 && access(archive.fileSystemRepresentation, R_OK) == 0;
    r.resourceDir = (access([[root stringByAppendingPathComponent:@"lib/clang/23/include"]
                              fileSystemRepresentation], R_OK) == 0);
    return r;
}

NSDictionary *NBToolchainDescribe(NSString *root) {
    if (root.length == 0) root = NBToolchainRoot();
    NBToolchainProbe p = NBToolchainCheck(root);
    BOOL present = p.clang || p.ld || p.ldid || p.sdk || p.resourceDir;
    return @{
        @"root": root ?: @"",
        @"present": @(present),
        @"clang": @(p.clang),
        @"ld": @(p.ld),
        @"ldid": @(p.ldid),
        @"sdk": @(p.sdk),
        @"resource_dir": @(p.resourceDir),
        @"ready": @(p.clang && p.ld && p.ldid && p.sdk && p.resourceDir),
        @"sdk_mode": @"provisioned-sdk-directory",
        @"note": @"ready only means every expected path exists and is executable; "
                 @"run the probe tests on this installation before claiming a build."
    };
}
