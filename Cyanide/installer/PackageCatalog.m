//
//  PackageCatalog.m
//  Cyanide
//

#import "PackageCatalog.h"
#import "../SettingsViewController.h"
#import "../tweaks/RepoTweaks.h"
#import "../tweaks/experimental_tweaks.h"

@interface Package ()
@property (nonatomic, readwrite, copy) NSString *symbolName;
@property (nonatomic, readwrite, copy) NSString *author;
@end

@implementation PackageCatalog

static NSString *catalog_string_or_empty(id value)
{
    return [value isKindOfClass:NSString.class] ? (NSString *)value : @"";
}

static NSArray<NSString *> *catalog_repotweaks_urls(NSUserDefaults *d)
{
    id raw = [d objectForKey:@"RepoTweaksURLs"];
    if (![raw isKindOfClass:NSArray.class]) return @[];
    NSMutableArray<NSString *> *urls = [NSMutableArray array];
    for (id value in (NSArray *)raw) {
        if ([value isKindOfClass:NSString.class]) [urls addObject:value];
    }
    return urls;
}

static NSDictionary *catalog_repotweaks_caches(NSUserDefaults *d)
{
    id raw = [d objectForKey:@"RepoTweaksCaches"];
    return [raw isKindOfClass:NSDictionary.class] ? (NSDictionary *)raw : @{};
}

static BOOL catalog_repo_script_requires_native_bridge(NSString *rawScript)
{
    if (![rawScript isKindOfClass:NSString.class] || rawScript.length == 0) return NO;
    return [rawScript containsString:@"nativeCallBuff"] ||
           [rawScript containsString:@"runOnMainEvaluate"] ||
           [rawScript containsString:@"Native.callSymbol"];
}

