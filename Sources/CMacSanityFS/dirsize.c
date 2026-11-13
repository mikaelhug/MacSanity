//  dirsize.c — recursive sizing with getattrlistbulk(2).
//
//  getattrlistbulk returns names, types and sizes for a whole directory in a few
//  syscalls (vs. a stat per entry), which makes it several times faster than
//  FileManager enumeration on trees like node_modules or Rust target/ folders.

#include "CMacSanityFS.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/attr.h>
#include <sys/param.h>
#include <sys/stat.h>
#include <sys/vnode.h>
#include <unistd.h>

// ---- Hard-link set: open addressing over (dev, inode) ------------------------

typedef struct { uint64_t *keys; size_t cap; size_t count; } LinkSet;

static uint64_t link_key(uint32_t dev, uint64_t ino) { return (ino * 0x9E3779B97F4A7C15ull) ^ dev; }

/// Returns true if newly inserted (first time this inode is seen).
static bool linkset_insert(LinkSet *s, uint64_t key) {
    if (key == 0) key = 1;   // 0 marks empty slots
    if ((s->count + 1) * 2 > s->cap) {
        size_t ncap = s->cap ? s->cap * 2 : 1024;
        uint64_t *nk = calloc(ncap, sizeof(uint64_t));
        if (!nk) return true;   // out of memory: count it (over-count beats crashing)
        for (size_t i = 0; i < s->cap; i++) {
            uint64_t k = s->keys[i];
            if (!k) continue;
            size_t j = k & (ncap - 1);
            while (nk[j]) j = (j + 1) & (ncap - 1);
            nk[j] = k;
        }
        free(s->keys);
        s->keys = nk;
        s->cap = ncap;
    }
    size_t i = key & (s->cap - 1);
    while (s->keys[i]) {
        if (s->keys[i] == key) return false;
        i = (i + 1) & (s->cap - 1);
    }
    s->keys[i] = key;
    s->count++;
    return true;
}

// ---- Walk --------------------------------------------------------------------

typedef struct {
    uint64_t threshold;
    MSNodeCallback callback;
    void *context;
    const volatile bool *cancel;
    uint32_t rootDevice;
    LinkSet links;
    char *buffer;        // getattrlistbulk buffer (reused)
    size_t bufferSize;
    bool cancelled;
} Walk;

typedef struct {
    char name[NAME_MAX + 1];
} ChildDir;

static void add(MSTreeSize *into, const MSTreeSize *from) {
    into->allocated += from->allocated;
    into->logical += from->logical;
    into->files += from->files;
    into->directories += from->directories;
    into->unreadable += from->unreadable;
    if (from->newestModification > into->newestModification) into->newestModification = from->newestModification;
}

