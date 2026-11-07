// MinimalNav: minimalist navigation for the new YouTube layout.
// - The bottom tab bar (pivot bar) is hidden permanently.
// - A profile button appears at the top right next to search.
//   Tap: go to "You" (FElibrary); tap again: back to the Home feed.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <YouTubeHeader/YTSettingsCell.h>
#import <YouTubeHeader/YTSettingsGroupData.h>
#import <YouTubeHeader/YTSettingsSectionItem.h>
#import <YouTubeHeader/YTSettingsSectionItemManager.h>
#import <YouTubeHeader/YTSettingsViewController.h>
#import <YouTubeHeader/YTIIcon.h>

@interface YTIPivotBarItemRenderer : NSObject
- (NSString *)pivotIdentifier;
@end
@interface YTPivotBarItemView : UIView
@property (nonatomic, strong) YTIPivotBarItemRenderer *renderer;
@property (nonatomic, strong) UIButton *navigationButton;
@end
@interface YTRightNavigationButtons : UIView
@property (nonatomic, strong) UIButton *searchButton;
@end
@interface YTPivotBarView : UIView
@end
@interface YTAppViewController : UIViewController
- (void)hidePivotBar;
@end
@interface YTAppViewControllerImpl : UIViewController
- (void)hidePivotBar;
@end

// YouTube itself provides the tab identifiers (FEwhat_to_watch, FElibrary); the
// hardcoded values are only a fallback in case these class methods ever go away.
@interface YTIBrowseRequest : NSObject
+ (NSString *)browseIDForWhatToWatch;
+ (NSString *)browseIDForLibraryTab;
@end
static NSString *MNBrowseID(SEL sel, NSString *fallback) {
    Class c = objc_getClass("YTIBrowseRequest");
    if (c && [c respondsToSelector:sel]) {
        NSString *v = ((NSString *(*)(Class, SEL))objc_msgSend)(c, sel);
        if (v.length) return v;
    }
    return fallback;
}
#define kHome MNBrowseID(@selector(browseIDForWhatToWatch), @"FEwhat_to_watch")
#define kYou  MNBrowseID(@selector(browseIDForLibraryTab), @"FElibrary")
static const NSInteger kButtonTag = 0x4D4E4156; // "MNAV"

#pragma mark - On/off switch

static NSString *const kEnabledKey = @"MinimalNavEnabled";
static const NSInteger kSettingsSection = 'mnav';

// Read once per app launch: the bar is hidden while the UI is being built,
// so toggling only takes effect after a restart.
static BOOL MNEnabled(void) {
    static BOOL enabled; static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        enabled = [d objectForKey:kEnabledKey] ? [d boolForKey:kEnabledKey] : YES;
    });
    return enabled;
}

static BOOL MNGerman(void) { return [[NSLocale preferredLanguages].firstObject hasPrefix:@"de"]; }

static __weak UIView *gPivotBarView;
static __weak UIView *gRightButtons;
static BOOL gUserWantsYou = NO;   // did the user switch to "You" themselves?

#pragma mark - Remember the pivot bar

%hook YTPivotBarView
- (void)didMoveToWindow { %orig; if (self.window) gPivotBarView = self; }
%end

#pragma mark - Never show the bottom bar

%hook YTAppViewController
- (void)showPivotBar { if (MNEnabled()) [self hidePivotBar]; else %orig; }
- (void)viewDidAppear:(BOOL)animated { %orig; if (MNEnabled()) [self hidePivotBar]; }
%end

%hook YTAppViewControllerImpl
- (void)showPivotBar { if (MNEnabled()) [self hidePivotBar]; else %orig; }
- (void)viewDidAppear:(BOOL)animated { %orig; if (MNEnabled()) [self hidePivotBar]; }
%end

#pragma mark - Fetch icons from the hidden bar

