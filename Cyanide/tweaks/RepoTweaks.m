//
//  RepoTweaks.m
//

#import <JavaScriptCore/JavaScriptCore.h>
#import "RepoTweaks.h"
#import "QuickLoader.h"
#import "remote_objc.h"
#import "../TaskRop/RemoteCall.h"
#import "../LogTextView.h"

extern uint64_t r_nsstr_retained(const char *str);

static const NSUInteger kRepoTweaksMaxRepoBytes = 512 * 1024;
static const NSUInteger kRepoTweaksMaxScriptBytes = 512 * 1024;

static NSMutableDictionary<NSString *, JSContext *> *g_repo_contexts = nil;
static NSMutableDictionary<NSString *, NSMutableDictionary<NSNumber *, id> *> *g_repo_timers_registry = nil;
static int g_repo_timer_id_counter = 0;
static volatile int g_repo_shutting_down = 0;
static char g_repo_queue_key;

static dispatch_queue_t repotweaks_js_queue(void) {
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("com.zeroxjf.cyanide.repotweaks.js", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(q, &g_repo_queue_key, &g_repo_queue_key, NULL);
    });
    return q;
}

static void repotweaks_perform_sync(dispatch_block_t block) {
    if (!block) return;
    if (dispatch_get_specific(&g_repo_queue_key)) {
        block();
    } else {
        dispatch_sync(repotweaks_js_queue(), block);
    }
}

static uint64_t repo_js_to_uint64(JSValue *val) {
    if ([val isString]) return strtoull([[val toString] UTF8String], NULL, 16);
    return (uint64_t)[val toDouble];
}

static NSString *repo_uint64_to_js(uint64_t val) {
    return [NSString stringWithFormat:@"0x%llx", val];
}

static BOOL repotweaks_is_https_url(NSString *urlString) {
    if (![urlString isKindOfClass:NSString.class] || urlString.length == 0) return NO;
    NSURLComponents *components = [NSURLComponents componentsWithString:urlString];
    return [components.scheme.lowercaseString isEqualToString:@"https"] && components.host.length > 0;
}

static BOOL repotweaks_valid_identifier(NSString *name) {
    if (![name isKindOfClass:NSString.class] || name.length == 0) return NO;
    unichar first = [name characterAtIndex:0];
    if (![[NSCharacterSet letterCharacterSet] characterIsMember:first] && first != '_' && first != '$') return NO;
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_$"];
    return [name rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound;
}

static NSString *repotweaks_js_string_literal(NSString *value) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:@[value ?: @""]
                                                   options:0
                                                     error:nil];
    NSString *arrayLiteral = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
    if (arrayLiteral.length >= 2 && [arrayLiteral hasPrefix:@"["] && [arrayLiteral hasSuffix:@"]"]) {
        return [arrayLiteral substringWithRange:NSMakeRange(1, arrayLiteral.length - 2)];
    }
    return @"\"\"";
}

static NSString *repotweaks_js_number_literal(NSString *value) {
    double number = [value respondsToSelector:@selector(doubleValue)] ? [value doubleValue] : 0.0;
    if (!isfinite(number)) number = 0.0;
    return [NSString stringWithFormat:@"%.12g", number];
}

static NSString *repotweaks_string_or_empty(id value) {
    return [value isKindOfClass:NSString.class] ? (NSString *)value : @"";
}

static NSDictionary *repotweaks_sanitized_tweak(id raw, NSString **errorMessage) {
    if (![raw isKindOfClass:NSDictionary.class]) {
        if (errorMessage) *errorMessage = @"Repo tweak entry is not an object.";
        return nil;
    }
    NSDictionary *dict = (NSDictionary *)raw;
    NSString *tweakID = repotweaks_string_or_empty(dict[@"id"]);
    NSString *name = repotweaks_string_or_empty(dict[@"name"]);
    NSString *scriptURL = repotweaks_string_or_empty(dict[@"scriptURL"]);
    if (tweakID.length == 0 || name.length == 0 || scriptURL.length == 0) {
        if (errorMessage) *errorMessage = @"Repo tweak is missing id, name, or scriptURL.";
        return nil;
    }
    if (!repotweaks_is_https_url(scriptURL)) {
        if (errorMessage) *errorMessage = @"Repo tweak scriptURL must be HTTPS.";
        return nil;
    }

    NSMutableDictionary *out = [@{
        @"id": tweakID,
        @"name": name,
        @"scriptURL": scriptURL,
        @"description": repotweaks_string_or_empty(dict[@"description"]),
        @"version": repotweaks_string_or_empty(dict[@"version"]),
    } mutableCopy];
    return out;
}

