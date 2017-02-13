//
//  IssueViewController.m
//  ShipHub
//
//  Created by James Howard on 3/24/16.
//  Copyright © 2016 Real Artists, Inc. All rights reserved.
//

#import "IssueViewController.h"

#import "Analytics.h"
#import "APIProxy.h"
#import "AttachmentManager.h"
#import "Auth.h"
#import "DataStore.h"
#import "DownloadBarViewController.h"
#import "EmptyLabelView.h"
#import "Error.h"
#import "Extras.h"
#import "MetadataStore.h"
#import "MultiDownloadProgress.h"
#import "NSFileWrapper+ImageExtras.h"
#import "Issue.h"
#import "IssueDocumentController.h"
#import "IssueIdentifier.h"
#import "NewLabelController.h"
#import "NewMilestoneController.h"
#import "JSON.h"
#import "UpNextHelper.h"
#import "Account.h"
#import "WebKitExtras.h"

#import <WebKit/WebKit.h>
#import <JavaScriptCore/JavaScriptCore.h>

typedef void (^SaveCompletion)(NSError *error);

NSString *const IssueViewControllerNeedsSaveDidChangeNotification = @"IssueViewControllerNeedsSaveDidChange";
NSString *const IssueViewControllerNeedsSaveKey = @"IssueViewControllerNeedsSave";

static NSString *const WebpackDevServerURL = @"http://localhost:8080/";

// touchbar identifiers
static NSString *const TBMarkdownItemId = @"TBMarkdown";
static NSString *const TBTextItemsId = @"TBText";
static NSString *const TBListItemsId = @"TBList";
static NSString *const TBHeadingItemsId = @"TBHeading";
static NSString *const TBTableItemId = @"TBTable";
static NSString *const TBLinkItemsId = @"TBLinks";
static NSString *const TBRuleItemId = @"TBRule";
static NSString *const TBCodeItemsId = @"TBCodes";
static NSString *const TBQuoteItemsId = @"TBQuotes";


@interface IssueWebView : WebView

@property (copy) NSString *dragPasteboardName;

@end

@interface IssueViewController () <WebFrameLoadDelegate, WebUIDelegate, WebPolicyDelegate, NSTouchBarDelegate> {
    NSMutableDictionary *_saveCompletions;
    NSTimer *_needsSaveTimer;
    
    BOOL _didFinishLoading;
    NSMutableArray *_javaScriptToRun;
    NSInteger _pastedImageCount;
    BOOL _useWebpackDevServer;
    
    NSInteger _spellcheckDocumentTag;
    NSDictionary *_spellcheckContextTarget;
    
    CFAbsoluteTime _lastCheckedForUpdates;
    NSString *_lastStateJSON;
    
    NSString *_commentFocusKey;
}

// Why legacy WebView?
// Because WKWebView doesn't support everything we need :(
// See https://bugs.webkit.org/show_bug.cgi?id=137759
@property IssueWebView *web;

@property DownloadBarViewController *downloadBar;
@property MultiDownloadProgress *downloadProgress;
@property NSTimer *downloadDebounceTimer;

@property EmptyLabelView *nothingLabel;

@property NSTimer *markAsReadTimer;

@property (nonatomic, getter=hasCommentFocus) BOOL commentFocus;

@property NSTouchBar *markdownTouchBar;

@end

@implementation IssueViewController

- (void)dealloc {
    _web.UIDelegate = nil;
    _web.frameLoadDelegate = nil;
    _web.policyDelegate = nil;
    IssueWebView *web = _web;
    RunOnMain(^{
        [web close];
    });
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)loadView {
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(issueDidUpdate:) name:DataStoreDidUpdateProblemsNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyWindowDidChange:) name:NSWindowDidBecomeKeyNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(metadataDidUpdate:) name:DataStoreDidUpdateMetadataNotification object:nil];
    
    NSView *container = [[NSView alloc] initWithFrame:CGRectMake(0, 0, 600, 600)];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(viewDidChangeFrame:) name:NSViewFrameDidChangeNotification object:container];
    
    _web = [[IssueWebView alloc] initWithFrame:container.bounds frameName:nil groupName:nil];
    _web.continuousSpellCheckingEnabled = YES;
    _web.drawsBackground = NO;
    _web.UIDelegate = self;
    _web.frameLoadDelegate = self;
    _web.policyDelegate = self;
    
    [container addSubview:_web];
    
    _nothingLabel = [[EmptyLabelView alloc] initWithFrame:container.bounds];
    _nothingLabel.hidden = YES;
    _nothingLabel.font = [NSFont systemFontOfSize:28.0];
    _nothingLabel.stringValue = NSLocalizedString(@"No Issue Selected", nil);
    [container addSubview:_nothingLabel];
    
    self.view = container;
}

- (void)setCommentFocus:(BOOL)commentFocus {
    if (_commentFocus != commentFocus) {
        _commentFocus = commentFocus;
        
        // update touch bar
        if ([self respondsToSelector:@selector(setTouchBar:)]) {
            self.touchBar = nil;
        }
    }
}

- (NSTouchBar *)makeTouchBar {
    if (!_commentFocus) {
        return nil;
    }
    
    if (!_markdownTouchBar) {
        _markdownTouchBar = [NSTouchBar new];
        _markdownTouchBar.customizationIdentifier = @"md";
        _markdownTouchBar.delegate = self;
        
        _markdownTouchBar.defaultItemIdentifiers = @[TBMarkdownItemId, NSTouchBarItemIdentifierOtherItemsProxy];
    }
    
    return _markdownTouchBar;
}