// The tabs expose their identifier via the accessibility ID,
// e.g. "id.ui.pivotbar.FElibrary.button". The icon lives on the YTQTMButton.
static void collectItemViews(UIView *v, NSMutableArray *out) {
    if ([v isKindOfClass:objc_getClass("YTPivotBarItemView")]) [out addObject:v];
    for (UIView *sub in v.subviews) collectItemViews(sub, out);
}

// A tab's hidden control (YTPivotBarItemViewAccessibilityControl).
// A real tap on it triggers -[YTPivotBarItemView didTapButton].
// Since early November 2026 YouTube no longer builds the bottom bar as a YTPivotBarView;
// the individual YTPivotBarItemView instances still exist. So remember the tab items themselves
// and only search via the bar or the windows as a last resort.
static NSHashTable *gItemViews;
%hook YTPivotBarItemView
- (void)didMoveToWindow {
    %orig;
    if (!self.window) return;
    if (!gItemViews) gItemViews = [NSHashTable weakObjectsHashTable];
    [gItemViews addObject:self];
}
%end

static NSArray *allItemViews(void) {
    NSMutableArray *out = [NSMutableArray array];
    for (UIView *v in gItemViews) if (v.window) [out addObject:v];
    if (out.count) return out;
    UIView *bar = gPivotBarView;
    if (bar) collectItemViews(bar, out);
    if (!out.count)
        for (UIWindow *w in [UIApplication sharedApplication].windows) collectItemViews(w, out);
    return out;
}

static UIControl *pivotControl(NSString *pivotID) {
    NSString *wanted = [NSString stringWithFormat:@"id.ui.pivotbar.%@.button", pivotID];
    for (UIView *item in allItemViews())
        for (UIView *sub in item.subviews)
            if ([sub isKindOfClass:[UIControl class]] && [sub.accessibilityIdentifier isEqualToString:wanted]) return (UIControl *)sub;
    return nil;
}

static BOOL pivotSelected(NSString *pivotID) {
    UIControl *c = pivotControl(pivotID);
    return c && (c.accessibilityTraits & UIAccessibilityTraitSelected);
}

// Like a tap on the tab: switches tabs instead of opening a new page
static BOOL tapPivot(NSString *pivotID) {
    UIControl *c = pivotControl(pivotID);
    if (!c) return NO;
    [c sendActionsForControlEvents:UIControlEventTouchUpInside];
    return YES;
}

static UIImage *pivotImage(NSString *pivotID) {
    NSString *wanted = [NSString stringWithFormat:@"id.ui.pivotbar.%@.button", pivotID];
    for (UIView *item in allItemViews()) {
        BOOL match = NO;
        for (UIView *sub in item.subviews) if ([sub.accessibilityIdentifier isEqualToString:wanted]) match = YES;
        if (!match) continue;
        for (UIView *sub in item.subviews) {
            if ([sub isKindOfClass:[UIButton class]]) {
                UIImage *img = [(UIButton *)sub imageForState:UIControlStateNormal];
                if (img) return img;
            }
        }
    }
    return nil;
}

#pragma mark - Profile button at the top right

@interface MNTarget : NSObject
+ (void)tapped:(id)sender;
@end
@implementation MNTarget
+ (void)tapped:(id)sender {
    gUserWantsYou = !pivotSelected(kYou);
    NSString *target = gUserWantsYou ? kYou : kHome;
    tapPivot(target);
    // On first open YouTube sometimes only creates the tab without switching to it.
    // In that case tap again after a short delay (at most twice).
    for (NSNumber *delay in @[@0.35, @0.9]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            BOOL wantYou = [target isEqual:kYou];
            if (gUserWantsYou == wantYou && !pivotSelected(target)) tapPivot(target);
            [gRightButtons setNeedsLayout];
        });
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [gRightButtons setNeedsLayout];
    });
}
@end

static UIImage *roundImage(UIImage *img, CGFloat side) {
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side)];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(0, 0, side, side)] addClip];
        [img drawInRect:CGRectMake(0, 0, side, side)];
    }];
}

