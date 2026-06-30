//
//  roundedicons.h
//  Fr0st — smooth corner radius on every home screen icon.
//  No image replacement. Just shape.
//

#pragma once
#import <Foundation/Foundation.h>

/// Apply rounded corners to all visible SBIconViews.
/// Call once after RemoteCall session is established.
bool rounded_icons_apply_in_session(float radiusMultiplier);

/// Remove rounded corners (restore default).
bool rounded_icons_stop_in_session(void);