- (nullable NSTouchBarItem *)touchBar:(NSTouchBar *)touchBar makeItemForIdentifier:(NSTouchBarItemIdentifier)identifier
{
    if ([identifier isEqualToString:TBMarkdownItemId]) {
        NSPopoverTouchBarItem *pop = [[NSPopoverTouchBarItem alloc] initWithIdentifier:identifier];
        NSImage *icon = [NSImage imageNamed:@"MarkdownTBIcon"];
        icon.template = YES;
        pop.collapsedRepresentationImage = icon;
        
        NSTouchBar *popBar = [NSTouchBar new];
        popBar.delegate = self;
        popBar.customizationIdentifier = @"mditems";
        popBar.delegate = self;
        
        popBar.defaultItemIdentifiers = @[TBTextItemsId, TBListItemsId, TBTableItemId, TBLinkItemsId, TBCodeItemsId, TBQuoteItemsId];
        
        pop.popoverTouchBar = popBar;
        
        return pop;
    } else if ([identifier isEqualToString:TBTextItemsId]) {
        NSImage *bold = [NSImage imageNamed:NSImageNameTouchBarTextBoldTemplate];
        NSImage *italic = [NSImage imageNamed:NSImageNameTouchBarTextItalicTemplate];
        NSImage *strike = [NSImage imageNamed:NSImageNameTouchBarTextStrikethroughTemplate];
        bold.template = italic.template = strike.template = YES;
        
        NSSegmentedControl *seg = [NSSegmentedControl segmentedControlWithImages:@[bold, italic, strike] trackingMode:NSSegmentSwitchTrackingMomentary target:self action:@selector(mdTbText:)];
        
        NSCustomTouchBarItem *item = [[NSCustomTouchBarItem alloc] initWithIdentifier:identifier];
        item.view = seg;
        
        return item;
    } else if ([identifier isEqualToString:TBListItemsId]) {
        NSImage *ulImage = [NSImage imageNamed:NSImageNameTouchBarTextListTemplate];
        NSImage *olImage = [NSImage imageNamed:@"MarkdownTBOrderedList"];
        NSImage *taskLImage = [NSImage imageNamed:@"MarkdownTBTaskList"];
        ulImage.template = olImage.template = taskLImage.template = YES;
        
        NSSegmentedControl *seg = [NSSegmentedControl segmentedControlWithImages:@[ulImage, olImage, taskLImage] trackingMode:NSSegmentSwitchTrackingMomentary target:self action:@selector(mdTbList:)];
        
        NSCustomTouchBarItem *item = [[NSCustomTouchBarItem alloc] initWithIdentifier:identifier];
        item.view = seg;
        
        return item;
    } else if ([identifier isEqualToString:TBHeadingItemsId]) {
        NSImage *headingInc = [NSImage imageNamed:@"MarkdownTBHeadingIncrease"];
        NSImage *headingDec = [NSImage imageNamed:@"MarkdownTBHeadingDecrease"];
        headingInc.template = headingDec.template = YES;
        
        NSSegmentedControl *seg = [NSSegmentedControl segmentedControlWithImages:@[headingInc, headingDec] trackingMode:NSSegmentSwitchTrackingMomentary target:self action:@selector(mdTbHeading:)];
        
        NSCustomTouchBarItem *item = [[NSCustomTouchBarItem alloc] initWithIdentifier:identifier];
        item.view = seg;
        
        return item;
    } else if ([identifier isEqualToString:TBTableItemId]) {
        NSImage *table = [NSImage imageNamed:@"MarkdownTBTable"];
        //NSImage *rule = [NSImage imageNamed:@"MarkdownTBRule"];
        table.template = YES;
        // rule.template = YES;
        
        NSSegmentedControl *seg = [NSSegmentedControl segmentedControlWithImages:@[table/*, rule*/] trackingMode:NSSegmentSwitchTrackingMomentary target:self action:@selector(mdTbTableRule:)];
        
        NSCustomTouchBarItem *item = [[NSCustomTouchBarItem alloc] initWithIdentifier:identifier];
        item.view = seg;
        
        return item;
    } else if ([identifier isEqualToString:TBLinkItemsId]) {
        //NSImage *image = [NSImage imageNamed:@"MarkdownTBImage"];
        NSImage *link = [NSImage imageNamed:@"MarkdownTBHyperlink"];
        //image.template = YES;
        link.template = YES;
        
        NSSegmentedControl *seg = [NSSegmentedControl segmentedControlWithImages:@[/*image, */link] trackingMode:NSSegmentSwitchTrackingMomentary target:self action:@selector(mdTbLink:)];
        
        NSCustomTouchBarItem *item = [[NSCustomTouchBarItem alloc] initWithIdentifier:identifier];
        item.view = seg;
        
        return item;
    } else if ([identifier isEqualToString:TBCodeItemsId]) {
        NSImage *inLine = [NSImage imageNamed:@"MarkdownTBCodeInline"];
        NSImage *block = [NSImage imageNamed:@"MarkdownTBCodeBlock"];
        
        NSSegmentedControl *seg = [NSSegmentedControl segmentedControlWithImages:@[inLine, block] trackingMode:NSSegmentSwitchTrackingMomentary target:self action:@selector(mdTbCode:)];
        
        NSCustomTouchBarItem *item = [[NSCustomTouchBarItem alloc] initWithIdentifier:identifier];
        item.view = seg;
        
        return item;
    } else if ([identifier isEqualToString:TBQuoteItemsId]) {
        NSImage *inc = [NSImage imageNamed:@"MarkdownTBQuoteMore"];
        NSImage *dec = [NSImage imageNamed:@"MarkdownTBQuoteLess"];
        inc.template = dec.template = YES;
        
        NSSegmentedControl *seg = [NSSegmentedControl segmentedControlWithImages:@[inc, dec] trackingMode:NSSegmentSwitchTrackingMomentary target:self action:@selector(mdTbQuote:)];
        
        NSCustomTouchBarItem *item = [[NSCustomTouchBarItem alloc] initWithIdentifier:identifier];
        item.view = seg;
        
        return item;
    }
    
    return nil;
}

- (void)viewDidChangeFrame:(NSNotification *)note {
    [self layoutSubviews];
}

- (void)layoutSubviews {
    CGRect b = self.view.bounds;
    if (_downloadProgress && !_downloadDebounceTimer) {
        CGRect downloadFrame = CGRectMake(0, 0, CGRectGetWidth(b), _downloadBar.view.frame.size.height);
        _downloadBar.view.frame = downloadFrame;
        
        CGRect webFrame = CGRectMake(0, CGRectGetMaxY(downloadFrame), CGRectGetWidth(b), CGRectGetHeight(b) - CGRectGetHeight(downloadFrame));
        _web.frame = webFrame;
    } else {
        _web.frame = self.view.bounds;
        if (_downloadBar.viewLoaded) {
            _downloadBar.view.frame = CGRectMake(0, -_downloadBar.view.frame.size.height, CGRectGetWidth(b), _downloadBar.view.frame.size.height);
        }
    }
    _nothingLabel.frame = _web.frame;
}

- (IBAction)scrollPageUp:(id)sender {
    [_web.mainFrame.frameView scrollPageUp:sender];
}

- (IBAction)scrollPageDown:(id)sender {
    [_web.mainFrame.frameView scrollPageDown:sender];
}

- (NSURL *)indexURL {
    static dispatch_once_t onceToken;
    static NSURL *URL;
    dispatch_once(&onceToken, ^{
        BOOL useWebpack = [[NSUserDefaults standardUserDefaults] boolForKey:@"UseWebpackDevServer"];
        if (useWebpack) {
            URL = [NSURL URLWithString:WebpackDevServerURL];
        } else {
            URL = [NSURL fileURLWithPath:[[NSBundle mainBundle] pathForResource:@"index" ofType:@"html" inDirectory:@"IssueWeb"]];
        }
    });
    return URL;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    
#if DEBUG
    _useWebpackDevServer = [[NSUserDefaults standardUserDefaults] boolForKey:@"UseWebpackDevServer"];
#endif
    
    NSURL *URL = [self indexURL];
    NSURLRequest *request = [NSURLRequest requestWithURL:URL];
    [_web.mainFrame loadRequest:request];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(webViewDidChange:) name:WebViewDidChangeNotification object:_web];
}

- (void)configureNewIssue {
    [self evaluateJavaScript:@"configureNewIssue();"];
    _web.hidden = NO;
    _nothingLabel.hidden = YES;

    [[Analytics sharedInstance] track:@"New Issue"];
}

- (NSString *)issueStateJSON:(Issue *)issue {
    MetadataStore *meta = [[DataStore activeStore] metadataStore];
    
    NSMutableDictionary *state = [NSMutableDictionary new];
    state[@"issue"] = issue;
    
    state[@"me"] = [Account me];
    state[@"token"] = [[[DataStore activeStore] auth] ghToken];
    state[@"repos"] = [meta activeRepos];
    
    if (issue.repository) {
        state[@"assignees"] = [meta assigneesForRepo:issue.repository];
        state[@"milestones"] = [meta activeMilestonesForRepo:issue.repository];
        state[@"labels"] = [meta labelsForRepo:issue.repository];
    } else {
        state[@"assignees"] = @[];
        state[@"milestones"] = @[];
        state[@"labels"] = @[];
    }
    
    return [JSON stringifyObject:state withNameTransformer:[JSON underbarsAndIDNameTransformer]];
}

- (void)updateTitle {
    self.title = _issue.title ?: NSLocalizedString(@"New Issue", nil);
}

- (void)setIssue:(Issue *)issue {
    [self setIssue:issue scrollToCommentWithIdentifier:nil];
}

