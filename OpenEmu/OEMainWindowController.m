/*
 Copyright (c) 2011, OpenEmu Team
 
 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are met:
 * Redistributions of source code must retain the above copyright
 notice, this list of conditions and the following disclaimer.
 * Redistributions in binary form must reproduce the above copyright
 notice, this list of conditions and the following disclaimer in the
 documentation and/or other materials provided with the distribution.
 * Neither the name of the OpenEmu Team nor the
 names of its contributors may be used to endorse or promote products
 derived from this software without specific prior written permission.
 
 THIS SOFTWARE IS PROVIDED BY OpenEmu Team ''AS IS'' AND ANY
 EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 DISCLAIMED. IN NO EVENT SHALL OpenEmu Team BE LIABLE FOR ANY
 DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#import "OEMainWindowController.h"

#import "OESetupAssistant.h"
#import "OECoreUpdater.h"
#import "OELibraryController.h"
#import "OELibraryDatabase.h"

#import "OEGameDocument.h"
@import OpenEmuKit;
#import "OEGameViewController.h"

#import "OEAlert+DefaultAlertsAdditions.h"
#import "OEDBGame.h"
#import "OEDBRom.h"

#import "OEROMImporter.h"

#import "NSDocument+OEAdditions.h"

#import "OpenEmu-Swift.h"

NSString *const OEForcePopoutGameWindowKey = @"forcePopout";
NSString *const OEPopoutGameWindowIntegerScalingOnlyKey = @"popoutGameWindowIntegerScalingOnly";
NSString *const OEFullScreenGameWindowKey  = @"fullScreen";

NSString *const OEMainWindowIdentifier     = @"LibraryWindow";
NSString *const OEDefaultWindowTitle       = @"OpenEmu";

#define MainMenu_Window_OpenEmuTag 501

@interface OEMainWindowController () <OELibraryControllerDelegate>
{
    OEGameDocument *_gameDocument;
    BOOL            _shouldExitFullScreenWhenGameFinishes;
    BOOL            _shouldUndockGameWindowOnFullScreenExit;
    BOOL            _resumePlayingAfterFullScreenTransition;
    
    BOOL _isLaunchingGame;
}

@end

@implementation OEMainWindowController

- (void)dealloc
{
    _currentContentController = nil;
    [self setDefaultContentController:nil];
    [self setLibraryController:nil];
    [self setPlaceholderView:nil];
}

- (id)initWithWindow:(NSWindow *)window
{
    if((self = [super initWithWindow:window]) == nil)
        return nil;
    
    // Since restoration from autosave happens before NSWindowController
    // receives -windowDidLoad and we are autosaving the window size, we
    // need to set allowWindowResizing to YES before -windowDidLoad
    _allowWindowResizing = YES;
    
    return self;
}


- (void)awakeFromNib
{
    [super awakeFromNib];
    
    [self setUpLibraryController];
    [self setUpWindow];
    [self setUpCurrentContentController];
    [self setUpViewMenuItemBindings];
    
    _isLaunchingGame = NO;
}

- (void)setUpLibraryController
{
    OELibraryController *libraryController = [self libraryController];
    
    [libraryController setDelegate:self];
    
    [libraryController view];
    [[self window] setToolbar:[libraryController toolbar]];
    self.window.toolbar.centeredItemIdentifier = @"OEToolbarItemIdentifierCategory";
}

- (void)setUpWindow
{
    NSWindow *window = self.window;
    
    window.delegate = self;
    
    window.excludedFromWindowsMenu = YES;
    window.titleVisibility = NSWindowTitleHidden;
    
    window.restorationClass = [self class];
    NSAssert([window.identifier isEqualToString:OEMainWindowIdentifier], @"Main library window identifier does not match between nib and code");
}

- (void)setUpCurrentContentController
{
    if(![[NSUserDefaults standardUserDefaults] boolForKey:OESetupAssistantHasFinishedKey])
    {
        NSWindow *window = self.window;
        
        OESetupAssistant *setupAssistant = [[OESetupAssistant alloc] init];
        [setupAssistant setCompletionBlock:^{
            [self setCurrentContentController:self.libraryController];
        }];
        
        // Adjust visual properties of the window.
        window.toolbar.visible = NO;
        
        [window center];
        
        [self setCurrentContentController:setupAssistant];
    }
    else
    {
        [self setCurrentContentController:self.libraryController];
    }
}

- (void)setUpViewMenuItemBindings
{
    NSMenu *viewMenu = [[[NSApp mainMenu] itemAtIndex:3] submenu];
    NSMenuItem *showLibraryNames = [viewMenu itemWithTag:10];
    NSMenuItem *showRomNames     = [viewMenu itemWithTag:11];
    NSMenuItem *undockGameWindow = [viewMenu itemWithTag:3];
    
    NSDictionary *negateOptions = @{NSValueTransformerNameBindingOption:NSNegateBooleanTransformerName};
    [showLibraryNames bind:@"enabled" toObject:self withKeyPath:@"mainWindowRunsGame" options:negateOptions];
    [showRomNames     bind:@"enabled" toObject:self withKeyPath:@"mainWindowRunsGame" options:negateOptions];
    [undockGameWindow bind:@"enabled" toObject:self withKeyPath:@"mainWindowRunsGame" options:@{}];
}

- (NSString *)windowNibName
{
    return @"MainWindow";
}

- (void)windowDidLoad
{
    NSLog(@"window did load");
    
    [super windowDidLoad];
    
    NSWindow *window = self.window;
    window.title = OEDefaultWindowTitle;
#if DEBUG_PRINT
    window.title = [window.title stringByAppendingString:@" (DEBUG BUILD)"];
#endif
}

#pragma mark -
// ugly hack, remove
- (void)startGame:(OEDBGame*)game
{
    [self OE_openGameDocumentWithGame:game saveState:[game autosaveForLastPlayedRom]];
}

#pragma mark -

- (void)setCurrentContentController:(NSViewController *)newController
{
    if(newController == nil) newController = self.libraryController;
    if(newController == self.currentContentController) return;
    
    NSView *placeHolderView = self.placeholderView;
    NSWindow *window = self.window;
    
    // We use Objective-C blocks to factor out common code used in both animated and non-animated controller switching
    void (^sendViewWillDisappear)(void) = ^{
        [self->_currentContentController viewWillDisappear];
        [newController viewWillAppear];
    };
    
    void (^replaceController)(NSView *) = ^(NSView *viewToReplace) {
        
        newController.view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        newController.view.frame = placeHolderView.bounds;
        
        if(viewToReplace)
            [placeHolderView replaceSubview:viewToReplace with:newController.view];
        else
            [placeHolderView addSubview:newController.view];
        
        [self.window makeFirstResponder:newController.view];
        
        [self->_currentContentController viewDidDisappear];
        [newController viewDidAppear];
        self->_currentContentController = newController;
        
        [viewToReplace removeFromSuperview];
        
        if(newController == self->_gameDocument.gameViewController)
        {
            // Adjust visual properties of the window.
            window.toolbar.visible = NO;
            window.titleVisibility = NSWindowTitleVisible;
            
            // Disable the full size content view window style mask attribute.
            NSRect windowFrame = window.frame;
            window.styleMask &= ~NSWindowStyleMaskFullSizeContentView;
            [window setFrame:windowFrame display:NO];
            
            self->_gameDocument.gameWindowController = self;
        }
        else
        {
            window.titleVisibility = NSWindowTitleHidden;
            
            if(newController == self.libraryController)
            {
                // Enable the full size content view window style mask attribute.
                NSRect windowFrame = window.frame;
                window.styleMask |= NSWindowStyleMaskFullSizeContentView;
                [window setFrame:windowFrame display:NO];
                
                // Adjust visual properties of the window.
                window.toolbar.visible = YES;
            }
        }
    };
    
    sendViewWillDisappear();
    replaceController(_currentContentController.view);
    
    // If a game is playing in the library window, unpause emulation immediately.
    if (newController == _gameDocument.gameViewController) {
        _gameDocument.emulationPaused = NO;
    }
}

- (IBAction)undockGameWindow:(id)sender
{
    _mainWindowRunsGame = NO;
    
    if(_shouldExitFullScreenWhenGameFinishes && [[self window] isFullScreen])
    {
        [[self window] toggleFullScreen:self];
        _shouldExitFullScreenWhenGameFinishes = NO;
        _shouldUndockGameWindowOnFullScreenExit = YES;
    }
    else
    {
        [_gameDocument setEmulationPaused:YES];
        [self setCurrentContentController:nil];
        [_gameDocument setGameWindowController:nil];
        
        [_gameDocument showInSeparateWindowInFullScreen:NO];
        _gameDocument = nil;
    }
}

#pragma mark - OELibraryControllerDelegate protocol conformance

- (void)OE_openGameDocumentWithGame:(OEDBGame *)game saveState:(OEDBSaveState *)state
{
    // make sure we don't launch a game multiple times :/
    if(_isLaunchingGame) return;
    _isLaunchingGame = YES;
    
    NSUserDefaults *standardDefaults = [NSUserDefaults standardUserDefaults];
    BOOL openInSeparateWindow = _mainWindowRunsGame || [standardDefaults boolForKey:OEForcePopoutGameWindowKey];
    BOOL fullScreen = [standardDefaults boolForKey:OEFullScreenGameWindowKey];
    
    _shouldExitFullScreenWhenGameFinishes = NO;
    void (^openDocument)(OEGameDocument *, NSError *) =
    ^(OEGameDocument *document, NSError *error)
    {
        self->_isLaunchingGame = NO;
        if(document == nil)
        {
            if([[error domain] isEqualToString:OEGameDocumentErrorDomain] && [error code] == OEFileDoesNotExistError && game)
            {
                [game setStatus:@(OEDBGameStatusAlert)];
                [game save];
                
                NSString *messageText = [NSString stringWithFormat:NSLocalizedString(@"The game '%@' could not be started because a rom file could not be found. Do you want to locate it?", @""), [game name]];
                if([[OEAlert alertWithMessageText:messageText
                                       defaultButton:NSLocalizedString(@"Locate…", @"")
                                     alternateButton:NSLocalizedString(@"Cancel", @"")] runModal] == NSAlertFirstButtonReturn)
                {
                    OEDBRom  *missingRom = [[game roms] anyObject];
                    NSURL   *originalURL = [missingRom URL];
                    NSString  *extension = [originalURL pathExtension];
                    
                    NSString *panelTitle = [NSString stringWithFormat:NSLocalizedString(@"Locate '%@'", @"Locate panel title"), [[originalURL pathComponents] lastObject]];
                    NSOpenPanel  *panel = [NSOpenPanel openPanel];
                    [panel setMessage:panelTitle];
                    [panel setCanChooseDirectories:NO];
                    [panel setCanChooseFiles:YES];
                    [panel setDirectoryURL:[originalURL URLByDeletingLastPathComponent]];
                    [panel setAllowsOtherFileTypes:NO];
                    [panel setAllowedFileTypes:@[extension]];
                    
                    if([panel runModal] == NSModalResponseOK)
                    {
                        [missingRom setURL:[panel URL]];
                        [missingRom save];
                        [self OE_openGameDocumentWithGame:game saveState:state];
                    }
                }
            }
            // FIXME: make it possible to locate missing rom files when the game is started from a savestate
            else if([[error domain] isEqualToString:OEGameDocumentErrorDomain] && [error code] == OEFileDoesNotExistError && !game)
            {
                NSString *messageText = NSLocalizedString(@"The game '%@' could not be started because a rom file could not be found. Do you want to locate it?", @"");
                
                NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"[\"'“„« ]+%@[\"'”“» ]+[ を]?" options:NSRegularExpressionCaseInsensitive error:NULL];
                messageText = [regex stringByReplacingMatchesInString:messageText options:0 range:NSMakeRange(0, messageText.length) withTemplate:@""];
                
                NSRange range = [messageText rangeOfString:@"."];
                if (range.location == NSNotFound)
                    range = [messageText rangeOfString:@"。"];
                if (range.location != NSNotFound)
                    messageText = [messageText substringToIndex:range.location+1];
                
                messageText = [messageText stringByAppendingString:NSLocalizedString(@" Start the game from the library view if you want to locate it.", @"")];
                
                [[OEAlert alertWithMessageText:messageText defaultButton:NSLocalizedString(@"OK", @"") alternateButton:nil] runModal];
            }
            else if(error) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self presentError:error];
                });
            }
            
            return;
        }
        else if ([[game status] intValue] == OEDBGameStatusAlert)
        {
            [game setStatus:@(OEDBGameStatusOK)];
            [game save];
        }
        
        if(openInSeparateWindow) return;
        
        self->_shouldExitFullScreenWhenGameFinishes = ![[self window] isFullScreen];
        self->_gameDocument = document;
        self->_mainWindowRunsGame = YES;
        
        while([[[self window] titlebarAccessoryViewControllers] count])
            [[self window] removeTitlebarAccessoryViewControllerAtIndex:0];
        [[[self window] toolbar] setVisible:NO];
        
        if(fullScreen && ![[self window] isFullScreen])
        {
            [NSApp activateIgnoringOtherApps:YES];
            
            [self setCurrentContentController:[document gameViewController]];
            [document setEmulationPaused:NO];
            [[self window] toggleFullScreen:self];
        }
        else
        {
            [document setGameWindowController:self];
            [self setCurrentContentController:[document gameViewController]];
        }
    };
    
    if(state != nil || ((state=[game autosaveForLastPlayedRom]) && [[OEAlert loadAutoSaveGameAlert] runModal] == NSAlertFirstButtonReturn))
        [[NSDocumentController sharedDocumentController] openGameDocumentWithSaveState:state display:openInSeparateWindow fullScreen:fullScreen completionHandler:openDocument];
    else
        [[NSDocumentController sharedDocumentController] openGameDocumentWithGame:game display:openInSeparateWindow fullScreen:fullScreen completionHandler:openDocument];
}

- (void)libraryController:(OELibraryController *)sender didSelectGame:(OEDBGame *)game
{
    [self OE_openGameDocumentWithGame:game saveState:nil];
}

- (void)libraryController:(OELibraryController *)sender didSelectSaveState:(OEDBSaveState *)saveState
{
    [self OE_openGameDocumentWithGame:nil saveState:saveState];
}

#pragma mark - NSWindow delegate

- (NSSize)windowWillResize:(NSWindow *)sender toSize:(NSSize)frameSize
{
    return [self allowWindowResizing] ? frameSize : [sender frame].size;
}

- (BOOL)windowShouldClose:(id)sender
{
    if([self currentContentController] == [self libraryController])
        return YES;
    else
    {
        [_gameDocument canCloseDocumentWithCompletionHandler:
         ^(NSDocument *document, BOOL shouldClose)
         {
             [self->_gameDocument setGameWindowController:nil];
             [self->_gameDocument close];
             self->_gameDocument = nil;
             self->_mainWindowRunsGame = NO;
             
             BOOL exitFullScreen = (self->_shouldExitFullScreenWhenGameFinishes && [[self window] isFullScreen]);
             if(exitFullScreen)
             {
                 [[[self window] toolbar] setVisible:YES];
                 [[self window] toggleFullScreen:self];
                 self->_shouldExitFullScreenWhenGameFinishes = NO;
             }
             
             [self setCurrentContentController:nil];
         }];
        
        return NO;
    }
}

- (void)windowWillClose:(NSNotification *)notification
{
    // Make sure the current content controller gets viewWillDisappear / viewDidAppear so it has a chance to store its state
    if([self currentContentController] == [self libraryController])
    {
        [[self libraryController] viewWillDisappear];
        [[self libraryController] viewDidDisappear];
        [[self libraryController] viewWillAppear];
        [[self libraryController] viewDidAppear];
    }
    
    [self setCurrentContentController:nil];
}

- (void)windowDidBecomeKey:(NSNotification *)notification
{
    [[self currentContentController] viewWillAppear];
    [[self currentContentController] viewDidAppear];
}

- (void)windowDidBecomeMain:(NSNotification *)notification
{
    NSMenu *mainMenu = [NSApp mainMenu];
    
    NSMenu *windowMenu = [[mainMenu itemAtIndex:5] submenu];
    NSMenuItem *item = [windowMenu itemWithTag:MainMenu_Window_OpenEmuTag];
    [item setState:NSControlStateValueOn];
}

- (void)windowDidResignMain:(NSNotification *)notification
{
    NSMenu *mainMenu = [NSApp mainMenu];
    
    NSMenu *windowMenu = [[mainMenu itemAtIndex:5] submenu];
    NSMenuItem *item = [windowMenu itemWithTag:MainMenu_Window_OpenEmuTag];
    [item setState:NSControlStateValueOff];
}

- (void)windowWillEnterFullScreen:(NSNotification *)notification
{
    if(_gameDocument && [_gameDocument gameWindowController] == self)
    {
        _resumePlayingAfterFullScreenTransition = ![_gameDocument isEmulationPaused];
        [_gameDocument setEmulationPaused:YES];
    }
}

- (void)windowDidEnterFullScreen:(NSNotification *)notification
{
    if(_gameDocument == nil) {
        return;
    }
    
    if(_shouldExitFullScreenWhenGameFinishes)
    {
        [_gameDocument setGameWindowController:self];
        [self setCurrentContentController:[_gameDocument gameViewController]];
    }
    
    if(_resumePlayingAfterFullScreenTransition)
        [_gameDocument setEmulationPaused:NO];
}

- (void)windowWillExitFullScreen:(NSNotification *)notification
{
    if(_gameDocument)
    {
        _resumePlayingAfterFullScreenTransition = ![_gameDocument isEmulationPaused];
        [_gameDocument setEmulationPaused:YES];
    }
}

- (void)windowDidExitFullScreen:(NSNotification *)notification
{
    if(_shouldUndockGameWindowOnFullScreenExit)
    {
        _shouldUndockGameWindowOnFullScreenExit = NO;
        
        [self setCurrentContentController:nil];
        
        [_gameDocument showInSeparateWindowInFullScreen:NO];
        
        if(_resumePlayingAfterFullScreenTransition)
            [_gameDocument setEmulationPaused:NO];
        
        _gameDocument = nil;
        _mainWindowRunsGame = NO;
    }
    else if(_gameDocument && _resumePlayingAfterFullScreenTransition)
        [_gameDocument setEmulationPaused:NO];
}

- (NSRect)window:(NSWindow *)window willPositionSheet:(NSWindow *)sheet usingRect:(NSRect)rect
{
    // Ge window title bar height.
    CGFloat contentHeight = [window contentRectForFrameRect:window.frame].size.height;
    CGFloat titleBarHeight = window.frame.size.height - contentHeight;
    
    // Re-position the sheet beneath the title bar.
    const CGFloat sheetOffset = titleBarHeight;
    rect.origin.y -= sheetOffset;
    return rect;
}

#pragma mark - Window Restoration

+ (void)restoreWindowWithIdentifier:(NSString *)identifier state:(NSCoder *)state completionHandler:(void (^)(NSWindow * __nullable, NSError * __nullable))completionHandler
{
    if ([identifier isEqualToString:OEMainWindowIdentifier]) {
        OEApplicationDelegate *appDelegate = (OEApplicationDelegate *)[NSApp delegate];
        
        if (appDelegate) {
            [NSApp extendStateRestoration];
            appDelegate.restoreWindow = YES;
            
            NSNotificationCenter *notificationCenter = [NSNotificationCenter defaultCenter];
            NSOperationQueue *mainQueue = [NSOperationQueue mainQueue];
            void (^completionHandlerCopy)(NSWindow * __nullable, NSError * __nullable) = [completionHandler copy];
            
            id observerOfLibraryDidLoad = [notificationCenter addObserverForName:OELibraryDidLoadNotificationName object:nil queue:mainQueue usingBlock:^(NSNotification * _Nonnull note) {
                OEMainWindowController *mainWindowController = [[self alloc]  initWithWindowNibName:@"MainWindow"];
                appDelegate.mainWindowController = mainWindowController;
                NSWindow *mainWindow = [mainWindowController window];
                
                completionHandlerCopy(mainWindow, nil);
                
                [NSApp completeStateRestoration];
            }];
            
            appDelegate.libraryDidLoadObserverForRestoreWindow = observerOfLibraryDidLoad;
            return;
        }
    }
    completionHandler(nil, nil);
}

#pragma mark - Menu Items

- (IBAction)launchLastPlayedROM:(id)sender
{
    OEDBGame *game = [[sender representedObject] game];
    
    [self libraryController:nil didSelectGame:game];
}

@end