%hook YTRightNavigationButtons
// Buttons pushed past the left edge must remain tappable
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    if (!MNEnabled()) return %orig;
    for (UIView *v in self.subviews)
        if (!v.hidden && v.alpha > 0.01 && CGRectContainsPoint(v.frame, point)) return YES;
    return %orig;
}

- (void)layoutSubviews {
    %orig;
    if (!MNEnabled()) return;
    gRightButtons = self;

    // On launch YouTube restores the last open tab, sometimes with a delay.
    // During the first 15 s after launch go back to Home, as long as the
    // user has not switched to "You" via the button themselves.
    static CFAbsoluteTime launchTime = 0;
    if (launchTime == 0) launchTime = CFAbsoluteTimeGetCurrent();
    if (!gUserWantsYou && CFAbsoluteTimeGetCurrent() - launchTime < 15 && pivotSelected(kYou)) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!gUserWantsYou && pivotSelected(kYou)) { tapPivot(kHome); [gRightButtons setNeedsLayout]; }
        });
    }

    UIButton *search = self.searchButton;
    if (!search || CGRectIsEmpty(search.frame)) return;

    UIButton *btn = (UIButton *)[self viewWithTag:kButtonTag];
    if (!btn) {
        btn = [UIButton buttonWithType:UIButtonTypeCustom];
        btn.tag = kButtonTag;
        btn.adjustsImageWhenHighlighted = NO;
        [btn addTarget:[MNTarget class] action:@selector(tapped:) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:btn];
    }

    // Shift all visible buttons left by one button width and place the new
    // button at the far right. Remember the last frames we set so the shift
    // does not accumulate if %orig does not re-layout.
    CGFloat w = search.frame.size.width;
    CGFloat maxX = 0;
    for (UIView *v in self.subviews) {
        if (v == btn || v.hidden) continue;
        NSValue *last = objc_getAssociatedObject(v, @selector(layoutSubviews));
        if (last && CGRectEqualToRect(last.CGRectValue, v.frame)) {
            maxX = MAX(maxX, CGRectGetMaxX(v.frame) + w);
            continue;
        }
        maxX = MAX(maxX, CGRectGetMaxX(v.frame));
        CGRect f = v.frame; f.origin.x -= w; v.frame = f;
        objc_setAssociatedObject(v, @selector(layoutSubviews), [NSValue valueWithCGRect:f], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    btn.frame = CGRectMake(maxX - w, search.frame.origin.y, w, search.frame.size.height);

    // Same icon size and color as the search button
    CGSize iconSize = search.imageView.frame.size;
    if (iconSize.width < 1) iconSize = CGSizeMake(24, 24);
    UIColor *tint = search.imageView.tintColor ?: UIColor.labelColor;
    UIImage *img;
    if (pivotSelected(kYou)) {
        img = pivotImage(kHome) ?: [UIImage systemImageNamed:@"house"];
        btn.accessibilityLabel = @"Home";
        img = [img imageWithTintColor:tint renderingMode:UIImageRenderingModeAlwaysOriginal];
    } else {
        UIImage *avatar = pivotImage(kYou);
        // Profile picture may not be loaded yet: retry up to 20 times at one-second intervals
        static int retries = 0;
        if (!avatar && retries < 20) {
            retries++;
            __weak UIView *weakSelf = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [weakSelf setNeedsLayout]; });
        }
        btn.accessibilityLabel = @"Du";
        if (avatar && avatar.renderingMode != UIImageRenderingModeAlwaysTemplate)
            img = roundImage(avatar, iconSize.width);
        else
            img = [(avatar ?: [UIImage systemImageNamed:@"person.crop.circle"]) imageWithTintColor:tint renderingMode:UIImageRenderingModeAlwaysOriginal];
    }
    [btn setImage:img forState:UIControlStateNormal];
    btn.imageView.contentMode = UIViewContentModeScaleAspectFit;
    CGFloat inset = (w - iconSize.width) / 2;
    btn.imageEdgeInsets = UIEdgeInsetsMake(inset, inset, inset, inset);
}
%end