- (void)setIssue:(Issue *)issue scrollToCommentWithIdentifier:(NSNumber *)commentIdentifier {
    dispatch_assert_current_queue(dispatch_get_main_queue());
    //DebugLog(@"%@", issue);
    BOOL identifierChanged = ![NSObject object:_issue.fullIdentifier isEqual:issue.fullIdentifier];
    BOOL shouldScrollToTop = issue != nil && _issue != nil && identifierChanged;
    _issue = issue;
    if (issue) {
        NSString *issueJSON = [self issueStateJSON:issue];
        _lastStateJSON = issueJSON;
        NSString *js = [NSString stringWithFormat:@"applyIssueState(%@, %@)", issueJSON, commentIdentifier];
        //DebugLog(@"%@", js);
        [self evaluateJavaScript:js];
        if (shouldScrollToTop && !commentIdentifier) {
            [self evaluateJavaScript:@"window.scroll(0, 0)"];
        }
    }
    [self updateTitle];
    BOOL hidden = _issue == nil;
    _web.hidden = hidden;
    _nothingLabel.hidden = !hidden;

    if (issue && identifierChanged) {
        [[Analytics sharedInstance] track:@"View Issue"];
    }
}

- (void)scrollToCommentWithIdentifier:(NSNumber *)commentIdentifier {
    NSString *js = [NSString stringWithFormat:@"scrollToCommentWithIdentifier(%@)", [JSON stringifyObject:commentIdentifier]];
    [self evaluateJavaScript:js];
}

- (void)noteCheckedForIssueUpdates {
    _lastCheckedForUpdates = CFAbsoluteTimeGetCurrent();
}

- (void)checkForIssueUpdates {
    if (_issue.fullIdentifier) {
        [self noteCheckedForIssueUpdates];
        [[DataStore activeStore] checkForIssueUpdates:_issue.fullIdentifier];
    }
}

- (void)keyWindowDidChange:(NSNotification *)note {
    if ([self.view.window isKeyWindow]) {
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (now - _lastCheckedForUpdates > 30.0) {
            [self checkForIssueUpdates];
        }
        [self scheduleMarkAsReadTimerIfNeeded];
    }
}

- (void)setColumnBrowser:(BOOL)columnBrowser {
    _columnBrowser = columnBrowser;
    
    [self evaluateJavaScript:
     [NSString stringWithFormat:
      @"window.setInColumnBrowser(%@)",
      (_columnBrowser ? @"true" : @"false")]];
}

- (void)markAsReadTimerFired:(NSTimer *)timer {
    _markAsReadTimer = nil;
    if ([_issue.fullIdentifier isEqualToString:timer.userInfo] && _issue.unread) {
        NSWindow *window = self.view.window;
        if ([window isKeyWindow]) {
            [[DataStore activeStore] markIssueAsRead:timer.userInfo];
        }
    }
}

- (void)scheduleMarkAsReadTimerIfNeeded {
    if (!_issue) {
        [_markAsReadTimer invalidate];
        _markAsReadTimer = nil;
        return;
    }
    if (_markAsReadTimer && ![_markAsReadTimer.userInfo isEqualToString:_issue.fullIdentifier]) {
        [_markAsReadTimer invalidate];
        _markAsReadTimer = nil;
    }
    if (_issue.unread && !_markAsReadTimer) {
        _markAsReadTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 weakTarget:self selector:@selector(markAsReadTimerFired:) userInfo:_issue.fullIdentifier repeats:NO];
    }
}

- (void)issueDidUpdate:(NSNotification *)note {
    if (!_issue) return;
    if ([note object] == [DataStore activeStore]) {
        NSArray *updated = note.userInfo[DataStoreUpdatedProblemsKey];
        if ([updated containsObject:_issue.fullIdentifier]) {
            [[DataStore activeStore] loadFullIssue:_issue.fullIdentifier completion:^(Issue *issue, NSError *error) {
                if (issue) {
                    self.issue = issue;
                    [self scheduleMarkAsReadTimerIfNeeded];
                }
            }];
        }
    }
}

- (void)metadataDidUpdate:(NSNotification *)note {
    if (_issue.fullIdentifier && [note object] == [DataStore activeStore]) {
        NSString *json = [self issueStateJSON:_issue];
        if (![json isEqualToString:_lastStateJSON]) {
            DebugLog(@"issueStateJSON changed, reloading");
            [[DataStore activeStore] loadFullIssue:_issue.fullIdentifier completion:^(Issue *issue, NSError *error) {
                if ([issue.fullIdentifier isEqualToString:_issue.fullIdentifier]) {
                    self.issue = issue;
                }
            }];
        }
    }
}

- (void)evaluateJavaScript:(NSString *)js {
    if (!_didFinishLoading) {
        if (!_javaScriptToRun) {
            _javaScriptToRun = [NSMutableArray new];
        }
        [_javaScriptToRun addObject:js];
    } else {
        [_web stringByEvaluatingJavaScriptFromString:js];
    }
}

#pragma mark - WebUIDelegate

- (void)webView:(WebView *)sender runOpenPanelForFileButtonWithResultListener:(id<WebOpenPanelResultListener>)resultListener allowMultipleFiles:(BOOL)allowMultipleFiles
{
    NSOpenPanel* panel = [NSOpenPanel openPanel];
    
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = NO;
    panel.allowsMultipleSelection = allowMultipleFiles;
    
    [panel beginSheetModalForWindow:self.view.window completionHandler:^(NSInteger result) {
        if (result == NSFileHandlingPanelOKButton) {
            [resultListener chooseFilenames:[panel.URLs arrayByMappingObjects:^id(NSURL * obj) {
                return [obj path];
            }]];
        } else {
            [resultListener cancel];
        }
    }];
}

- (void)webView:(WebView *)sender runJavaScriptAlertPanelWithMessage:(NSString *)message initiatedByFrame:(WebFrame *)frame
{
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = message;
    
    [alert beginSheetModalForWindow:self.view.window completionHandler:nil];
}

- (NSArray *)webView:(WebView *)sender contextMenuItemsForElement:(NSDictionary *)element defaultMenuItems:(NSArray *)defaultMenuItems {
    NSArray *menuItems = defaultMenuItems;
    
    if (_spellcheckContextTarget) {
        NSDictionary *target = _spellcheckContextTarget;
        _spellcheckContextTarget = nil;
        
        NSSpellChecker *checker = [NSSpellChecker sharedSpellChecker];
        NSString *contents = target[@"text"];
        NSArray *guesses = [checker guessesForWordRange:NSMakeRange(0, contents.length) inString:contents language:nil inSpellDocumentWithTag:_spellcheckDocumentTag];
        
        NSMutableArray *items = [NSMutableArray new];
        if ([guesses count] == 0) {
            NSMenuItem *noGuesses = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"No Guesses Found", nil) action:@selector(fixSpelling:) keyEquivalent:@""];
            noGuesses.enabled = NO;
            [items addObject:noGuesses];
        } else {
            
            for (NSString *guess in guesses) {
                NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:guess action:@selector(fixSpelling:) keyEquivalent:@""];
                item.target = self;
                item.representedObject = target;
                [items addObject:item];
            }
        }
        
        [items addObject:[NSMenuItem separatorItem]];
        
        [items addObjectsFromArray:defaultMenuItems];
        
        menuItems = items;
    }
    
    for (NSMenuItem *i in menuItems) {
        switch (i.tag) {
            case 2000: /* WebMenuItemTagOpenLink */
                i.hidden = YES;
            case WebMenuItemTagOpenLinkInNewWindow:
                i.target = self;
                i.action = @selector(openLinkInNewWindow:);
                break;
            case WebMenuItemTagOpenImageInNewWindow:
                i.target = self;
                i.action = @selector(openImageInNewWindow:);
                break;
            case WebMenuItemTagDownloadLinkToDisk:
                i.target = self;
                i.action = @selector(downloadLinkToDisk:);
                break;
            case WebMenuItemTagDownloadImageToDisk:
                i.target = self;
                i.action = @selector(downloadImageToDisk:);
                break;
            default: break;
        }
    }
    
    return menuItems;
}

