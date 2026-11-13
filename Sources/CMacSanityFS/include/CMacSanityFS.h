//  CMacSanityFS.h — fast, safe directory sizing for the cleaner.

#ifndef CMacSanityFS_h
#define CMacSanityFS_h

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Totals for one walked tree.
typedef struct {
    uint64_t allocated;   ///< bytes on disk (what `du` reports); hard links counted once
    uint64_t logical;     ///< file lengths
    uint64_t files;
    uint64_t directories;
    int64_t  newestModification;  ///< newest mtime (Unix seconds) of anything inside, 0 if empty
    uint64_t unreadable;  ///< directories that couldn't be opened (permissions / TCC)
} MSTreeSize;

/// Called in post-order for every node whose allocated size is at least the
/// walk's threshold (the root is always reported, at depth 0). Children are
/// reported before their parent, so a tree can be rebuilt from (depth, node)
/// pairs with one pending-children list per depth.
typedef void (*MSNodeCallback)(void * _Nullable context, int depth, const char * _Nonnull name,
                               bool isDirectory, const MSTreeSize * _Nonnull size);

/// Walk `path` recursively and return its totals.
///
/// - Never follows symbolic links (they count as their own tiny size).
/// - Never crosses into another file system (mounted volumes, disk images).
/// - Hard-linked files are counted once per walk.
/// - Holds at most one directory descriptor open at a time.
/// - `cancel` (optional) is polled between directories; when it becomes true the
///   walk stops early and returns false.
///
/// `callback` may be NULL (totals only). Returns false if the root couldn't be
/// read or the walk was cancelled.
bool MSWalkTree(const char * _Nonnull path, uint64_t reportThreshold,
                MSNodeCallback _Nullable callback, void * _Nullable context,
                const volatile bool * _Nullable cancel, MSTreeSize * _Nonnull out);

#ifdef __cplusplus
}
#endif

#endif /* CMacSanityFS_h */