#pragma mark - Section in the YouTube settings

@interface YTSettingsGroupData (MinimalNav)
+ (NSMutableArray <NSNumber *> *)tweaks;
@end
@interface YTSettingsSectionItemManager (MinimalNav)
- (void)updateMinimalNavSectionWithEntry:(id)entry;
@end

// With YouGroupSettings: add the section to its "Tweaks" group
static void MNAddToTweakGroup(void) {
    Class groupData = objc_getClass("YTSettingsGroupData");
    if (!class_getClassMethod(groupData, @selector(tweaks))) return;
    NSMutableArray *tweaks = [groupData tweaks];
    if (![tweaks containsObject:@(kSettingsSection)]) [tweaks addObject:@(kSettingsSection)];
}

%hook YTSettingsGroupData
// Without YouGroupSettings: insert the section into the first settings group
- (NSArray <NSNumber *> *)orderedCategories {
    MNAddToTweakGroup();
    if (self.type != 1 || class_getClassMethod(objc_getClass("YTSettingsGroupData"), @selector(tweaks)))
        return %orig;
    NSMutableArray *cats = [%orig mutableCopy];
    [cats insertObject:@(kSettingsSection) atIndex:0];
    return cats;
}
%end

%hook YTAppSettingsPresentationData
+ (NSArray <NSNumber *> *)settingsCategoryOrder {
    MNAddToTweakGroup();
    NSArray <NSNumber *> *order = %orig;
    NSUInteger i = [order indexOfObject:@(1)];
    if (i == NSNotFound || [order containsObject:@(kSettingsSection)]) return order;
    NSMutableArray *m = [order mutableCopy];
    [m insertObject:@(kSettingsSection) atIndex:i + 1];
    return m;
}
%end

%hook YTSettingsSectionItemManager
%new(v@:@)
- (void)updateMinimalNavSectionWithEntry:(id)entry {
    YTSettingsViewController *delegate = [self valueForKey:@"_dataDelegate"];
    BOOL de = MNGerman();
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    BOOL on = [d objectForKey:kEnabledKey] ? [d boolForKey:kEnabledKey] : YES;
    YTSettingsSectionItem *toggle = [%c(YTSettingsSectionItem) switchItemWithTitle:(de ? @"Aktiviert" : @"Enabled")
        titleDescription:(de ? @"Blendet die untere Leiste aus und zeigt dein Profilbild oben rechts. Wirkt nach einem Neustart der App."
                             : @"Hides the bottom bar and shows your profile picture at the top right. Takes effect after restarting the app.")
        accessibilityIdentifier:nil
        switchOn:on
        switchBlock:^BOOL (YTSettingsCell *cell, BOOL enabled) {
            [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kEnabledKey];
            return YES;
        }
        settingItemId:0];
    NSString *title = @"MinimalNav";
    if ([delegate respondsToSelector:@selector(setSectionItems:forCategory:title:icon:titleDescription:headerHidden:)])
        [delegate setSectionItems:[@[toggle] mutableCopy] forCategory:kSettingsSection title:title icon:nil titleDescription:nil headerHidden:NO];
    else
        [delegate setSectionItems:[@[toggle] mutableCopy] forCategory:kSettingsSection title:title titleDescription:nil headerHidden:NO];
}

- (void)updateSectionForCategory:(NSUInteger)category withEntry:(id)entry {
    if (category == kSettingsSection) { [self updateMinimalNavSectionWithEntry:entry]; return; }
    %orig;
}
%end

%ctor {
    %init;
    // Only after all tweaks have loaded (YouGroupSettings loads later alphabetically)
    dispatch_async(dispatch_get_main_queue(), ^{ MNAddToTweakGroup(); });
}