- (void)fixSpelling:(id)sender {
    NSString *callback = [NSString stringWithFormat:@"window.spellcheckFixer(%@, %@);", [JSON stringifyObject:[sender representedObject]], [JSON stringifyObject:[sender title]]];
    [self evaluateJavaScript:callback];
}

- (void)openLinkInNewWindow:(id)sender {
    NSMenuItem *item = sender;
    NSDictionary *element = item.representedObject;
    NSURL *URL = element[WebElementLinkURLKey];
    if (URL) {
        id issueIdentifier = [NSString issueIdentifierWithGitHubURL:URL];
        if (issueIdentifier) {
            [[IssueDocumentController sharedDocumentController] openIssueWithIdentifier:issueIdentifier];
        } else {
            [[NSWorkspace sharedWorkspace] openURL:URL];
        }
    }
}

- (void)openImageInNewWindow:(id)sender {
    NSMenuItem *item = sender;
    NSDictionary *element = item.representedObject;
    NSURL *URL = element[WebElementImageURLKey];
    if (URL) {
        [[NSWorkspace sharedWorkspace] openURL:URL];
    }
}

- (void)downloadLinkToDisk:(id)sender {
    NSMenuItem *item = sender;
    NSDictionary *element = item.representedObject;
    NSURL *URL = element[WebElementLinkURLKey];
    if (URL) {
        [self downloadURL:URL];
    }
}

- (void)downloadImageToDisk:(id)sender {
    NSMenuItem *item = sender;
    NSDictionary *element = item.representedObject;
    NSURL *URL = element[WebElementImageURLKey];
    if (URL) {
        [self downloadURL:URL];
    }
}

- (void)downloadURL:(NSURL *)URL {
    // Use a save panel to play nice with sandboxing
    NSSavePanel *panel = [NSSavePanel new];
    
    NSString *UTI = [[URL pathExtension] UTIFromExtension];
    if (UTI) {
        panel.allowedFileTypes = @[UTI];
    }
    
    NSString *filename = [[[URL path] lastPathComponent] stringByRemovingPercentEncoding];
    panel.nameFieldStringValue = filename;
    NSString *downloadsDir = [NSSearchPathForDirectoriesInDomains(NSDownloadsDirectory, NSUserDomainMask, YES) firstObject];
    panel.directoryURL = [NSURL fileURLWithPath:downloadsDir];
    
    [panel beginSheetModalForWindow:self.view.window completionHandler:^(NSInteger result) {
        if (result == NSFileHandlingPanelOKButton) {
            NSURL *destination = panel.URL;
            
            __block __strong NSProgress *downloadProgress = nil;
            
            CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
            
            void (^completionHandler)(NSURL *, NSURLResponse *, NSError *) = ^(NSURL *location, NSURLResponse *response, NSError *error) {
                NSError *err = error;
                if (location) {
                    // Move downloaded file into place
                    [[NSFileManager defaultManager] replaceItemAtURL:destination withItemAtURL:location backupItemName:nil options:NSFileManagerItemReplacementUsingNewMetadataOnly resultingItemURL:NULL error:&err];
                    
                    // Bounce destination directory in dock
                    NSString *parentPath = [[destination path] stringByDeletingLastPathComponent];
                    [[NSDistributedNotificationCenter defaultCenter] postNotificationName:@"com.apple.DownloadFileFinished" object:parentPath];
                    
                    // Show the item in the finder if it didn't take too long to download or we're being watched
                    RunOnMain(^{
                        CFAbsoluteTime duration = CFAbsoluteTimeGetCurrent() - start;
                        if (duration < 2.0 || [self.view.window isKeyWindow]) {
                            [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[destination]];
                        }
                    });
                }
                if (err && ![err isCancelError]) {
                    ErrLog(@"%@", err);
                    RunOnMain(^{
                        NSAlert *alert = [NSAlert alertWithError:err];
                        [alert beginSheetModalForWindow:self.view.window completionHandler:NULL];
                    });
                }
                
                [self removeDownloadProgress:downloadProgress];
            };
            
            NSURLSessionDownloadTask *task = [[NSURLSession sharedSession] downloadTaskWithURL:URL completionHandler:completionHandler];
            task.taskDescription = [NSString stringWithFormat:NSLocalizedString(@"Downloading %@ …", nil), filename];
            downloadProgress = [task downloadProgress];
            [self addDownloadProgress:downloadProgress];
            [task resume];
        }
    }];
}

- (void)animateDownloadBar {
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext * _Nonnull context) {
        [context setDuration:0.1];
        [context setAllowsImplicitAnimation:YES];
        [context setTimingFunction:[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut]];
        [self layoutSubviews];
    } completionHandler:nil];
}

- (void)downloadDebounceTimerFired:(NSTimer *)timer {
    _downloadDebounceTimer = nil;
    if (_downloadProgress) {
        [self animateDownloadBar];
    }
}

- (void)addDownloadProgress:(NSProgress *)progress {
    dispatch_assert_current_queue(dispatch_get_main_queue());
    
    if (!_downloadProgress) {
        if (!_downloadBar) {
            _downloadBar = [DownloadBarViewController new];
            [self.view addSubview:_downloadBar.view];
            [self layoutSubviews];
        }
        
        _downloadProgress = [MultiDownloadProgress new];
        [_downloadProgress addChild:progress];
        _downloadBar.progress = _downloadProgress;
        
        if (!_downloadDebounceTimer) {
            // Prevent download bar from appearing unless we're waiting for more than a beat
            _downloadDebounceTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 target:self selector:@selector(downloadDebounceTimerFired:) userInfo:nil repeats:NO];
        }
    } else {
        [_downloadProgress addChild:progress];
    }
}

- (void)removeDownloadProgress:(NSProgress *)progress {
    RunOnMain(^{
        [_downloadProgress removeChild:progress];
        if (_downloadProgress.childProgressArray.count == 0) {
            [_downloadDebounceTimer invalidate];
            _downloadDebounceTimer = nil;
            
            _downloadProgress = nil;
            [self animateDownloadBar];
        }
    });
}

#pragma mark - WebFrameLoadDelegate

- (void)webView:(WebView *)webView didClearWindowObject:(WebScriptObject *)windowObject forFrame:(WebFrame *)frame {
    __weak __typeof(self) weakSelf = self;
    [windowObject addScriptMessageHandlerBlock:^(NSDictionary *msg) {
        [weakSelf proxyAPI:msg];
    } name:@"inAppAPI"];
    
    [windowObject addScriptMessageHandlerBlock:^(NSDictionary *msg) {
        [weakSelf pasteHelper:msg];
    } name:@"inAppPasteHelper"];
    
    [windowObject addScriptMessageHandlerBlock:^(NSDictionary *msg) {
        [weakSelf scheduleNeedsSaveTimer];
    } name:@"documentEditedHelper"];
    
    [windowObject addScriptMessageHandlerBlock:^(NSDictionary *msg) {
        [weakSelf handleDocumentSaved:msg];
    } name:@"documentSaveHandler"];

    [[windowObject JSValue] setValue:^(NSString *name, NSArray *allLabels, NSString *owner, NSString *repo, JSValue *completionCallback){
        [weakSelf handleNewLabelWithName:name allLabels:allLabels owner:owner repo:repo completionCallback:(JSValue *)completionCallback];
    } forProperty:@"newLabel"];
    
    [[windowObject JSValue] setValue:^(NSString *name, NSString *owner, NSString *repo, JSValue *completionCallback){
        [weakSelf handleNewMilestoneWithName:name owner:owner repo:repo completionCallback:completionCallback];
    } forProperty:@"newMilestone"];
    
    [windowObject addScriptMessageHandlerBlock:^(NSDictionary *msg) {
        [weakSelf spellcheck:msg];
    } name:@"spellcheck"];
    
    [windowObject addScriptMessageHandlerBlock:^(NSDictionary *msg) {
        [weakSelf javascriptLoadComplete];
    } name:@"loadComplete"];
    
    [windowObject addScriptMessageHandlerBlock:^(NSDictionary *msg) {
        [weakSelf handleCommentFocus:msg];
    } name:@"inAppCommentFocus"];
    
    NSString *setupJS =
    @"window.inApp = true;\n"
    @"window.postAppMessage = function(msg) { window.inAppAPI.postMessage(msg); }\n";
    
    NSString *apiToken = [[[DataStore activeStore] auth] ghToken];
    setupJS = [setupJS stringByAppendingFormat:@"window.setAPIToken(\"%@\");\n", apiToken];
    
    [windowObject evaluateWebScript:setupJS];
}