static NSDictionary *repotweaks_sanitized_repo(id raw, NSString **errorMessage) {
    if (![raw isKindOfClass:NSDictionary.class]) {
        if (errorMessage) *errorMessage = @"Repository JSON root must be an object.";
        return nil;
    }
    NSDictionary *dict = (NSDictionary *)raw;
    id rawTweaks = dict[@"tweaks"];
    if (![rawTweaks isKindOfClass:NSArray.class]) {
        if (errorMessage) *errorMessage = @"Repository JSON must include a tweaks array.";
        return nil;
    }

    NSMutableArray *tweaks = [NSMutableArray array];
    for (id rawTweak in (NSArray *)rawTweaks) {
        NSString *entryError = nil;
        NSDictionary *tweak = repotweaks_sanitized_tweak(rawTweak, &entryError);
        if (tweak) {
            [tweaks addObject:tweak];
        } else if (entryError.length > 0) {
            log_user("[RepoTweaks] Skipping invalid entry: %s\n", entryError.UTF8String);
        }
    }
    if (tweaks.count == 0) {
        if (errorMessage) *errorMessage = @"Repository has no valid HTTPS-backed tweaks.";
        return nil;
    }

    return @{
        @"repoName": repotweaks_string_or_empty(dict[@"repoName"]).length ? repotweaks_string_or_empty(dict[@"repoName"]) : @"Repository",
        @"author": repotweaks_string_or_empty(dict[@"author"]),
        @"tweaks": tweaks,
    };
}

static NSArray<NSString *> *repotweaks_saved_urls(NSUserDefaults *d) {
    id raw = [d objectForKey:@"RepoTweaksURLs"];
    if (![raw isKindOfClass:NSArray.class]) return @[];
    NSMutableArray<NSString *> *urls = [NSMutableArray array];
    for (id value in (NSArray *)raw) {
        if ([value isKindOfClass:NSString.class]) [urls addObject:value];
    }
    return urls;
}

static NSDictionary *repotweaks_saved_caches(NSUserDefaults *d) {
    id raw = [d objectForKey:@"RepoTweaksCaches"];
    return [raw isKindOfClass:NSDictionary.class] ? raw : @{};
}

static void repotweaks_cancel_tweak_locked(NSString *tweakID) {
    NSMutableDictionary *timers = g_repo_timers_registry[tweakID];
    for (id timerSource in timers.allValues) {
        dispatch_source_cancel((dispatch_source_t)timerSource);
    }
    [timers removeAllObjects];
    [g_repo_timers_registry removeObjectForKey:tweakID];
    [g_repo_contexts removeObjectForKey:tweakID];
}

