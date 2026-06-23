//
//  QuickLoader.h
//

#ifndef QuickLoader_h
#define QuickLoader_h

#import <stdbool.h>
#import <Foundation/Foundation.h>

bool quickloader_apply_in_session();

bool quickloader_run_js_string(NSString *jsCode);

bool quickloader_stop_in_session(void);

#endif /* QuickLoader_h */