- (void)javascriptLoadComplete {
    _didFinishLoading = YES;
    NSArray *toRun = _javaScriptToRun;
    _javaScriptToRun = nil;
    for (NSString *script in toRun) {
        [self evaluateJavaScript:script];
    }
}

#pragma mark - WebPolicyDelegate

- (void)webView:(WebView *)webView decidePolicyForNavigationAction:(NSDictionary *)actionInformation request:(NSURLRequest *)request frame:(WebFrame *)frame decisionListener:(id<WebPolicyDecisionListener>)listener
{
    //DebugLog(@"%@", actionInformation);
    
    WebNavigationType navigationType = [actionInformation[WebActionNavigationTypeKey] integerValue];
    
    if (navigationType == WebNavigationTypeReload) {
        if (_useWebpackDevServer) {
            // The webpack-dev-server page will auto-refresh as the content updates,
            // so reloading needs to be allowed.
            
            _didFinishLoading = NO;
            
            if (_issue) {
                [self setIssue:_issue];
                [self reload:nil];
            } else {
                [self configureNewIssue];
            }
            
            [listener use];
        } else {
            [self reload:nil];
            [listener ignore];
        }
    } else if (navigationType == WebNavigationTypeOther) {
        NSURL *URL = actionInformation[WebActionOriginalURLKey];
        if ([URL isEqual:[self indexURL]]) {
            [listener use];
        } else {
            [listener ignore];
        }
    } else {
        NSURL *URL = actionInformation[WebActionOriginalURLKey];
        id issueIdentifier = [NSString issueIdentifierWithGitHubURL:URL];
        
        if (issueIdentifier) {
            [[IssueDocumentController sharedDocumentController] openIssueWithIdentifier:issueIdentifier];
        } else {
            [[NSWorkspace sharedWorkspace] openURL:URL];
        }
        
        [listener ignore];
    }
}

- (void)webView:(WebView *)webView decidePolicyForNewWindowAction:(NSDictionary *)actionInformation request:(NSURLRequest *)request newFrameName:(NSString *)frameName decisionListener:(id<WebPolicyDecisionListener>)listener
{
    NSURL *URL = actionInformation[WebActionOriginalURLKey];
    id issueIdentifier = [NSString issueIdentifierWithGitHubURL:URL];
    
    if (issueIdentifier) {
        [[IssueDocumentController sharedDocumentController] openIssueWithIdentifier:issueIdentifier];
    } else {
        [[NSWorkspace sharedWorkspace] openURL:URL];
    }
    
    [listener ignore];
}

#pragma mark WebView Notifications

- (void)needsSaveTimerFired:(NSNotification *)note {
    _needsSaveTimer = nil;
    [[NSNotificationCenter defaultCenter] postNotificationName:IssueViewControllerNeedsSaveDidChangeNotification object:self userInfo:@{ IssueViewControllerNeedsSaveKey : @([self needsSave]) }];
}

- (void)scheduleNeedsSaveTimer {
    if (!_needsSaveTimer) {
        _needsSaveTimer = [NSTimer scheduledTimerWithTimeInterval:0.1 target:self selector:@selector(needsSaveTimerFired:) userInfo:nil repeats:NO];
    }
}

- (void)webViewDidChange:(NSNotification *)note {
    [self scheduleNeedsSaveTimer];
}

#pragma mark - Javascript Bridge

- (void)proxyAPI:(NSDictionary *)msg {
    //DebugLog(@"%@", msg);
    
    APIProxy *proxy = [APIProxy proxyWithRequest:msg completion:^(NSString *jsonResult, NSError *err) {
        dispatch_assert_current_queue(dispatch_get_main_queue());
        
        if (err) {
            BOOL isMutation = ![msg[@"opts"][@"method"] isEqualToString:@"GET"];
            
            if (isMutation) {
                NSAlert *alert = [NSAlert new];
                alert.alertStyle = NSCriticalAlertStyle;
                alert.messageText = NSLocalizedString(@"Unable to save issue", nil);
                alert.informativeText = [err localizedDescription] ?: @"";
                [alert addButtonWithTitle:NSLocalizedString(@"Retry", nil)];
                [alert addButtonWithTitle:NSLocalizedString(@"Discard Changes", nil)];
                
                [alert beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse returnCode) {
                    if (returnCode == NSAlertFirstButtonReturn) {
                        [self proxyAPI:msg];
                    } else {
                        NSString *callback;
                        callback = [NSString stringWithFormat:@"apiCallback(%@, null, %@)", msg[@"handle"], [JSON stringifyObject:[err localizedDescription]]];
                        [self evaluateJavaScript:callback];
                        [self revert:nil];
                    }
                }];
            } else {
                NSString *callback;
                callback = [NSString stringWithFormat:@"apiCallback(%@, null, %@)", msg[@"handle"], [JSON stringifyObject:[err localizedDescription]]];
                [self evaluateJavaScript:callback];
            }
        } else {
            NSString *callback = [NSString stringWithFormat:@"apiCallback(%@, %@, null)", msg[@"handle"], jsonResult];
            [self evaluateJavaScript:callback];
        }
    }];
    [proxy setUpdatedIssueHandler:^(Issue *updatedIssue) {
        if (_issue.fullIdentifier == nil || [_issue.fullIdentifier isEqualToString:updatedIssue.fullIdentifier]) {
            _issue = updatedIssue;
            [self updateTitle];
            [self scheduleNeedsSaveTimer];
        }
    }];
    [proxy resume];
}

- (NSString *)placeholderWithWrapper:(NSFileWrapper *)wrapper {
    NSString *filename = wrapper.preferredFilename ?: @"attachment";
    if ([wrapper isImageType]) {
        return [NSString stringWithFormat:@"![Uploading %@](...)", filename];
    } else {
        return [NSString stringWithFormat:@"[Uploading %@](...)", filename];
    }
}

- (NSString *)linkWithWrapper:(NSFileWrapper *)wrapper URL:(NSURL *)linkURL {
    NSString *filename = wrapper.preferredFilename ?: @"attachment";
    if ([wrapper isImageType]) {
        NSImage *image = [wrapper image];
        if ([image isHiDPI]) {
            // for hidpi images we want to write an <img> tag instead of using markdown syntax, as this will prevent it from drawing too large.
            filename = [filename stringByReplacingOccurrencesOfString:@"'" withString:@"`"];
            CGSize size = image.size;
            // Workaround for realartists/shiphub-cocoa#241 Image attachments from Ship appear stretched / squished when viewed on github.com
            // Only include the image width, not the height so GitHub doesn't get confused.
            return [NSString stringWithFormat:@"<img src='%@' title='%@' width=%.0f>", linkURL, filename, size.width];
        } else {
            return [NSString stringWithFormat:@"![%@](%@)", filename, linkURL];
        }
    } else {
        return [NSString stringWithFormat:@"[%@](%@)", filename, linkURL];
    }
}

