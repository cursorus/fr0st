//
//  darksword_drag.m
//
//  Adapted from kolbicz/DarkSword-Tweaks override_drag_coefficient.m
//  (licensed for use in projects including Cyanide per the upstream README).
//
//  Overrides _UIAnimationDragCoefficient in SpringBoard.
//  Values below 1.0 make SpringBoard animations faster; above 1.0 slower.
//  The SpringBoard RemoteCall session must be open before calling this.
//

#import "darksword_drag.h"
#import "../TaskRop/RemoteCall.h"

#import <dlfcn.h>
#import <stdint.h>
#import <stdbool.h>
#import <stdio.h>
#import <string.h>

typedef struct {
    uint64_t g, revVar, revOnce;
    uint32_t valOff, revOff;
} drag_t;

static uint64_t drag_strip_fp(void *p)
{
    uint64_t v = (uint64_t)p;
#if __has_feature(ptrauth_calls)
    if (v >> 47)
        v = (uint64_t)__builtin_ptrauth_strip((void *)v, 0);
#endif
    return v;
}

static bool drag_find(drag_t *o)
{
    void *fp = dlsym(RTLD_DEFAULT, "_SetUIAnimationDragCoefficient");
    if (!fp) { printf("[DRAG] _SetUIAnimationDragCoefficient not found\n"); return false; }

    uint64_t pc = drag_strip_fp(fp);
    const uint32_t *c = (const uint32_t *)pc;

    // Follow a single B/BL thunk if present.
    for (int i = 0; i < 4; i++) {
        if ((c[i] & 0xfc000000) == 0x14000000) {
            pc += (uint64_t)i * 4 + (int64_t)((int32_t)(c[i] << 6) >> 4);
            c = (const uint32_t *)pc;
            break;
        }
    }

    uint64_t pg[32] = {0}, pv[32] = {0}, g = 0, rV = 0, rO = 0;
    uint32_t vOff = 0, rOff = 0;

    for (int i = 0; i < 80; i++) {
        uint32_t in = c[i];
        int rd = in & 31, rn = (in >> 5) & 31;
        uint64_t ipc = pc + (uint64_t)i * 4;

        if ((in & 0x9f000000) == 0x90000000) {                        // ADRP
            int64_t lo = (in >> 29) & 3, hi = (in >> 5) & 0x7ffff;
            int64_t off = ((hi << 2) | lo) << 12; off = (off << 31) >> 31;
            pg[rd] = (ipc & ~0xfffULL) + off; pv[rd] = 0;
        } else if ((in & 0xff800000) == 0x91000000 && pg[rn]) {       // ADD imm
            pv[rd] = pg[rn] + ((in >> 10) & 0xfff);
        } else if ((in & 0xffc00000) == 0xf9400000 && pg[rn] && !rO) {
            rO = pg[rn] + (((in >> 10) & 0xfff) << 3);                // 1st LDR Xt -> revOnce
        } else if ((in & 0xffc00000) == 0xb9400000 && pg[rn] && !rV) {
            rV = pg[rn] + (((in >> 10) & 0xfff) << 2);                // 1st LDR Wt -> revVar
        } else if ((in & 0xff800000) == 0xfd000000 && pv[rn] && !g) { // STR/LDR Dt,[Xn,#v]
            g = pv[rn]; vOff = ((in >> 10) & 0xfff) << 3;
        } else if ((in & 0xff800000) == 0xb9000000 && g && pv[rn] == g) {
            rOff = ((in >> 10) & 0xfff) << 2;                         // W store -> slotRev off
            break;
        }
    }

    if (!g || !rV || !rO || (rO != rV + 8 && rV != rO + 8)) return false;
    o->g = g; o->revVar = rV; o->revOnce = rO;
    o->valOff = vOff ? vOff : 8; o->revOff = rOff;
    return true;
}

bool darksword_drag_coefficient_apply(double coefficient)
{
    drag_t d;
    if (!drag_find(&d)) {
        printf("[DRAG] find failed\n");
        return false;
    }

    uint32_t rv = 0;
    remote_read(d.revVar, &rv, 4);
    if ((int)rv < 1) { uint32_t one = 1; remote_write(d.revVar, &one, 4); rv = 1; }

    union { double dv; uint64_t u; } b = { .dv = coefficient };
    uint32_t sentinel = 0x7fffffff;

    remote_write(d.g + d.revOff, &sentinel, 4);
    remote_write(d.g + d.valOff, &b.u, 8);

    double chk = 0; uint32_t sr = 0;
    remote_read(d.g + d.valOff, &chk, 8);
    remote_read(d.g + d.revOff, &sr, 4);
    printf("[DRAG] g=0x%llx revVar=%u value=%.4f slotRev=0x%x\n",
           (unsigned long long)d.g, rv, chk, sr);
    return true;
}
