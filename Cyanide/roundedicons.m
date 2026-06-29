//
//  roundedicons.m
//  Fr0st — smooth corner radius on every home screen icon.
//
//  Architecture mirrors themer.m: uses sb_walk to collect
//  all SBIconViews, then applies cornerRadius to _iconImageView.layer.
//  No image swapping. No overlays. Just shape.
//

#import "roundedicons.h"
#import "remote_objc.h"
#import "sb_walk.h"
#import "TaskRop/RemoteCall.h"

#import <Foundation/Foundation.h>
#import <stdio.h>

// Default radius multiplier — matches Apple's superellipse (~22.5% of width).
// iOS default icon corner = ~27%, Apple Watch = ~50% (full circle).
static const float kRoundedDefaultMultiplier = 0.225f;

static bool rounded_apply_to_iconview(uint64_t iconView, float multiplier)
{
    if (!r_is_objc_ptr(iconView)) return false;

    // Get _iconImageView — this is where the actual icon pixels live.
    uint64_t iiv = r_ivar_value(iconView, "_iconImageView");
    if (!r_is_objc_ptr(iiv) && r_responds_main(iconView, "_iconImageView")) {
        iiv = r_msg2_main(iconView, "_iconImageView", 0, 0, 0, 0);
    }
    if (!r_is_objc_ptr(iiv)) return false;

    // Get the layer of _iconImageView.
    if (!r_responds_main(iiv, "layer")) return false;
    uint64_t layer = r_msg2_main(iiv, "layer", 0, 0, 0, 0);
    if (!r_is_objc_ptr(layer)) return false;

    // Read current bounds to calculate radius from actual icon width.
    struct { double x, y, w, h; } bounds = {0};
    double width = 60.0; // fallback
    if (r_responds_main(layer, "bounds") &&
        r_msg2_main_struct_ret(layer, "bounds",
            &bounds, sizeof(bounds),
            NULL, 0, NULL, 0, NULL, 0, NULL, 0) &&
        bounds.w > 1.0) {
        width = bounds.w;
    }

    double radius = width * (double)multiplier;

    // Apply cornerRadius.
    if (!r_responds_main(layer, "setCornerRadius:")) return false;
    r_msg2_main_raw(layer, "setCornerRadius:",
        &radius, sizeof(radius),
        NULL, 0, NULL, 0, NULL, 0);

    // masksToBounds must be YES or cornerRadius has no visible effect.
    if (r_responds_main(layer, "setMasksToBounds:")) {
        r_msg2_main(layer, "setMasksToBounds:", 1, 0, 0, 0);
    }

    return true;
}

static bool rounded_apply_to_iconview_zero(uint64_t iconView)
{
    if (!r_is_objc_ptr(iconView)) return false;

    uint64_t iiv = r_ivar_value(iconView, "_iconImageView");
    if (!r_is_objc_ptr(iiv) && r_responds_main(iconView, "_iconImageView")) {
        iiv = r_msg2_main(iconView, "_iconImageView", 0, 0, 0, 0);
    }
    if (!r_is_objc_ptr(iiv)) return false;

    if (!r_responds_main(iiv, "layer")) return false;
    uint64_t layer = r_msg2_main(iiv, "layer", 0, 0, 0, 0);
    if (!r_is_objc_ptr(layer)) return false;

    double radius = 0.0;
    if (r_responds_main(layer, "setCornerRadius:")) {
        r_msg2_main_raw(layer, "setCornerRadius:",
            &radius, sizeof(radius),
            NULL, 0, NULL, 0, NULL, 0);
    }
    if (r_responds_main(layer, "setMasksToBounds:")) {
        r_msg2_main(layer, "setMasksToBounds:", 0, 0, 0, 0);
    }

    return true;
}

bool rounded_icons_apply_in_session(float radiusMultiplier)
{
    if (radiusMultiplier <= 0.0f) radiusMultiplier = kRoundedDefaultMultiplier;
    // Clamp: 0.225 = iOS default, 0.5 = full circle (Watch style)
    if (radiusMultiplier > 0.5f) radiusMultiplier = 0.5f;

    uint64_t listViewCls = r_class("SBIconListView");
    uint64_t iconViewCls = r_class("SBIconView");
    if (!r_is_objc_ptr(listViewCls) || !r_is_objc_ptr(iconViewCls)) {
        printf("[ROUNDED] missing class SBIconListView=0x%llx SBIconView=0x%llx\n",
               (unsigned long long)listViewCls,
               (unsigned long long)iconViewCls);
        return false;
    }

    enum { LV_CAP = 64 };
    uint64_t lvs[LV_CAP];
    int nlv = sb_collect_views_in_windows(listViewCls, lvs, LV_CAP);
    if (nlv == 0) {
        printf("[ROUNDED] no SBIconListView visible\n");
        return false;
    }

    int applied = 0;
    int failed  = 0;

    for (int i = 0; i < nlv; i++) {
        enum { IV_CAP = 64 };
        uint64_t ivs[IV_CAP];
        int n = sb_collect_views(lvs[i], iconViewCls, ivs, IV_CAP);
        for (int j = 0; j < n; j++) {
            if (rounded_apply_to_iconview(ivs[j], radiusMultiplier))
                applied++;
            else
                failed++;
        }
    }

    printf("[ROUNDED] apply done lists=%d applied=%d failed=%d multiplier=%.3f\n",
           nlv, applied, failed, (double)radiusMultiplier);
    return applied > 0;
}

bool rounded_icons_stop_in_session(void)
{
    uint64_t listViewCls = r_class("SBIconListView");
    uint64_t iconViewCls = r_class("SBIconView");
    if (!r_is_objc_ptr(listViewCls) || !r_is_objc_ptr(iconViewCls)) return false;

    enum { LV_CAP = 64 };
    uint64_t lvs[LV_CAP];
    int nlv = sb_collect_views_in_windows(listViewCls, lvs, LV_CAP);
    if (nlv == 0) return false;

    int cleared = 0;
    for (int i = 0; i < nlv; i++) {
        enum { IV_CAP = 64 };
        uint64_t ivs[IV_CAP];
        int n = sb_collect_views(lvs[i], iconViewCls, ivs, IV_CAP);
        for (int j = 0; j < n; j++) {
            if (rounded_apply_to_iconview_zero(ivs[j]))
                cleared++;
        }
    }

    printf("[ROUNDED] stop cleared=%d\n", cleared);
    return cleared > 0;
}