- (void)pasteWrappers:(NSArray<NSFileWrapper *> *)wrappers handle:(NSNumber *)handle {
    NSMutableString *pasteString = [NSMutableString new];
    
    __block NSInteger pendingUploads = wrappers.count;
    for (NSFileWrapper *wrapper in wrappers) {
        NSString *placeholder = [self placeholderWithWrapper:wrapper];
        
        [[AttachmentManager sharedManager] uploadAttachment:wrapper completion:^(NSURL *destinationURL, NSError *error) {
            NSString *js = nil;
            
            dispatch_assert_current_queue(dispatch_get_main_queue());
            
            if (error) {
                js = [NSString stringWithFormat:@"pasteCallback(%@, 'uploadFailed', %@)", handle, [JSON stringifyObject:@{@"placeholder": placeholder, @"err": [error localizedDescription]}]];
            } else {
                NSString *link = [self linkWithWrapper:wrapper URL:destinationURL];
                js = [NSString stringWithFormat:@"pasteCallback(%@, 'uploadFinished', %@)", handle, [JSON stringifyObject:@{@"placeholder": placeholder, @"link": link}]];
            }
            
            //DebugLog(@"%@", js);
            [self evaluateJavaScript:js];
            
            pendingUploads--;
            
            if (pendingUploads == 0) {
                js = [NSString stringWithFormat:@"pasteCallback(%@, 'completed')", handle];
                [self evaluateJavaScript:js];
            }
        }];
        
        [pasteString appendFormat:@"%@\n", placeholder];
    }
    
    NSString *js = [NSString stringWithFormat:
                    @"pasteCallback(%@, 'pasteText', %@);\n"
                    @"pasteCallback(%@, 'uploadsStarted', %tu);\n",
                    handle, [JSON stringifyObject:pasteString],
                    handle, wrappers.count];
    //DebugLog(@"%@", js);
    [self evaluateJavaScript:js];
}

- (void)selectAttachments:(NSNumber *)handle {
    NSOpenPanel* panel = [NSOpenPanel openPanel];
    
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = NO;
    panel.allowsMultipleSelection = YES;
    
    [panel beginSheetModalForWindow:self.view.window completionHandler:^(NSInteger result) {
        if (result == NSFileHandlingPanelOKButton && panel.URLs.count > 0) {
            NSArray *wrappers = [panel.URLs arrayByMappingObjects:^id(id obj) {
                return [[NSFileWrapper alloc] initWithURL:obj options:0 error:NULL];
            }];
            
            [self pasteWrappers:wrappers handle:handle];
        } else {
            // cancel
            NSString *js = [NSString stringWithFormat:@"pasteCallback(%@, 'completed')", handle];
            [self evaluateJavaScript:js];
        }
    }];
}

- (void)pasteHelper:(NSDictionary *)msg {
    NSNumber *handle = msg[@"handle"];
    NSString *pasteboardName = msg[@"pasteboard"];
    
    NSPasteboard *pasteboard = nil;
    if ([pasteboardName isEqualToString:@"dragging"]) {
        pasteboard = [NSPasteboard pasteboardWithName:_web.dragPasteboardName?:NSDragPboard];
    } else if ([pasteboardName isEqualToString:@"NSOpenPanel"]) {
        [self selectAttachments:handle];
    } else {
        pasteboard = [NSPasteboard generalPasteboard];
    }
    
    NSString *callback;
    
#if DEBUG
    for (NSPasteboardItem *item in pasteboard.pasteboardItems) {
        DebugLog(@"Saw item %@, with types %@", item, item.types);
    }
#endif
    
    if ([pasteboard canReadItemWithDataConformingToTypes:@[NSFilenamesPboardType, NSFilesPromisePboardType, (__bridge NSString *)kPasteboardTypeFileURLPromise, (__bridge NSString *)kUTTypeFileURL]]) {
        // file data
        DebugLog(@"paste files: %@", pasteboard.pasteboardItems);
        
        NSMutableArray *wrappers = [NSMutableArray new];
        for (NSPasteboardItem *item in pasteboard.pasteboardItems) {
            NSString *URLString = [item stringForType:(__bridge NSString *)kUTTypeFileURL];
            if (URLString) {
                NSURL *URL = [NSURL URLWithString:URLString];
                NSFileWrapper *wrapper = [[NSFileWrapper alloc] initWithURL:URL options:0 error:NULL];
                [wrappers addObject:wrapper];
            }
        }
        
        [self pasteWrappers:wrappers handle:handle];
    } else if ([pasteboard canReadItemWithDataConformingToTypes:@[NSPasteboardTypeRTFD]]) {
        // find out if the rich text contains files in it we need to upload
        NSData *data = [pasteboard dataForType:NSPasteboardTypeRTFD];
        NSAttributedString *attrStr = [[NSAttributedString alloc] initWithRTFD:data documentAttributes:nil];
        
        DebugLog(@"paste attrStr: %@", attrStr);
        
        // find all the attachments
        NSMutableArray *attachments = [NSMutableArray new];
        NSMutableArray *ranges = [NSMutableArray new];
        [attrStr enumerateAttribute:NSAttachmentAttributeName inRange:NSMakeRange(0, attrStr.length) options:0 usingBlock:^(id  _Nullable value, NSRange range, BOOL * _Nonnull stop) {
            if ([value isKindOfClass:[NSTextAttachment class]]) {
                NSFileWrapper *wrapper = [value fileWrapper];
                if (wrapper) {
                    [attachments addObject:wrapper];
                    [ranges addObject:[NSValue valueWithRange:range]];
                }
            }
        }];
        
        if (attachments.count == 0) {
            NSString *js = [NSString stringWithFormat:
                            @"pasteCallback(%@, 'pasteText', %@);\n"
                            @"pasteCallback(%@, 'completed');\n",
                            handle, [JSON stringifyObject:[attrStr string]],
                            handle];
            [self evaluateJavaScript:js];
        } else {
            NSMutableAttributedString *pasteStr = [attrStr mutableCopy];
            
            __block NSInteger pendingUploads = attachments.count;
            for (NSInteger i = pendingUploads; i > 0; i--) {
                NSRange range = [ranges[i-1] rangeValue];
                NSFileWrapper *attachment = attachments[i-1];
                
                NSString *placeholder = [self placeholderWithWrapper:attachment];
                [pasteStr replaceCharactersInRange:range withString:placeholder];
                
                [[AttachmentManager sharedManager] uploadAttachment:attachment completion:^(NSURL *destinationURL, NSError *error) {
                    NSString *js = nil;
                    
                    dispatch_assert_current_queue(dispatch_get_main_queue());
                    
                    if (error) {
                        js = [NSString stringWithFormat:@"pasteCallback(%@, 'uploadFailed', %@)", handle, [JSON stringifyObject:@{@"placeholder": placeholder, @"err": [error localizedDescription]}]];
                    } else {
                        NSString *link = [self linkWithWrapper:attachment URL:destinationURL];
                        js = [NSString stringWithFormat:@"pasteCallback(%@, 'uploadFinished', %@)", handle, [JSON stringifyObject:@{@"placeholder": placeholder, @"link": link}]];
                    }
                    
                    DebugLog(@"%@", js);
                    [self evaluateJavaScript:js];
                    
                    pendingUploads--;
                    
                    if (pendingUploads == 0) {
                        js = [NSString stringWithFormat:@"pasteCallback(%@, 'completed')", handle];
                        [self evaluateJavaScript:js];
                    }
                }];
            }
            
            NSString *js = [NSString stringWithFormat:
                            @"pasteCallback(%@, 'pasteText', %@);\n"
                            @"pasteCallback(%@, 'uploadsStarted', %tu);\n",
                            handle, [JSON stringifyObject:[pasteStr string]],
                            handle, attachments.count];
            DebugLog(@"%@", js);
            [self evaluateJavaScript:js];
        }
        
    } else if ([pasteboard canReadItemWithDataConformingToTypes:@[NSPasteboardTypeString]]) {
        // just plain text
        NSString *contents = [pasteboard stringForType:NSPasteboardTypeString];
        callback = [NSString stringWithFormat:@"pasteCallback(%@, 'pasteText', %@);", handle, [JSON stringifyObject:contents]];
        DebugLog(@"paste text: %@", callback);
        [self evaluateJavaScript:callback];
        
        callback = [NSString stringWithFormat:@"pasteCallback(%@, 'completed');", handle];
        DebugLog(@"%@", callback);
        [self evaluateJavaScript:callback];
    } else if ([pasteboard canReadItemWithDataConformingToTypes:@[(__bridge NSString *)kUTTypeGIF, NSPasteboardTypePNG, NSPasteboardTypePDF, NSPasteboardTypeTIFF]]) {
        // images
        DebugLog(@"paste images: %@", pasteboard.pasteboardItems);
        NSMutableArray *imageWrappers = [NSMutableArray new];
        for (NSPasteboardItem *item in pasteboard.pasteboardItems) {
            NSData *imgData = [item dataForType:(__bridge NSString *)kUTTypeGIF];
            NSString *ext = @"gif";
            if (!imgData) {
                imgData = [item dataForType:NSPasteboardTypePNG];
                ext = @"png";
            }
            if (!imgData) {
                imgData = [item dataForType:NSPasteboardTypePDF];
                ext = @"pdf";
            }
            if (!imgData) {
                imgData = [item dataForType:NSPasteboardTypeTIFF];
                ext = @"tiff";
            }
            
            if (imgData) {
                NSFileWrapper *wrapper = [[NSFileWrapper alloc] initRegularFileWithContents:imgData];
                
                NSString *filename = [NSString stringWithFormat:NSLocalizedString(@"Pasted Image %td.%@", nil), ++_pastedImageCount, ext];
                wrapper.preferredFilename = filename;
                
                [imageWrappers addObject:wrapper];
            }
        }
        
        [self pasteWrappers:imageWrappers handle:handle];
        
    } else {
        // can't read anything
        DebugLog(@"nothing readable in pasteboard: %@", pasteboard.pasteboardItems);
        callback = [NSString stringWithFormat:@"pasteCallback(%@, 'completed');", handle];
        [self evaluateJavaScript:callback];
    }
}

