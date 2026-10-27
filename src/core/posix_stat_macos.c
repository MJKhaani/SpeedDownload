/* Darwin's sys/stat.h selects the correct symbol and struct stat layout for
 * the active SDK. Keep the C ABI surface narrow and pass only scalar data. */
#include <stdint.h>
#include <sys/stat.h>

int speed_download_macos_stat(const char *path, int follow_symlinks,
                              uint32_t *uid, uint32_t *mode,
                              uint64_t *device, uint64_t *inode) {
    struct stat status;
    int result = follow_symlinks ? stat(path, &status) : lstat(path, &status);
    if (result != 0) return result;
    *uid = (uint32_t)status.st_uid;
    *mode = (uint32_t)status.st_mode;
    *device = (uint64_t)status.st_dev;
    *inode = (uint64_t)status.st_ino;
    return 0;
}