+ (NSArray<Package *> *)repoPackages
{
    repotweaks_seed_default_repos();

    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSDictionary *caches = catalog_repotweaks_caches(d);
    NSMutableArray<Package *> *packages = [NSMutableArray array];

    for (NSString *url in catalog_repotweaks_urls(d)) {
        id repoRaw = caches[url];
        if (![repoRaw isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *repo = (NSDictionary *)repoRaw;
        NSString *repoName = catalog_string_or_empty(repo[@"repoName"]);
        NSString *author = catalog_string_or_empty(repo[@"author"]);
        id tweaksRaw = repo[@"tweaks"];
        if (![tweaksRaw isKindOfClass:NSArray.class]) continue;

        for (id tweakRaw in (NSArray *)tweaksRaw) {
            if (![tweakRaw isKindOfClass:NSDictionary.class]) continue;
            NSDictionary *tweak = (NSDictionary *)tweakRaw;
            NSString *tweakID = catalog_string_or_empty(tweak[@"id"]);
            NSString *name = catalog_string_or_empty(tweak[@"name"]);
            NSString *scriptURL = catalog_string_or_empty(tweak[@"scriptURL"]);
            if (tweakID.length == 0 || name.length == 0 || scriptURL.length == 0) continue;

            NSString *identifier = [NSString stringWithFormat:@"repo.%@", repotweaks_storage_key(url, tweakID)];
            Package *pkg = [[Package alloc] initRepoTweakWithIdentifier:identifier
                                                                   name:name
                                                       shortDescription:catalog_string_or_empty(tweak[@"description"])
                                                                version:catalog_string_or_empty(tweak[@"version"])
                                                                 author:author
                                                               repoName:repoName
                                                                repoURL:url
                                                            repoTweakID:tweakID
                                                           repoScriptURL:scriptURL];
            NSString *symbol = catalog_string_or_empty(tweak[@"symbol"]);
            if (symbol.length > 0) pkg.symbolName = symbol;
            NSString *tweakAuthor = catalog_string_or_empty(tweak[@"author"]);
            if (tweakAuthor.length > 0) pkg.author = tweakAuthor;
            NSString *rawScript = [d stringForKey:repotweaks_script_defaults_key(url, tweakID)];
            NSString *unsupportedReason = repotweaks_unsupported_reason(tweak);
            if (unsupportedReason.length > 0) {
                pkg.installDisabledReason = unsupportedReason;
                pkg.unstableWarning = unsupportedReason;
            } else if (rawScript.length == 0) {
                pkg.installDisabledReason = @"Refresh this source from the Sources tab before installing.";
            } else if (pkg.repoTweakUsesQuickLoader && catalog_repo_script_requires_native_bridge(rawScript)) {
                pkg.installDisabledReason = @"This repo tweak needs a dedicated Cyanide native backend before it can install.";
            }
            [packages addObject:pkg];
        }
    }

    return [packages sortedArrayUsingComparator:^NSComparisonResult(Package *a, Package *b) {
        return [a.name caseInsensitiveCompare:b.name];
    }];
}

// Mirrors of the private SettingsSection enum values in SettingsViewController.m
// (kept in sync — must match the underlying section indices used for the
// detail-mode SettingsViewController push).
static const NSInteger kSecSBC              = 4;
static const NSInteger kSecStatBar          = 5;
static const NSInteger kSecNSBar            = 6;
static const NSInteger kSecNiceBarLite      = 7;
static const NSInteger kSecRSSI             = 8;
static const NSInteger kSecTypeBanner       = 10;
static const NSInteger kSecNotificationIsland = 11;
static const NSInteger kSecPowercuff        = 12;
static const NSInteger kSecDragCoefficient  = 14;
static const NSInteger kSecLayoutExtras     = 15;
static const NSInteger kSecNanoRegistry     = 16;
static const NSInteger kSecSnowBoardLite    = 18;
static const NSInteger kSecLiveWP           = 19;
static const NSInteger kSecLocationSim      = 20;
static const NSInteger kSecGravityLite      = 21;
static const NSInteger kSecRoundedIcons     = 27;
static const NSInteger kSecAppSwitcherGrid  = 22;
static const NSInteger kSecIPADecryptor     = 23;
static const NSInteger kSecFastLockXLite    = 24;
static const NSInteger kSecQuickLoader      = 25;
static const NSInteger kSecRepoTweaks       = 26;

+ (NSArray<Package *> *)allPackages
{
    NSArray<Package *> *full = [self allPackagesIncludingExperimental];
    BOOL experimentalOn = [[NSUserDefaults standardUserDefaults]
                            boolForKey:kSettingsExperimentalTweaksEnabled];

    NSMutableArray<Package *> *out = [NSMutableArray arrayWithCapacity:full.count];
    for (Package *p in full) {
        if (p.creatorOnly) continue;
        if (p.experimental && !experimentalOn) continue;
        [out addObject:p];
    }
    return out;
}

+ (NSArray<Package *> *)allPackagesIncludingExperimental
{
    static NSArray<Package *> *list;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *version = @"1.0";
        NSString *inDevelopmentDisabledReason =
            @"In development — install is disabled because this tweak does not work yet. The code is left in the app/source tree for anyone who wants to pick it up.";

        Package *statBar = [[Package alloc] initWithIdentifier:@"com.darksword.statbar"
                                           name:@"StatBar"
                               shortDescription:@"Battery temperature + free RAM overlay"
                                longDescription:@"Installs an overlay window in SpringBoard that shows live battery temperature and free RAM next to the system status bar. Refresh timing is adjus[...]
                                        version:version
                                         author:@"zeroxjf"
                                       category:@"Status Bar"
                                     symbolName:@"thermometer.medium"
                                           kind:PackageInstallKindToggle
                                     enabledKey:kSettingsStatBarEnabled
                                          isNew:NO];
        statBar.settingsSection = kSecStatBar;

        Package *nsBar = [[Package alloc] initWithIdentifier:@"com.darksword.nsbar"
                                           name:@"NSBar"
                               shortDescription:@"Network speed overlay in the status bar"
                                longDescription:@"Displays real-time download and upload speed in a compact SpringBoard status-bar overlay. Pick its corner or center position in Settings.\n\nPort[...]
                                        version:version
                                         author:@"d1y"
                                       category:@"Status Bar"
                                     symbolName:@"network"
                                           kind:PackageInstallKindToggle
                                     enabledKey:kSettingsNSBarEnabled
                                          isNew:NO];
        nsBar.settingsSection = kSecNSBar;

        Package *niceBarLite = [[Package alloc] initWithIdentifier:@"com.darksword.nicebarlite"
                                           name:@"NiceBar Lite"
                               shortDescription:@"NiceBar-style status labels"
                                longDescription:@"Adds configurable text labels around the status bar. Slots can show custom text, date/time formats, and system values such as battery, memory, ne[...]
                                        version:version
                                         author:@"d1y"
                                       category:@"Status Bar"
                                     symbolName:@"textformat.size"
                                           kind:PackageInstallKindToggle
                                     enabledKey:kSettingsNiceBarLiteEnabled
                                          isNew:NO];
        niceBarLite.settingsSection = kSecNiceBarLite;

#if CYANIDE_EXPERIMENTAL_TWEAKS_AVAILABLE
        Package *signal = [[Package alloc] initWithIdentifier:@"com.darksword.rssidisplay"
                                           name:@"Signal Readouts"
                               shortDescription:@"RSRP dBm on cellular, bar count on WiFi"
                                longDescription:@"Replaces the signal-strength glyphs in the status bar with live numeric readouts: RSRP in dBm for cellular, and the active bar count for WiFi. Up[...]
                                        version:version
                                         author:@"zeroxjf"
                                       category:@"In Development"
                                     symbolName:@"antenna.radiowaves.left.and.right"
                                           kind:PackageInstallKindToggle
                                     enabledKey:kSettingsRSSIDisplayEnabled
                                          isNew:NO];
        signal.settingsSection = kSecRSSI;
        signal.installDisabledReason = inDevelopmentDisabledReason;
        signal.unstableWarning = @"⚠️ In development only — install is disabled because this does not work yet. The live status-bar refresh interferes with other SpringBoard tweaks and can [...]
#endif

        Package *sbc = [[Package alloc] initWithIdentifier:@"com.darksword.sbcustomizer"
                                           name:@"SBCustomizer"
                               shortDescription:@"Custom dock count and home screen grid"
                                longDescription:@"Customizes the dock icon count and the home screen icon grid (columns and rows). Optionally hides icon labels.\n\nAdjust the per-axis counts and [...]
                                        version:version
                                         author:@"zeroxjf"
                                       category:@"Home Screen"
                                     symbolName:@"square.grid.3x3.fill"
                                           kind:PackageInstallKindToggle
                                     enabledKey:kSettingsSBCEnabled
                                          isNew:NO];
        sbc.settingsSection = kSecSBC;

        Package *powercuff = [[Package alloc] initWithIdentifier:@"com.darksword.powercuff"
                                           name:@"Powercuff"
                               shortDescription:@"Underclock the CPU/GPU thermal pressure"
                                longDescription:@"Drives thermalmonitord with synthetic thermal pressure to underclock the CPU and GPU. Useful for cooling-sensitive workloads or extending runtime[...]
                                        version:version
                                         author:@"rpetrich"
                                       category:@"System"
                                     symbolName:@"bolt.slash.fill"
                                           kind:PackageInstallKindToggle
                                     enabledKey:kSettingsPowercuffEnabled
                                          isNew:NO];
        powercuff.settingsSection = kSecPowercuff;

        Package *axon = [[Package alloc] initWithIdentifier:@"com.darksword.axonlite"
                                           name:@"Axon Lite"
                               shortDescription:@"Group Notification Center requests by app"
                                longDescription:@"Groups visible Notification Center requests by app in a SpringBoard overlay and filters duplicates while Cyanide keeps the RemoteCall session ali[...]
                                        version:version
                                         author:@"zeroxjf"
                                       category:@"SpringBoard"
                                     symbolName:@"bell.badge.fill"
                                           kind:PackageInstallKindToggle
                                     enabledKey:kSettingsAxonLiteEnabled
                                          isNew:NO];
        axon.unstableWarning = @"⚠️ Experimental: work-in-progress. Expect SpringBoard crashes, dropped notifications, layout glitches, and breakage between Cyanide builds. Don't rely on it f[...]

#if CYANIDE_EXPERIMENTAL_TWEAKS_AVAILABLE
        Package *typeBanner = [[Package alloc] initWithIdentifier:@"com.darksword.typebanner"
                                           name:@"TypeBanner"
                               shortDescription:@"iMessage typing banner under the Dynamic Island"
                                longDescription:@"Port of TypeMillennium. Shows a pill banner just below the Dynamic Island when imagent reports an active iMessage typing indicator.\n\nNo extra c[...]
                                        version:version
                                         author:@"zeroxjf"
                                       category:@"In Development"
                                     symbolName:@"ellipsis.bubble.fill"
                                           kind:PackageInstallKindToggle
                                     enabledKey:kSettingsTypeBannerEnabled
                                          isNew:NO];
        typeBanner.settingsSection = kSecTypeBanner;
        typeBanner.installDisabledReason = inDevelopmentDisabledReason;
        typeBanner.unstableWarning = @"⚠️ In development only — install is disabled because this does not work yet. Keeps an original-thread imagent RemoteCall session for live polling and [...]

        Package *notificationIsland = [[Package alloc] initWithIdentifier:@"com.darksword.notificationisland"
                                           name:@"Notification Island"
                               shortDescription:@"Mirror incoming banners into the Dynamic Island"
                                longDescription:@"Experimental Dynamic Island notification route. Watches SpringBoard's active banner request over the shared RemoteCall session, then mirrors the [...]
                                        version:version
                                         author:@"zeroxjf"
                                       category:@"In Development"
                                     symbolName:@"bell.and.waves.left.and.right.fill"
                                           kind:PackageInstallKindToggle
                                     enabledKey:kSettingsNotificationIslandEnabled
                                          isNew:NO];
        notificationIsland.settingsSection = kSecNotificationIsland;
        notificationIsland.installDisabledReason = inDevelopmentDisabledReason;
        notificationIsland.unstableWarning = @"⚠️ In development only — install is disabled because this does not work yet. Polls SpringBoard notification state over RemoteCall and may miss[...]

        Package *ipaDecryptor = [[Package alloc] initWithIdentifier:@"com.darksword.ipadecryptor"
                                           name:@"IPA Decryptor"
                               shortDescription:@"Decrypt installed App Store app payloads"
                                longDescription:@"In-development local IPA decryptor. Select an installed user app or paste an App Store link, resolve it to a bundle ID, sign in for an App Store [...]
                                        version:version
                                         author:@"londek / zeroxjf"
                                       category:@"In Development"
                                     symbolName:@"lock.open.fill"
                                           kind:PackageInstallKindDirectTool
                                     enabledKey:nil
                                          isNew:NO];
        ipaDecryptor.settingsSection = kSecIPADecryptor;
        ipaDecryptor.installDisabledReason = inDevelopmentDisabledReason;
        ipaDecryptor.unstableWarning = @"⚠️ In development only — install is disabled because this does not work yet. Encrypted IPA download is experimental. SINF/iTunesMetadata patching, t[...]

        Package *stageStrip = [[Package alloc] initWithIdentifier:@"com.darksword.stagestrip"
                                           name:@"Dynamic Stage Lite"
                               shortDescription:@"Two floating app windows, iPad-style"
                                longDescription:
            @"Run two apps as floating, resizable windows on top of SpringBoard.\n\n"
            @"Based on Dynamic Stage by tomt000 — the original Stage Manager-for-iPhone tweak. Dynamic Stage Lite is an independent, RemoteCall-only re-implementation of the split-view + scene-[...]
            @"How to use:\n"
            @"• Tap the dot in the bottom-right corner of the screen to open the picker.\n"
            @"• Tap two apps to launch them side-by-side.\n"
            @"• Drag the top bar to move; drag any corner to resize.\n"
            @"• X in the top-left of a window closes it.\n"
            @"• Gear in the picker tray jumps back to Cyanide settings.\n\n"
            @"First Run is slow. The picker has to enumerate every installed app over RemoteCall and build a tile per app — expect 1-2 minutes on a fresh install. Re-Runs reuse the cache and ar[...]
            @"Rough edges:\n"
            @"• Touch routing into hosted apps isn't wired — windows are for viewing/switching, not scrolling or typing.\n"
            @"• Auto-close on full-screen launch is not yet hooked up; close manually with the X.\n"
            @"• Gestures may stutter while the App Library is still filling in."
                                        version:version
                                         author:@"zeroxjf"
                                       category:@"Beta"
                                     symbolName:@"sidebar.left"
                                           kind:PackageInstallKindToggle
                                     enabledKey:kSettingsStageStripEnabled
                                          isNew:NO];
        stageStrip.unstableWarning = @"Beta / unstable: First Run takes 1-2 minutes because the picker enumerates every installed app and builds a tile per app. Re-Runs are fast. Touch routing in[...]
#endif

        Package *locationSim = [[Package alloc] initWithIdentifier:@"com.darksword.locationsim"
                                           name:@"Location Simulator"
                               shortDescription:@"CoreLocation static point simulation"
                                longDescription:@"Spoofs the device's GPS location via Apple's CLSimulationManager. Requires Apple Maps installed and set up — Maps is the RemoteCall host proces[...]
                                        version:version
                                         author:@"zeroxjf, kolbicz, ezzuldinSt"
                                       category:@"System"
                                     symbolName:@"location.fill"
                                           kind:PackageInstallKindDirectTool
                                     enabledKey:nil
                                          isNew:NO];
        locationSim.settingsSection = kSecLocationSim;
        locationSim.experimental = NO;
        locationSim.unstableWarning = @"Beta: requires Apple Maps installed and set up. Changes CoreLocation's active simulation state — may affect time zone, date/time, and other location-tied[...]

        Package *snowboardLite = [[Package alloc] initWithIdentifier:@"com.darksword.snowboardlite"
                                           name:@"SnowBoard Lite"
                               shortDescription:@"Local SnowBoard-style icon themes"
                                longDescription:@"Imports SnowBoard/IconBundles themes into a local library and applies the selected theme through Cyanide's icon replacement pipeline. Supports th[...]
                                        version:version
                                         author:@"d1y"
                                       category:@"Theming"
                                     symbolName:@"square.stack.3d.up.fill"
                                          kind:PackageInstallKindToggle
                                     enabledKey:kSettingsSnowBoardLiteEnabled
                                          isNew:NO];
        snowboardLite.settingsSection = kSecSnowBoardLite;
        snowboardLite.unstableWarning = @"Preview: import or select a SnowBoard Lite theme before applying.";

        Package *liveWP = [[Package alloc] initWithIdentifier:@"com.darksword.livewp"
                                           name:@"LiveWP"
                               shortDescription:@"Video wallpaper for Home and Lock Screen"
                                longDescription:@"Plays a selected MP4/MOV/M4V video behind SpringBoard's home and lock screen windows while Cyanide keeps the RemoteCall session alive.\n\nPorted [...]
                                        version:version
                                         author:@"d1y"
                                       category:@"Theming"
                                     symbolName:@"play.rectangle.fill"
                                           kind:PackageInstallKindToggle
                                     enabledKey:kSettingsLiveWPEnabled
                                          isNew:NO];
        liveWP.settingsSection = kSecLiveWP;

        Package *layoutExtras = [[Package alloc] initWithIdentifier:@"com.darksword.layoutextras"
                                           name:@"Home Layout Extras"
                               shortDescription:@"Extra home/dock padding and per-icon scaling"
                                longDescription:@"Adds extra padding around the home grid and the dock, and scales icons up or down. Stacks on top of SBCustomizer.\n\nDial in left/right/top/botto[...]
                                        version:version
                                         author:@"kolbicz"
                                       category:@"Home Screen"
                                     symbolName:@"square.dashed.inset.filled"
                                           kind:PackageInstallKindToggle
                                     enabledKey:kSettingsLayoutExtrasEnabled
                                          isNew:NO];
        layoutExtras.settingsSection = kSecLayoutExtras;
        NSInteger iosMajor = [[NSProcessInfo processInfo] operatingSystemVersion].majorVersion;
        if (iosMajor >= 26) {
            layoutExtras.knownIssues = @[
                @"iOS 26: layout may reset after rotation or page swipe. Re-run to reapply.",
            ];
        }

        Package *gravityLite = [[Package alloc] initWithIdentifier:@"com.darksword.gravitylite"
                                           name:@"Gravity Lite"
                               shortDescription:@"Make home-screen icons fall with physics"
                                longDescription:@"Core RemoteCall-only port of Julio Verne's classic Gravity tweak for iOS 26. Applies UIDynamicAnimator gravity, collision bounds, bounce, frictio[...]
                                        version:version
                                         author:@"Julio Verne / zeroxjf"
                                       category:@"Home Screen"
                                     symbolName:@"arrow.down.circle.fill"
                                           kind:PackageInstallKindToggle
                                     enabledKey:kSettingsGravityLiteEnabled
                                          isNew:NO];
        gravityLite.settingsSection = kSecGravityLite;
        gravityLite.unstableWarning = @"Beta: RemoteCall-only physics can be reset by SpringBoard relayouts such as page swipes, rotations, folder transitions, or resprings. Use Restore Icon Layo[...]
        gravityLite.knownIssues = @[
            @"To disable, use the App Switcher to return to Cyanide and deactivate Gravity Lite. There is no other way to stop it right now.",
            @"Touch input does not register on displaced icons yet. Forwarding taps in this environment is a major WIP.",
            @"Install is slow as hell. WIP. Cyanide has to capture every visible icon and widget before physics start.",
            @"Page swipes, folder opens, or SpringBoard relayouts may stop the effect. Run Gravity again.",
        ];

        Package *roundedIcons = [[Package alloc] initWithIdentifier:@"com.fr0st.roundedicons"
            name:@"Rounded Icons"
            shortDescription:@"Smooth corners on every home screen icon"
            longDescription:@"Applies corner radius to _iconImageView.layer on every SBIconView. No image replacement."
            version:version
            author:@"cursorus"
            category:@"Home Screen"
            symbolName:@"circle.square.fill"
            kind:PackageInstallKindToggle
            enabledKey:kSettingsRoundedIconsEnabled
            isNew:YES];
        roundedIcons.settingsSection = kSecRoundedIcons;

        Package *appSwitcherGrid = [[Package alloc] initWithIdentifier:@"com.darksword.appswitchergrid"
                                           name:@"App Switcher Grid"
                               shortDescription:@"Grid-style app switcher"
                                longDescription:@"Applies a runtime SpringBoard method patch that makes the app switcher use grid/deck style.\n\nThis does not write system files. A respring resto[...]
                                        version:version
                                         author:@"rooootdev"
                                       category:@"SpringBoard"
                                     symbolName:@"square.grid.2x2.fill"
                                           kind:PackageInstallKindToggle
                                     enabledKey:kSettingsAppSwitcherGridEnabled
                                          isNew:NO];
        appSwitcherGrid.settingsSection = kSecAppSwitcherGrid;
        appSwitcherGrid.unstableWarning = @"Beta: patches SpringBoard runtime methods in memory. Respring restores stock, but unsupported builds may glitch the app switcher or crash SpringBoard. [...]

        Package *quickLoader = [[Package alloc] initWithIdentifier:@"com.darksword.quickloader"
                                           name:@"QuickLoader"
                               shortDescription:@"Executes custom .js code"
                                longDescription:@"Select a local JavaScript file from Files, configure any declared parameters, and run it through Cyanide's SpringBoard RemoteCall bridge.\n\nOnly[...]
                                        version:@"1.0"
                                         author:@"Iggy05"
                                       category:@"SpringBoard"
                                     symbolName:@"bolt.fill"
                                           kind:PackageInstallKindToggle
                                     enabledKey:kSettingsQuickLoaderEnabled
                                          isNew:NO];
        quickLoader.settingsSection = kSecQuickLoader;
        quickLoader.unstableWarning = @"Runs user-selected JavaScript with access to Cyanide's RemoteCall helpers. Only use scripts you trust; bad scripts can crash SpringBoard.";

#if CYANIDE_EXPERIMENTAL_TWEAKS_AVAILABLE
        Package *fastLockXLite = [[Package alloc] initWithIdentifier:@"com.darksword.fastlockx-lite"
                                           name:@"FastLockX Lite"
                               shortDescription:@"Face ID retry + unlock controls"
                                longDescription:@"RemoteCall-only port of the usable FastLockX primitives recovered from the iOS 15 tweak by Artem Kasper.\n\nCredits: original FastLockX by Artem [...]
                                        version:version
                                         author:@"Artem Kasper / zeroxjf"
                                       category:@"Beta"
                                     symbolName:@"lock.open.fill"
                                           kind:PackageInstallKindToggle
                                     enabledKey:kSettingsFastLockXLiteEnabled
                                          isNew:NO];
        fastLockXLite.settingsSection = kSecFastLockXLite;
        fastLockXLite.unstableWarning = @"Beta / unstable: sends private SpringBoard lock-screen and biometric-resource messages. Always On runs SpringBoard timers while the device is locked, so [...]
#endif

        Package *nanoRegistry = [[Package alloc] initWithIdentifier:@"com.darksword.nanoregistry"
                                           name:@"Watch Pairing Override"
                               shortDescription:@"Pair a newer watch or revive an older one"
                                longDescription:@"Changes the watchOS pairing range saved on this iPhone.\n\nMost people should use watchOS Range 99/23/10/6 in Settings, then apply the override. [...]
                                        version:version
                                         author:@"zeroxjf"
                                       category:@"System"
                                     symbolName:@"applewatch.radiowaves.left.and.right"
                                           kind:PackageInstallKindNanoRegistry
                                     enabledKey:nil
                                          isNew:NO];
        nanoRegistry.settingsSection = kSecNanoRegistry;
        nanoRegistry.unstableWarning = @"Warning: modifies a local NanoRegistry MobileAsset. Cyanide saves a .cyanide.bak backup beside the original, but system-file edits can fail or require a r[...]

        Package *callRecordingSound = [[Package alloc] initWithIdentifier:@"com.darksword.callrecording-sound"
                                           name:@"Call Recording Sound"
                               shortDescription:@"Silence disclosure start/stop sounds"
                                longDescription:@"Replaces the CallServices StartDisclosureWithTone and StopDisclosure audio files with Cyanide's bundled silent payloads.\n\nCredits: YangJiiii (@[...]
                                        version:version
                                         author:@"YangJiiii (@duongduong0908) / zeroxjf"
                                       category:@"System"
                                     symbolName:@"speaker.slash.fill"
                                           kind:PackageInstallKindCallRecordingSound
                                     enabledKey:nil
                                          isNew:NO];
        callRecordingSound.experimental = NO;
        callRecordingSound.unstableWarning = @"Beta: persistent CallServices system-file replacement. Disclosure sounds may be legally required where you live; you are responsible for your use an[...]

        Package *hideHomeBar = [[Package alloc] initWithIdentifier:@"com.darksword.hide-home-bar"
                                           name:@"Hide Home Bar"
                               shortDescription:@"Hide the bottom home indicator"
                                longDescription:@"Zeros the first page of /System/Library/PrivateFrameworks/MaterialKit.framework/Assets.car using Cyanide's stable file-page zero path, which hide[...]
                                        version:version
                                         author:@"C4ndyF1sh / jailbreakdotparty / zeroxjf"
                                       category:@"Home Screen"
                                     symbolName:@"line.3.horizontal"
                                           kind:PackageInstallKindHideHomeBar
                                     enabledKey:nil
                                          isNew:NO];
        hideHomeBar.unstableWarning = @"Beta: system asset page zeroing. Run by itself, then respring after hiding. To restore the home indicator, choose Restore Home Bar and respring.";

        Package *otaBlock = [[Package alloc] initWithIdentifier:@"com.darksword.ota-block"
                                           name:@"OTA Updates"
                               shortDescription:@"Enable or disable over-the-air system updates"
                                longDescription:@"Disables or enables the launchd jobs responsible for over-the-air system updates by editing disabled.plist. State persists across reboots.\n\nSys[...]
                                        version:version
                                         author:@"kolbicz"
                                       category:@"System"
                                     symbolName:@"icloud.slash.fill"
                                          kind:PackageInstallKindOTA
                                    enabledKey:nil
                                         isNew:NO];
        otaBlock.unstableWarning = @"Warning: persistent system-file edit. This package modifies launchd disabled.plist to change OTA job state across reboot. Disable or re-enable OTA updates at [...]

        Package *disableAppLibrary = [[Package alloc] initWithIdentifier:@"com.darksword.disable-app-library"
                                           name:@"Disable App Library"
                               shortDescription:@"Remove the App Library page"
                                longDescription:@"Removes the App Library page that sits past your last home-screen page. Swiping past the last page becomes a no-op."
                                        version:version
                                         author:@"kolbicz"
                                       category:@"SpringBoard"
                                     symbolName:@"square.grid.2x2.fill"
                                           kind:PackageInstallKindToggle
                                     enabledKey:kSettingsDSDisableAppLibrary
                                          isNew:NO];

        list = @[
            statBar,
            nsBar,
            niceBarLite,
            sbc,
            layoutExtras,
            gravityLite,
            roundedIcons,
            powercuff,

            disableAppLibrary,

            [[Package alloc] initWithIdentifier:@"com.darksword.disable-icon-flyin"
                                           name:@"Disable Icon Fly-In"
                               shortDescription:@"Skip the icon spring animation"
                                longDescription:@"Skips the spring animation that plays when home screen icons appear after unlock or app switch. Icons just appear in their final position."
                                        version:version
                                         author:@"kolbicz"
                                       category:@"SpringBoard"
                                     symbolName:@"sparkles"
                                           kind:PackageInstallKindToggle
                                     enabledKey:kSettingsDSDisableIconFlyIn
                                          isNew:NO],

            [[Package alloc] initWithIdentifier:@"com.darksword.zero-wake-animation"
                                           name:@"Zero Wake Animation"
                               shortDescription:@"Snap on instantly when waking"
                                longDescription:@"Removes the fade-in animation when waking the display. The screen pops on at full brightness immediately."
                                        version:version
                                         author:@"kolbicz"
                                       category:@"SpringBoard"
                                     symbolName:@"moon.zzz.fill"
                                           kind:PackageInstallKindToggle
                                     enabledKey:kSettingsDSZeroWakeAnimation
                                          isNew:NO],

            [[Package alloc] initWithIdentifier:@"com.darksword.zero-backlight-fade"
                                           name:@"Zero Backlight Fade"
                               shortDescription:@"Instant lock/unlock backlight"
                                longDescription:@"Cuts the backlight fade duration to zero so the display switches on or off instantly on lock and unlock."
                                        version:version
                                         author:@"kolbicz"
                                       category:@"SpringBoard"
                                     symbolName:@"sun.max.fill"
                                           kind:PackageInstallKindToggle
                                     enabledKey:kSettingsDSZeroBacklightFade
                                          isNew:NO],

            [[Package alloc] initWithIdentifier:@"com.darksword.double-tap-to-lock"
                                           name:@"Double-Tap to Lock"
                               shortDescription:@"Lock with a wallpaper double-tap"
                                longDescription:@"Double-tap an empty area of the wallpaper to lock the device. No more reaching for the side button."
                                        version:version
                                         author:@"kolbicz"
                                       category:@"SpringBoard"
                                     symbolName:@"hand.tap.fill"
                                           kind:PackageInstallKindToggle
                                     enabledKey:kSettingsDSDoubleTapToLock
                                          isNew:NO],

            ({
                Package *drag = [[Package alloc] initWithIdentifier:@"com.darksword.drag-coefficient"
                                                               name:@"Drag Coefficient"
                                                   shortDescription:@"Custom SpringBoard animation speed multiplier"
                                                    longDescription:@"Overrides _UIAnimationDragCoefficient in SpringBoard to make all UIKit spring animations faster or slower.\n\nSet the coeffic[...]
                                                            version:version
                                                             author:@"kolbicz"
                                                           category:@"SpringBoard"
                                                         symbolName:@"dial.medium.fill"
                                                               kind:PackageInstallKindToggle
                                                         enabledKey:kSettingsDSDragCoefficientEnabled
                                                              isNew:NO];
                drag.settingsSection = kSecDragCoefficient;
                drag;
            }),

            otaBlock,

            // Higher-risk/manual packages last so their warnings sit below core tweaks.
#if CYANIDE_EXPERIMENTAL_TWEAKS_AVAILABLE
            signal,
#endif
            axon,
            nanoRegistry,
            callRecordingSound,
            hideHomeBar,
#if CYANIDE_EXPERIMENTAL_TWEAKS_AVAILABLE
            typeBanner,
            notificationIsland,
            ipaDecryptor,
            stageStrip,
            fastLockXLite,
#endif
            locationSim,
            snowboardLite,
            liveWP,
            appSwitcherGrid,
            quickLoader,
        ];
    });
    NSArray<Package *> *repoPackages = [self repoPackages];
    if (repoPackages.count == 0) return list;
    return [list arrayByAddingObjectsFromArray:repoPackages];
}