- (void)handleDocumentSaved:(NSDictionary *)msg {
    NSNumber *token = msg[@"token"];
    if (token) {
        SaveCompletion completion = _saveCompletions[token];
        if (completion) {
            [_saveCompletions removeObjectForKey:token];
            
            id err = msg[@"error"];
            NSError *error = nil;
            if (err && err != [NSNull null]) {
                error = [NSError shipErrorWithCode:ShipErrorCodeProblemSaveOtherError localizedMessage:err];
            }
            completion(error);
        }
    }
}

- (void)spellcheck:(NSDictionary *)msg {
    NSSpellChecker *checker = [NSSpellChecker sharedSpellChecker];
    if (_spellcheckDocumentTag == 0) {
        _spellcheckDocumentTag = [NSSpellChecker uniqueSpellDocumentTag];
    }
    
    if (msg[@"contextMenu"]) {
        _spellcheckContextTarget = msg[@"target"];
        return;
    }
    
    NSString *text = msg[@"text"];
    NSNumber *handle = msg[@"handle"];
    [checker requestCheckingOfString:text range:NSMakeRange(0, text.length) types:NSTextCheckingTypeSpelling options:nil inSpellDocumentWithTag:_spellcheckDocumentTag completionHandler:^(NSInteger sequenceNumber, NSArray<NSTextCheckingResult *> * _Nonnull results, NSOrthography * _Nonnull orthography, NSInteger wordCount) {
        
        // convert NSTextCheckingResults to {start:{line, ch}, end:{line, ch}} objects
        
        NSMutableArray *cmRanges = [NSMutableArray new];
        
        __block NSUInteger processed = 0;
        __block NSUInteger line = 0;
        
        [text enumerateSubstringsInRange:NSMakeRange(0, text.length) options:NSStringEnumerationByLines usingBlock:^(NSString * _Nullable substring, NSRange substringRange, NSRange enclosingRange, BOOL * _Nonnull stop) {
            
            for (NSUInteger i = processed; i < results.count; i++) {
                NSTextCheckingResult *result = results[i];
                NSRange r = result.range;
                if (NSRangeContainsRange(substringRange, r)) {
                    NSDictionary *cmRange = @{ @"start": @{ @"line" : @(line), @"ch" : @(r.location - substringRange.location) },
                                               @"end": @{ @"line": @(line), @"ch" : @(NSMaxRange(r) - substringRange.location) } };
                    [cmRanges addObject:cmRange];
                    processed++;
                } else if (NSMaxRange(substringRange) < NSMaxRange(r)) {
                    break;
                }
            }
            
            line++;
            *stop = processed == results.count;
            
        }];
        
        RunOnMain(^{
            NSString *callback = [NSString stringWithFormat:@"window.spellcheckResults({handle:%@, results:%@});", handle, [JSON stringifyObject:cmRanges]];
            [self evaluateJavaScript:callback];
        });
        
    }];
}

- (void)handleNewLabelWithName:(NSString *)name
                     allLabels:(NSArray *)allLabels
                         owner:(NSString *)owner
                          repo:(NSString *)repo
            completionCallback:(JSValue *)completionCallback {
    NewLabelController *newLabelController = [[NewLabelController alloc] initWithPrefilledName:(name ?: @"")
                                                                                     allLabels:allLabels
                                                                                         owner:owner
                                                                                          repo:repo];
    
    [self.view.window beginSheet:newLabelController.window completionHandler:^(NSModalResponse response){
        if (response == NSModalResponseOK) {
            NSAssert(newLabelController.createdLabel != nil, @"succeeded but created label was nil");
            [completionCallback callWithArguments:@[@YES, newLabelController.createdLabel]];
        } else {
            [completionCallback callWithArguments:@[@NO]];
        }
    }];
}

- (void)handleNewMilestoneWithName:(NSString *)name owner:(NSString *)owner repo:(NSString *)repoName completionCallback:(JSValue *)completionCallback
{
    Repo *repo = [[[[[DataStore activeStore] metadataStore] activeRepos] filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"fullName = %@", [NSString stringWithFormat:@"%@/%@", owner, repoName]] limit:1] firstObject];
    if (!repo) {
        [completionCallback callWithArguments:@[]];
        return;
    }
    
    NewMilestoneController *mc = [[NewMilestoneController alloc] initWithInitialRepos:@[repo] initialReposAreRequired:YES initialName:name];
    [mc beginInWindow:self.view.window completion:^(NSArray<Milestone *> *createdMilestones, NSError *error) {
        if (error) {
            [completionCallback callWithArguments:@[]];
        } else {
            id jsRepr = [JSON JSRepresentableValueFromSerializedObject:createdMilestones withNameTransformer:[JSON underbarsAndIDNameTransformer]];
            [completionCallback callWithArguments:@[jsRepr]];
        }
    }];
}