bool repotweaks_run_isolated_js(NSString *tweakID, NSString *tweakName, NSString *jsCode) {
    if (![tweakID isKindOfClass:NSString.class] || tweakID.length == 0 ||
        ![jsCode isKindOfClass:NSString.class] || jsCode.length == 0) {
        return false;
    }

    __block bool ok = true;
    NSString *safeID = [tweakID copy];
    NSString *safeName = ([tweakName isKindOfClass:NSString.class] && tweakName.length > 0) ? [tweakName copy] : safeID;

    repotweaks_perform_sync(^{
        if (!g_repo_contexts) g_repo_contexts = [NSMutableDictionary dictionary];
        if (!g_repo_timers_registry) g_repo_timers_registry = [NSMutableDictionary dictionary];

        repotweaks_cancel_tweak_locked(safeID);
        NSMutableDictionary<NSNumber *, id> *tweakTimers = [NSMutableDictionary dictionary];
        g_repo_timers_registry[safeID] = tweakTimers;

        JSContext *context = [[JSContext alloc] init];
        g_repo_contexts[safeID] = context;

        context.exceptionHandler = ^(JSContext *ctx, JSValue *exception) {
            log_user("[RepoTweaks ERROR][%s] %s\n", safeName.UTF8String, [[exception toString] UTF8String]);
        };

        context[@"setInterval"] = ^JSValue*(JSValue *func, JSValue *delay) {
            int tId = ++g_repo_timer_id_counter;
            uint64_t ms = [delay toUInt32];
            if (ms < 16) ms = 16;

            dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, repotweaks_js_queue());
            dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, ms * NSEC_PER_MSEC),
                                      ms * NSEC_PER_MSEC, (ms / 10) * NSEC_PER_MSEC);
            dispatch_source_set_event_handler(timer, ^{
                if (!g_repo_shutting_down) [func callWithArguments:@[]];
            });

            tweakTimers[@(tId)] = timer;
            dispatch_resume(timer);
            return [JSValue valueWithInt32:tId inContext:[JSContext currentContext]];
        };

        context[@"clearInterval"] = ^(JSValue *timerId) {
            int tId = [timerId toInt32];
            dispatch_source_t timer = (dispatch_source_t)tweakTimers[@(tId)];
            if (timer) {
                dispatch_source_cancel(timer);
                [tweakTimers removeObjectForKey:@(tId)];
            }
        };

        context[@"setTimeout"] = ^JSValue*(JSValue *func, JSValue *delay) {
            int tId = ++g_repo_timer_id_counter;
            uint64_t ms = [delay toUInt32];

            dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, repotweaks_js_queue());
            dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, ms * NSEC_PER_MSEC),
                                      DISPATCH_TIME_FOREVER, 0);
            dispatch_source_set_event_handler(timer, ^{
                if (!g_repo_shutting_down) [func callWithArguments:@[]];
                dispatch_source_cancel(timer);
                [tweakTimers removeObjectForKey:@(tId)];
            });

            tweakTimers[@(tId)] = timer;
            dispatch_resume(timer);
            return [JSValue valueWithInt32:tId inContext:[JSContext currentContext]];
        };

        context[@"clearTimeout"] = ^(JSValue *timerId) {
            int tId = [timerId toInt32];
            dispatch_source_t timer = (dispatch_source_t)tweakTimers[@(tId)];
            if (timer) {
                dispatch_source_cancel(timer);
                [tweakTimers removeObjectForKey:@(tId)];
            }
        };

        context[@"log"] = ^(NSString *msg) {
            if (g_repo_shutting_down) return;
            log_user("[RepoTweaks][%s] %s\n", safeName.UTF8String, [msg UTF8String]);
        };

        context[@"r_sel"] = ^NSString*(NSString *selName) {
            if (g_repo_shutting_down) return repo_uint64_to_js(0);
            uint64_t selPtr = (uint64_t)sel_registerName([selName UTF8String]);
            return repo_uint64_to_js(selPtr);
        };

        context[@"r_class"] = ^NSString*(NSString *className) {
            if (g_repo_shutting_down) return repo_uint64_to_js(0);
            uint64_t res = r_class([className UTF8String]);
            return repo_uint64_to_js(res);
        };

        context[@"r_msg2"] = ^() {
            if (g_repo_shutting_down) return repo_uint64_to_js(0);
            NSArray *args = [JSContext currentArguments];
            if (args.count < 2) return repo_uint64_to_js(0);

            uint64_t target = repo_js_to_uint64(args[0]);
            NSString *selector = [args[1] toString];
            uint64_t a1 = args.count > 2 ? repo_js_to_uint64(args[2]) : 0;
            uint64_t a2 = args.count > 3 ? repo_js_to_uint64(args[3]) : 0;
            uint64_t a3 = args.count > 4 ? repo_js_to_uint64(args[4]) : 0;
            uint64_t a4 = args.count > 5 ? repo_js_to_uint64(args[5]) : 0;

            uint64_t res = r_msg2(target, [selector UTF8String], a1, a2, a3, a4);
            return repo_uint64_to_js(res);
        };

        context[@"r_msg2_main"] = ^() {
            if (g_repo_shutting_down) return repo_uint64_to_js(0);
            NSArray *args = [JSContext currentArguments];
            if (args.count < 2) return repo_uint64_to_js(0);

            uint64_t target = repo_js_to_uint64(args[0]);
            NSString *selector = [args[1] toString];
            uint64_t a1 = args.count > 2 ? repo_js_to_uint64(args[2]) : 0;
            uint64_t a2 = args.count > 3 ? repo_js_to_uint64(args[3]) : 0;
            uint64_t a3 = args.count > 4 ? repo_js_to_uint64(args[4]) : 0;
            uint64_t a4 = args.count > 5 ? repo_js_to_uint64(args[5]) : 0;

            uint64_t res = r_msg2_main(target, [selector UTF8String], a1, a2, a3, a4);
            return repo_uint64_to_js(res);
        };

        context[@"r_nsstr"] = ^NSString*(NSString *str) {
            if (g_repo_shutting_down || !str) return repo_uint64_to_js(0);
            uint64_t ptr = r_nsstr_retained([str UTF8String]);
            return repo_uint64_to_js(ptr);
        };

        log_user("[RepoTweaks] Spawning sandbox for: %s\n", safeName.UTF8String);
        [context evaluateScript:jsCode];
        if (context.exception) ok = false;
    });

    return ok;
}