+ (NSArray<NSString *> *)categoriesInOrder
{
    NSArray<NSString *> *preferred = @[
        @"In Development",
        @"Beta",
        @"Experimental",
        @"Status Bar",
        @"Home Screen",
        @"Theming",
        @"SpringBoard",
        @"System",
        @"JavaScript Tweaks",
    ];
    NSMutableArray<NSString *> *all = [NSMutableArray array];
    for (Package *p in [self allPackages]) {
        if (![all containsObject:p.category]) [all addObject:p.category];
    }
    NSMutableArray<NSString *> *order = [NSMutableArray array];
    for (NSString *cat in preferred) {
        if ([all containsObject:cat]) [order addObject:cat];
    }
    for (NSString *cat in all) {
        if (![order containsObject:cat]) [order addObject:cat];
    }
    return order;
}

+ (NSDictionary<NSString *, NSArray<Package *> *> *)packagesByCategory
{
    NSMutableDictionary<NSString *, NSMutableArray<Package *> *> *buckets = [NSMutableDictionary dictionary];
    for (Package *p in [self allPackages]) {
        NSMutableArray<Package *> *bucket = buckets[p.category];
        if (!bucket) {
            bucket = [NSMutableArray array];
            buckets[p.category] = bucket;
        }
        [bucket addObject:p];
    }
    return buckets;
}

@end