- (void)handleCommentFocus:(NSDictionary *)d {
    NSString *key = d[@"key"];
    BOOL state = [d[@"state"] boolValue];
    
    if (!state && (!_commentFocusKey || [_commentFocusKey isEqualToString:key])) {
        // blurred
        self.commentFocus = NO;
    } else if (state) {
        _commentFocusKey = [key copy];
        self.commentFocus = YES;
    }
}

#pragma mark -

- (IBAction)reload:(id)sender {
    if (_issue) {
        [[DataStore activeStore] checkForIssueUpdates:_issue.fullIdentifier];
    }
}

- (IBAction)revert:(id)sender {
    if (_issue) {
        self.issue = _issue;
    } else {
        [self configureNewIssue];
    }
}

- (IBAction)copyIssueNumber:(id)sender {
    [[_issue fullIdentifier] copyIssueIdentifierToPasteboard:[NSPasteboard generalPasteboard]];
}

- (IBAction)copyIssueNumberWithTitle:(id)sender {
    [[_issue fullIdentifier] copyIssueIdentifierToPasteboard:[NSPasteboard generalPasteboard] withTitle:_issue.title];
}

- (IBAction)copyIssueGitHubURL:(id)sender {
    [[_issue fullIdentifier] copyIssueGitHubURLToPasteboard:[NSPasteboard generalPasteboard]];
}

- (IBAction)toggleUpNext:(id)sender {
    [[UpNextHelper sharedHelper] addToUpNext:@[_issue.fullIdentifier] atHead:NO window:self.view.window completion:nil];
}

- (BOOL)validateMenuItem:(NSMenuItem *)menuItem {
    if (menuItem.action == @selector(saveDocument:)) {
        return [self needsSave];
    } else if (menuItem.action == @selector(fixSpelling:)) {
        return menuItem.representedObject != nil;
    } else if (menuItem.action == @selector(toggleUpNext:)) {
        menuItem.title = NSLocalizedString(@"Add to Up Next", nil);
    } else if ([NSStringFromSelector(menuItem.action) hasPrefix:@"md"]) {
        return YES; // return _commentFocus;
    } else if (menuItem.action == @selector(toggleCommentPreview:)) {
        return YES;
    }
    return _issue.fullIdentifier != nil;
}

- (IBAction)openDocumentInBrowser:(id)sender {
    NSURL *URL = [[_issue fullIdentifier] issueGitHubURL];
    [[NSWorkspace sharedWorkspace] openURL:URL];
}

- (BOOL)needsSave {
    JSValue *val = [_web.mainFrame.javaScriptContext evaluateScript:@"window.needsSave()"];
    return [val toBool];
}

- (IBAction)saveDocument:(id)sender {
    [self saveWithCompletion:nil];
}

- (void)saveWithCompletion:(void (^)(NSError *err))completion {
    static NSInteger token = 1;
    ++token;
    
    if (completion) {
        if (!_saveCompletions) {
            _saveCompletions = [NSMutableDictionary new];
        }
        _saveCompletions[@(token)] = [completion copy];
    }
    
    [_web.mainFrame.javaScriptContext evaluateScript:[NSString stringWithFormat:@"window.save(%td);", token]];
}

#pragma mark - Formatting Controls

- (void)applyFormat:(NSString *)format {
    [self evaluateJavaScript:[NSString stringWithFormat:@"applyMarkdownFormat(%@)", [JSON stringifyObject:format withNameTransformer:nil]]];
}

- (IBAction)mdBold:(id)sender {
    [self applyFormat:@"bold"];
}

- (IBAction)mdItalic:(id)sender {
    [self applyFormat:@"italic"];
}

- (IBAction)mdStrike:(id)sender {
    [self applyFormat:@"strike"];
}

- (IBAction)mdIncreaseHeading:(id)sender {
    [self applyFormat:@"headingMore"];
}

- (IBAction)mdDecreaseHeading:(id)sender {
    [self applyFormat:@"headingLess"];
}

- (IBAction)mdUnorderedList:(id)sender {
    [self applyFormat:@"insertUL"];
}

- (IBAction)mdOrderedList:(id)sender {
    [self applyFormat:@"insertOL"];
}

- (IBAction)mdTaskList:(id)sender {
    [self applyFormat:@"insertTaskList"];
}

- (IBAction)mdTable:(id)sender {
    [self applyFormat:@"insertTable"];
}

- (IBAction)mdHorizontalRule:(id)sender {
    [self applyFormat:@"insertHorizontalRule"];
}

- (IBAction)mdCodeBlock:(id)sender {
    [self applyFormat:@"code"];
}

- (IBAction)mdCodeFence:(id)sender {
    [self applyFormat:@"codefence"];
}

- (IBAction)mdHyperlink:(id)sender {
    [self applyFormat:@"hyperlink"];
}

- (IBAction)mdAttachFile:(id)sender {
    [self applyFormat:@"attach"];
}

- (IBAction)mdIncreaseQuote:(id)sender {
    [self applyFormat:@"quoteMore"];
}

- (IBAction)mdDecreaseQuote:(id)sender {
    [self applyFormat:@"quoteLess"];
}

- (IBAction)mdIndent:(id)sender {
    [self applyFormat:@"indentMore"];
}

- (IBAction)mdOutdent:(id)sender {
    [self applyFormat:@"indentLess"];
}

- (IBAction)mdTbText:(id)sender {
    NSInteger seg = [sender selectedSegment];
    switch (seg) {
        case 0: [self mdBold:nil]; break;
        case 1: [self mdItalic:nil]; break;
        case 2: [self mdStrike:nil]; break;
    }
}

- (IBAction)mdTbList:(id)sender {
    NSInteger seg = [sender selectedSegment];
    switch (seg) {
        case 0: [self mdUnorderedList:nil]; break;
        case 1: [self mdOrderedList:nil]; break;
        case 2: [self mdTaskList:nil]; break;
    }
}

- (IBAction)mdTbHeading:(id)sender {
    NSInteger seg = [sender selectedSegment];
    switch (seg) {
        case 0: [self mdIncreaseHeading:nil]; break;
        case 1: [self mdDecreaseHeading:nil]; break;
    }
}

- (IBAction)mdTbTableRule:(id)sender {
    NSInteger seg = [sender selectedSegment];
    switch (seg) {
        case 0: [self mdTable:nil]; break;
        case 1: [self mdHorizontalRule:nil]; break;
    }
}

- (IBAction)mdTbLink:(id)sender {
    [self mdAttachFile:nil];
}

- (IBAction)mdTbCode:(id)sender {
    NSInteger seg = [sender selectedSegment];
    switch (seg) {
        case 0: [self mdCodeBlock:nil]; break;
        case 1: [self mdCodeFence:nil]; break;
    }
}

- (IBAction)mdTbQuote:(id)sender {
    NSInteger seg = [sender selectedSegment];
    switch (seg) {
        case 0: [self mdIncreaseQuote:nil]; break;
        case 1: [self mdDecreaseQuote:nil]; break;
    }
}
                                                                                   
#pragma mark -

- (IBAction)toggleCommentPreview:(id)sender {
    [self evaluateJavaScript:@"toggleCommentPreview()"];
}

#pragma mark -

- (void)takeFocus {
    [self evaluateJavaScript:@"focusIssue()"];
}

@end

@implementation IssueWebView

- (BOOL)performKeyEquivalent:(NSEvent *)event {
    // realartists/shiphub-cocoa#272 Ctrl-Tab to go between tabs doesn’t work for IssueDocuments
    if ((event.modifierFlags & NSControlKeyMask) != 0 && [event isTabKey]) {
        return NO;
    }
    return [super performKeyEquivalent:event];
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    self.dragPasteboardName = [[sender draggingPasteboard] name];
    return [super performDragOperation:sender];
}

@end
