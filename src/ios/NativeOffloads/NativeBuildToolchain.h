/* [T-native-build] Runtime toolchain discovery for minis-native-build.
 *
 * Device-verified layout (probe v8/v9, iOS 16.4.1): the exact same steps —
 * clang + iPhoneOS SDK + ld + ldid staged under the app bundle and executed
 * through NBPRun — produced, signed and exported an installable IPA.
 *
 * This header/impl only *locates and describes* a staged toolchain. It never
 * downloads, never installs into PATH and never claims a compiler works because
 * a file exists: every check is a stat/access probe plus the caller's optional
 * live `--version` run, and `ready` means "paths present and executable".
 */
#ifndef MINIS_NATIVE_BUILD_TOOLCHAIN_H
#define MINIS_NATIVE_BUILD_TOOLCHAIN_H

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    BOOL clang, ld, ldid, sdk, resourceDir;
} NBToolchainProbe;

/* Root of a staged toolchain inside the app bundle. Returns nil when the app
 * was built without one (normal App Store build: nothing is bundled). */
NSString *NBToolchainRoot(void);

/* [T-native-build] Writable toolchain staging area. Always <Data>/Library/Caches
 * /native-toolchain/<name>. Never the app tmp dir: iOS rejects exec there
 * (access X_OK and posix_spawn return EPERM) regardless of entitlements.
 * Creates the directory and returns its child `name`, or nil on failure. */
NSString *NBSearchPathForSharedCache(NSString *name);

/* Stat/access the layout rooted at `root` (nil → NBToolchainRoot()). */
NBToolchainProbe NBToolchainCheck(NSString *root);

/* Human/JSON-ready description. Never runs anything. */
NSDictionary *NBToolchainDescribe(NSString *root);
/* Independent host lstat/stat/access observations; never gates a launch. */
NSDictionary *NBPathDiagnostics(NSString *path);

/* [T-native-build] Artifact inspection: parse a Mach-O far enough to answer
 * "did the tool actually produce the right thing?", so no build step is ever
 * accepted on exit status alone. Read-only; the file is never executed and no
 * signature is cryptographically verified — only the LC_CODE_SIGNATURE region.
 *
 * Keys: path, exists, valid, size, arch (arm64/x86_64/other), filetype
 * (object/executable/dylib/...), pie, has_main, has_ios_build, min_ios,
 * has_code_signature, signature_size, error ("" when valid). */
NSDictionary *NBMachOInspect(NSString *path);

#ifdef __cplusplus
}
#endif

#endif /* MINIS_NATIVE_BUILD_TOOLCHAIN_H */