/// Size the directory at `path` (already known to be a directory on rootDevice).
/// Returns false if it couldn't be opened.
static bool walk_dir(Walk *w, const char *path, int depth, MSTreeSize *out) {
    memset(out, 0, sizeof(*out));
    out->directories = 1;
    if (w->cancel && *w->cancel) { w->cancelled = true; return false; }

    int fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) { out->unreadable = 1; return false; }

    struct attrlist attrs = {0};
    attrs.bitmapcount = ATTR_BIT_MAP_COUNT;
    attrs.commonattr = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_NAME | ATTR_CMN_DEVID | ATTR_CMN_OBJTYPE
                     | ATTR_CMN_MODTIME | ATTR_CMN_FILEID;
    attrs.fileattr = ATTR_FILE_LINKCOUNT | ATTR_FILE_ALLOCSIZE | ATTR_FILE_DATALENGTH;

    // Subdirectories are collected first and walked after the descriptor is
    // closed, so a deep tree never holds more than one directory open.
    ChildDir *subdirs = NULL;
    size_t subCount = 0, subCap = 0;

    for (;;) {
        int n = getattrlistbulk(fd, &attrs, w->buffer, w->bufferSize, FSOPT_PACK_INVAL_ATTRS);
        if (n <= 0) break;   // 0 = done, -1 = error (treat what we have as the result)
        char *entry = w->buffer;
        for (int i = 0; i < n; i++) {
            char *p = entry;
            uint32_t length = *(uint32_t *)p; p += sizeof(uint32_t);
            attribute_set_t returned = *(attribute_set_t *)p; p += sizeof(attribute_set_t);

            attrreference_t nameRef = *(attrreference_t *)p;
            const char *name = p + nameRef.attr_dataoffset;
            p += sizeof(attrreference_t);
            uint32_t dev = *(dev_t *)p; p += sizeof(dev_t);
            fsobj_type_t type = *(fsobj_type_t *)p; p += sizeof(fsobj_type_t);
            struct timespec mtime = *(struct timespec *)p; p += sizeof(struct timespec);
            uint64_t fileID = *(uint64_t *)p; p += sizeof(uint64_t);

            if (mtime.tv_sec > out->newestModification) out->newestModification = mtime.tv_sec;

            if (type == VDIR) {
                if (dev == w->rootDevice) {   // never cross into another volume
                    if (subCount == subCap) {
                        subCap = subCap ? subCap * 2 : 16;
                        ChildDir *grown = realloc(subdirs, subCap * sizeof(ChildDir));
                        if (!grown) { subCap = subCount; entry += length; continue; }
                        subdirs = grown;
                    }
                    strlcpy(subdirs[subCount++].name, name, NAME_MAX + 1);
                }
            } else {
                // Regular files, symlinks (their own size only), and others.
                uint32_t links = 1;
                uint64_t alloc = 0, logical = 0;
                if (returned.fileattr & ATTR_FILE_LINKCOUNT) links = *(uint32_t *)p;
                p += sizeof(uint32_t);
                if (returned.fileattr & ATTR_FILE_ALLOCSIZE) alloc = (uint64_t)*(off_t *)p;
                p += sizeof(off_t);
                if (returned.fileattr & ATTR_FILE_DATALENGTH) logical = (uint64_t)*(off_t *)p;
                p += sizeof(off_t);

                if (links > 1 && !linkset_insert(&w->links, link_key(dev, fileID))) {
                    // Another name of a file already counted.
                } else {
                    out->allocated += alloc;
                    out->logical += logical;
                    out->files += 1;
                    if (w->callback && alloc >= w->threshold) {
                        MSTreeSize f = { alloc, logical, 1, 0, mtime.tv_sec, 0 };
                        w->callback(w->context, depth + 1, name, false, &f);
                    }
                }
            }
            entry += length;
        }
    }
    close(fd);

    char child[PATH_MAX];
    for (size_t i = 0; i < subCount && !w->cancelled; i++) {
        int len = snprintf(child, sizeof(child), "%s/%s", path, subdirs[i].name);
        if (len <= 0 || (size_t)len >= sizeof(child)) { out->unreadable += 1; continue; }
        MSTreeSize sub;
        walk_dir(w, child, depth + 1, &sub);
        add(out, &sub);
        if (w->callback && sub.allocated >= w->threshold && !w->cancelled) {
            w->callback(w->context, depth + 1, subdirs[i].name, true, &sub);
        }
    }
    free(subdirs);
    return !w->cancelled;
}

bool MSWalkTree(const char *path, uint64_t reportThreshold, MSNodeCallback callback, void *context,
                const volatile bool *cancel, MSTreeSize *out) {
    memset(out, 0, sizeof(*out));
    struct stat st;
    if (lstat(path, &st) != 0) return false;

    const char *base = strrchr(path, '/');
    base = (base && base[1]) ? base + 1 : path;

    if (!S_ISDIR(st.st_mode)) {
        // A single file (or symlink — its own size, never the target's).
        out->allocated = (uint64_t)st.st_blocks * 512;
        out->logical = (uint64_t)st.st_size;
        out->files = 1;
        out->newestModification = st.st_mtimespec.tv_sec;
        if (callback) callback(context, 0, base, false, out);
        return true;
    }

    Walk w = {0};
    w.threshold = reportThreshold;
    w.callback = callback;
    w.context = context;
    w.cancel = cancel;
    w.rootDevice = (uint32_t)st.st_dev;
    w.bufferSize = 256 * 1024;
    w.buffer = malloc(w.bufferSize);
    if (!w.buffer) return false;

    bool ok = walk_dir(&w, path, 0, out);
    if (callback && !w.cancelled) callback(context, 0, base, true, out);

    free(w.buffer);
    free(w.links.keys);
    return ok && !w.cancelled;
}