bool repotweaks_apply_in_session(void) {
    __sync_lock_test_and_set(&g_repo_shutting_down, 0);

    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSDictionary *allRepos = repotweaks_saved_caches(d);
    if (allRepos.count == 0) return false;

    bool executedAny = false;
    for (NSString *url in allRepos) {
        if (![url isKindOfClass:NSString.class]) continue;
        NSDictionary *repoData = [allRepos[url] isKindOfClass:NSDictionary.class] ? allRepos[url] : nil;
        NSArray *tweaks = [repoData[@"tweaks"] isKindOfClass:NSArray.class] ? repoData[@"tweaks"] : @[];

        for (NSDictionary *tweak in tweaks) {
            if (![tweak isKindOfClass:NSDictionary.class]) continue;
            NSString *tweakID = repotweaks_string_or_empty(tweak[@"id"]);
            NSString *tweakName = repotweaks_string_or_empty(tweak[@"name"]);
            if (tweakID.length == 0) continue;

            NSString *toggleKey = [NSString stringWithFormat:@"RepoTweakEnabled_%@", tweakID];
            if (![d boolForKey:toggleKey]) {
                repotweaks_perform_sync(^{ repotweaks_cancel_tweak_locked(tweakID); });
                continue;
            }

            NSString *scriptKey = [NSString stringWithFormat:@"RepoTweakScript_%@", tweakID];
            NSString *rawJsCode = [d stringForKey:scriptKey];
            if (rawJsCode.length == 0) continue;

            NSMutableString *finalScript = [NSMutableString stringWithString:@"// --- REPOTWEAKS PARAMS ---\n"];
            NSString *valuesKey = [NSString stringWithFormat:@"RepoTweakValues_%@", tweakID];
            NSMutableDictionary *savedValues = [[d dictionaryForKey:valuesKey] mutableCopy] ?: [NSMutableDictionary dictionary];
            BOOL didUpdateDefaults = NO;

            for (NSString *line in [rawJsCode componentsSeparatedByString:@"\n"]) {
                if (![line containsString:@"@param:"]) continue;
                NSArray *parts = [line componentsSeparatedByString:@"|"];
                if (parts.count < 4) continue;
                NSArray *typeParts = [parts[0] componentsSeparatedByString:@"@param:"];
                if (typeParts.count < 2) continue;

                NSString *type = [typeParts[1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
                NSString *varName = [parts[1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
                NSString *defValue = [parts[3] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
                if (!repotweaks_valid_identifier(varName)) {
                    log_user("[RepoTweaks] Skipping invalid parameter name: %s\n", varName.UTF8String);
                    continue;
                }

                NSString *currentValue = savedValues[varName];
                if (![currentValue isKindOfClass:NSString.class]) {
                    currentValue = defValue ?: @"";
                    savedValues[varName] = currentValue;
                    didUpdateDefaults = YES;
                }

                if ([type isEqualToString:@"switch"]) {
                    [finalScript appendFormat:@"var %@ = %@;\n", varName, [currentValue boolValue] ? @"true" : @"false"];
                } else if ([type isEqualToString:@"text"] || [type isEqualToString:@"color"]) {
                    [finalScript appendFormat:@"var %@ = %@;\n", varName, repotweaks_js_string_literal(currentValue)];
                } else if ([type isEqualToString:@"slider"] || [type isEqualToString:@"number"]) {
                    [finalScript appendFormat:@"var %@ = %@;\n", varName, repotweaks_js_number_literal(currentValue)];
                }
            }

            if (didUpdateDefaults) {
                [d setObject:savedValues forKey:valuesKey];
                [d synchronize];
            }

            [finalScript appendString:@"// -------------------------\n\n"];
            [finalScript appendString:rawJsCode];
            bool ok = repotweaks_run_isolated_js(tweakID, tweakName, finalScript);
            executedAny = executedAny || ok;
        }
    }
    return executedAny;
}

void repotweaks_refresh_repo(NSString *repoURL, void (^completion)(BOOL success, NSString *message)) {
    void (^finish)(BOOL, NSString *) = ^(BOOL success, NSString *message) {
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(success, message ?: @""); });
    };
    if (!repotweaks_is_https_url(repoURL)) {
        finish(NO, @"Repository URL must be HTTPS.");
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:repoURL]];
    request.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    request.timeoutInterval = 20;

    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error || !data) {
            finish(NO, error.localizedDescription ?: @"Download failed.");
            return;
        }
        if ([response isKindOfClass:NSHTTPURLResponse.class]) {
            NSInteger status = ((NSHTTPURLResponse *)response).statusCode;
            if (status < 200 || status >= 300) {
                finish(NO, [NSString stringWithFormat:@"Repository returned HTTP %ld.", (long)status]);
                return;
            }
        }
        if (data.length == 0 || data.length > kRepoTweaksMaxRepoBytes) {
            finish(NO, @"Repository JSON is empty or too large.");
            return;
        }

        NSError *jsonErr = nil;
        id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonErr];
        NSString *validationError = nil;
        NSDictionary *sanitized = repotweaks_sanitized_repo(json, &validationError);
        if (!sanitized) {
            finish(NO, validationError ?: jsonErr.localizedDescription ?: @"Invalid JSON.");
            return;
        }

        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        NSMutableDictionary *caches = [repotweaks_saved_caches(d) mutableCopy];
        caches[repoURL] = sanitized;
        [d setObject:caches forKey:@"RepoTweaksCaches"];

        NSMutableArray *urls = [[repotweaks_saved_urls(d) mutableCopy] ?: [NSMutableArray array] mutableCopy];
        if (![urls containsObject:repoURL]) [urls addObject:repoURL];
        [d setObject:urls forKey:@"RepoTweaksURLs"];
        [d synchronize];

        NSArray *tweaks = sanitized[@"tweaks"];
        dispatch_group_t group = dispatch_group_create();
        __block BOOL scriptsOK = YES;
        for (NSDictionary *tweak in tweaks) {
            dispatch_group_enter(group);
            repotweaks_download_script(tweak[@"id"], tweak[@"scriptURL"], ^(BOOL success) {
                if (!success) scriptsOK = NO;
                dispatch_group_leave(group);
            });
        }
        dispatch_group_notify(group, dispatch_get_main_queue(), ^{
            finish(scriptsOK, scriptsOK ? @"Refreshed." : @"Refreshed, but one or more scripts failed to download.");
        });
    }] resume];
}

