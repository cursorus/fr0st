//
//  RepoTweaks.h
//

#ifndef RepoTweaks_h
#define RepoTweaks_h

#import <stdbool.h>
#import <Foundation/Foundation.h>

// Runs all enabled tweaks during the RUN 4/4 sequence
bool repotweaks_apply_in_session(void);

// Fetches the JSON from the given URL and caches it
void repotweaks_refresh_repo(NSString *repoURL, void (^completion)(BOOL success, NSString *message));

// Downloads the raw .js code for a specific tweak ID
void repotweaks_download_script(NSString *tweakId, NSString *scriptURL, void (^completion)(BOOL success));

bool repotweaks_stop_in_session(void);

#endif /* RepoTweaks_h */