void repotweaks_download_script(NSString *tweakId, NSString *scriptURL, void (^completion)(BOOL success)) {
    void (^finish)(BOOL) = ^(BOOL success) {
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(success); });
    };
    if (![tweakId isKindOfClass:NSString.class] || tweakId.length == 0 ||
        !repotweaks_is_https_url(scriptURL)) {
        finish(NO);
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:scriptURL]];
    request.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    request.timeoutInterval = 20;

    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error || !data) {
            finish(NO);
            return;
        }
        if ([response isKindOfClass:NSHTTPURLResponse.class]) {
            NSInteger status = ((NSHTTPURLResponse *)response).statusCode;
            if (status < 200 || status >= 300) {
                finish(NO);
                return;
            }
        }
        if (data.length == 0 || data.length > kRepoTweaksMaxScriptBytes) {
            finish(NO);
            return;
        }
        NSString *jsCode = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (jsCode.length == 0) {
            finish(NO);
            return;
        }

        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        [d setObject:jsCode forKey:[NSString stringWithFormat:@"RepoTweakScript_%@", tweakId]];
        [d synchronize];
        finish(YES);
    }] resume];
}

bool repotweaks_stop_in_session(void) {
    __sync_lock_test_and_set(&g_repo_shutting_down, 1);

    repotweaks_perform_sync(^{
        log_user("[RepoTweaks] Safe stop: stopping timers.\n");
        if (g_repo_timers_registry) {
            for (NSString *tweakID in [g_repo_timers_registry allKeys]) {
                repotweaks_cancel_tweak_locked(tweakID);
            }
            [g_repo_timers_registry removeAllObjects];
        }
        [g_repo_contexts removeAllObjects];
    });

    return true;
}
