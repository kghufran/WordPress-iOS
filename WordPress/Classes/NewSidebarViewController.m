//
//  NewSidebarMenuViewController.m
//  WordPress
//
//  Created by Sendhil Panchadsaram on 8/12/13.
//  Copyright (c) 2013 WordPress. All rights reserved.
//

#import "NewSidebarViewController.h"
#import "SidebarTopLevelView.h"
#import "NewSidebarCell.h"
#import "PostsViewController.h"
#import "WordPressAppDelegate.h"
#import "SettingsViewController.h"
#import "ReaderPostsViewController.h"
#import "NotificationsViewController.h"
#import "PagesViewController.h"
#import "CommentsViewController.h"
#import "StatsWebViewController.h"
#import "WPWebViewController.h"
#import "SoundUtil.h"
#import "WordPressComApi.h"
#import "WPAccount.h"
#import "QuickPhotoViewController.h"
#import "GeneralWalkthroughViewController.h"
#import "ThemeBrowserViewController.h"
#import "WPStyleGuide.h"

@interface NewSidebarViewController () <UITableViewDataSource, UITableViewDelegate, NSFetchedResultsControllerDelegate, UIActionSheetDelegate> {
    Blog *_currentlyOpenedBlog;
    NSIndexPath *_currentIndexPath;
    NSUInteger _unseenNotificationCount;
    BOOL _showingWelcomeScreen;
    BOOL _selectionRestored;
    UIActionSheet *_quickPhotoActionSheet;
    NSInteger _wantedSection;
    BOOL _changingContentForSelectedSection;
}

@property (nonatomic, strong) IBOutlet UITableView *tableView;
@property (nonatomic, strong) NSFetchedResultsController *resultsController;
@property (nonatomic, strong) Post *currentQuickPost;

@end

@implementation NewSidebarViewController

CGFloat const SidebarViewControllerNumberOfRowsForBlog = 6;

- (id)initWithNibName:(NSString *)nibNameOrNil bundle:(NSBundle *)nibBundleOrNil
{
    self = [super initWithNibName:nibNameOrNil bundle:nibBundleOrNil];
    if (self) {
    }
    return self;
}

- (void)dealloc
{
    self.resultsController.delegate = nil;
    [[NSNotificationCenter defaultCenter] removeObserver:self];

}

- (void)viewDidLoad
{
    [super viewDidLoad];
    
    self.view.backgroundColor = [WPStyleGuide darkAsNightGrey];
    self.tableView.backgroundColor = [WPStyleGuide darkAsNightGrey];
    
    UIView *footerView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, CGRectGetWidth(self.view.bounds), 100)];
    footerView.backgroundColor = [UIColor clearColor];
    self.tableView.tableFooterView = footerView;
    
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    
    [self registerForWordPressDotComAccountChangingNotification];
    [self registerForNewNotificationsNotifications];
}

- (void)registerForCommentUpdateNotifications
{
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(receivedCommentsChangedNotification)
                                                 name:kCommentsChangedNotificationName
                                               object:nil];
}

- (NSIndexPath *)postsIndexPathForCurrentlySelectedBlog
{
    if (_currentlyOpenedBlog == nil || [[self.resultsController fetchedObjects] count] == 0)
        return nil;

    __block BOOL blogFound;
    __block NSUInteger blogIndex;
    [[self.resultsController fetchedObjects] enumerateObjectsUsingBlock:^(Blog *blog, NSUInteger idx, BOOL *stop){
        if ([blog isEqual:_currentlyOpenedBlog]) {
            blogFound = YES;
            blogIndex = idx;
            *stop = YES;
        }
    }];
    
    if (blogFound) {
        return [NSIndexPath indexPathForRow:0 inSection:blogIndex];
    } else {
        return nil;
    }
}

- (void)receivedCommentsChangedNotification
{
    NSIndexPath *postsIndexPathForCurrentlyOpenedBlog = [self postsIndexPathForCurrentlySelectedBlog];
    if (postsIndexPathForCurrentlyOpenedBlog == nil)
        return;
    
    NSIndexPath *indexPath = [self indexPathForComments:postsIndexPathForCurrentlyOpenedBlog.section];
    if ([self isIndexPathValid:indexPath]) {
        [self.tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
        // Reloading the row above results in the cell being deselected
        [self.tableView selectRowAtIndexPath:_currentIndexPath animated:NO scrollPosition:UITableViewScrollPositionNone];
    }
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self presentContent];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    
    if (IS_IPHONE && _showingWelcomeScreen) {
        _showingWelcomeScreen = NO;
        static dispatch_once_t sidebarTeaseToken;
        dispatch_once(&sidebarTeaseToken, ^{
            [self.panelNavigationController teaseSidebar];
        });
    }

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        [self restorePreservedSelection];
        [self presentContent];
    });
}

- (NSFetchedResultsController *)resultsController {
    if (_resultsController != nil) return _resultsController;
    
    NSManagedObjectContext *moc = [[WordPressAppDelegate sharedWordPressApplicationDelegate] managedObjectContext];
    
    NSFetchRequest *fetchRequest = [[NSFetchRequest alloc] init];
    [fetchRequest setEntity:[NSEntityDescription entityForName:@"Blog" inManagedObjectContext:moc]];
    [fetchRequest setPropertiesToFetch:@[@"blogName", @"xmlrpc", @"url"]];
    NSSortDescriptor *sortDescriptor = [[NSSortDescriptor alloc] initWithKey:@"blogName" ascending:YES];
    NSArray *sortDescriptors = [[NSArray alloc] initWithObjects:sortDescriptor, nil];
    [fetchRequest setSortDescriptors:sortDescriptors];
    
    // For some reasons, the cache sometimes gets corrupted
    // Since we don't really use sections we skip the cache here
    _resultsController = [[NSFetchedResultsController alloc]
                          initWithFetchRequest:fetchRequest
                          managedObjectContext:moc
                          sectionNameKeyPath:nil
                          cacheName:nil];
    _resultsController.delegate = self;
    
    NSError *error = nil;
    if (![_resultsController performFetch:&error]) {
        WPFLog(@"Couldn't fecth blogs: %@", [error localizedDescription]);
        _resultsController = nil;
    }
    
    return _resultsController;
}


#pragma mark - Table view data source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return [[self.resultsController fetchedObjects] count] + 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    // Return the number of rows in the section.
    if ([self isLastSection:section]) {
        if ([self areReaderAndNotificationsEnabled]) {
            return 3;
        } else {
            if ([self noBlogs]) {
                return 0;
            } else {
                return 1; // Settings
            }
        }
    }
    else {
        Blog *blog = [[self.resultsController fetchedObjects] objectAtIndex:section];
        if ([blog isEqual:_currentlyOpenedBlog]) {
            return [self shouldShowThemesOption] ? SidebarViewControllerNumberOfRowsForBlog : SidebarViewControllerNumberOfRowsForBlog - 1;
        } else {
            return 0;
        }
    }
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section
{
    if ([self isLastSection:section])
        return 0.0;
    else
        return 44.0;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section
{
    if ([self isLastSection:section]) {
        return nil;
    }
    
    SidebarTopLevelView *headerView = [[SidebarTopLevelView alloc] initWithFrame:CGRectMake(0, 0, CGRectGetWidth(self.tableView.frame), 44)];
    Blog *blog = [[self.resultsController fetchedObjects] objectAtIndex:section];
    headerView.blogTitle = blog.blogName;
    headerView.blavatarUrl = blog.blavatarUrl;
    headerView.onTap = ^{
        [self toggleSection:[self sectionForBlog:blog]];
    };
    if ([blog isEqual:_currentlyOpenedBlog]) {
        headerView.selected = true;
    }
    return headerView;
}

- (void)toggleSection:(NSUInteger)section
{
    [self toggleSection:section forRow:0];
}

- (void)closeCurrentlyOpenedSection
{
    if (_currentlyOpenedBlog == nil)
        return;

    Blog *oldOpenedBlog = _currentlyOpenedBlog;
    _currentlyOpenedBlog = nil;
    [self.tableView beginUpdates];
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:[self sectionForBlog:oldOpenedBlog]] withRowAnimation:UITableViewRowAnimationAutomatic];
    [self.tableView endUpdates];
}

- (void)toggleSection:(NSUInteger)section forRow:(NSInteger)row
{
    Blog *oldOpenedBlog = _currentlyOpenedBlog;
    Blog *blogForSection = [[self.resultsController fetchedObjects] objectAtIndex:section];
    if ([blogForSection isEqual:oldOpenedBlog]) {
        // Collapse Currently Opened Section
        _currentlyOpenedBlog = nil;
        [self.tableView beginUpdates];
        [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:[self sectionForBlog:oldOpenedBlog]] withRowAnimation:UITableViewRowAnimationAutomatic];
        [self.tableView endUpdates];
    } else {
        // Collapse Old Section and Expand New Section
        _currentlyOpenedBlog = blogForSection;
        [self.tableView beginUpdates];
        if (oldOpenedBlog != nil) {
            [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:[self sectionForBlog:oldOpenedBlog]] withRowAnimation:UITableViewRowAnimationAutomatic];
        }
        [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:[self sectionForBlog:_currentlyOpenedBlog]] withRowAnimation:UITableViewRowAnimationAutomatic];
        [self.tableView endUpdates];
        
        [self.tableView selectRowAtIndexPath:[NSIndexPath indexPathForRow:row inSection:section] animated:YES scrollPosition:UITableViewScrollPositionNone];
        [self processRowSelectionAtIndexPath:[NSIndexPath indexPathForRow:row inSection:section] closingSidebar:NO];
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if ([self isLastSection:indexPath.section]) {
        static NSString *CellIdentifier = @"OtherCell";
        NewSidebarCell *cell = [tableView dequeueReusableCellWithIdentifier:CellIdentifier];
        if (cell == nil) {
            cell = [[NewSidebarCell alloc] init];
        }
        
        NSString *text;
        UIImage *image;
        UIImage *selectedImage;
        if ([self isRowForReader:indexPath]) {
            text = NSLocalizedString(@"Reader", nil);
            image = [UIImage imageNamed:@"icon-menu-reader"];
            selectedImage = [UIImage imageNamed:@"icon-menu-reader-active"];
        } else if ([self isRowForNotifications:indexPath]) {
            text = NSLocalizedString(@"Notifications", nil);
            image = [UIImage imageNamed:@"icon-menu-notifications"];
            selectedImage = [UIImage imageNamed:@"icon-menu-notifications-active"];
            if (_unseenNotificationCount > 0) {
                cell.showsBadge = YES;
                cell.badgeNumber = _unseenNotificationCount;
            }
        } else if ([self isRowForSettings:indexPath]) {
            text = NSLocalizedString(@"Settings", nil);
            image = [UIImage imageNamed:@"icon-menu-settings"];
            selectedImage = [UIImage imageNamed:@"icon-menu-settings-active"];
        }
        
        cell.cellBackgroundColor = SidebarTableViewCellBackgroundColorDark;
        cell.title = text;
        cell.mainImage = image;
        cell.selectedImage = selectedImage;
        
        return cell;
    } else {
        static NSString *CellIdentifier = @"Cell";
        NewSidebarCell *cell = [tableView dequeueReusableCellWithIdentifier:CellIdentifier];
        if (cell == nil) {
            cell = [[NewSidebarCell alloc] init];
        }
        
        cell.showsBadge = false;
        cell.firstAccessoryViewImage = nil;
        cell.secondAccessoryViewImage = nil;
        
        NSString *text;
        UIImage *image;
        UIImage *selectedImage;
        if ([self isRowForPosts:indexPath]) {
            text = NSLocalizedString(@"Posts", nil);
            image = [UIImage imageNamed:@"icon-menu-posts"];
            selectedImage = [UIImage imageNamed:@"icon-menu-posts-active"];
            cell.firstAccessoryViewImage = [UIImage imageNamed:@"icon-menu-posts-quickphoto"];
            __weak UITableViewCell *weakCell = cell;
            cell.tappedFirstAccessoryView = ^{
                [self showQuickPhotoForFrame:weakCell.frame];
            };
            cell.secondAccessoryViewImage = [UIImage imageNamed:@"icon-menu-posts-add"];
            cell.tappedSecondAccessoryView = ^{
                [self quickAddNewPost:indexPath];
            };
        } else if ([self isRowForPages:indexPath]) {
            text = NSLocalizedString(@"Pages", nil);
            image = [UIImage imageNamed:@"icon-menu-pages"];
            selectedImage = [UIImage imageNamed:@"icon-menu-pages-active"];
            cell.secondAccessoryViewImage = [UIImage imageNamed:@"icon-menu-posts-add"];
            cell.tappedSecondAccessoryView = ^{
                [self quickAddNewPost:indexPath];
            };
        } else if ([self isRowForComments:indexPath]) {
            text = NSLocalizedString(@"Comments", nil);
            image = [UIImage imageNamed:@"icon-menu-comments"];
            selectedImage = [UIImage imageNamed:@"icon-menu-comments-active"];
            Blog *blog = [[self.resultsController fetchedObjects] objectAtIndex:indexPath.section];
            int numberOfPendingComments = [blog numberOfPendingComments];
            if (numberOfPendingComments > 0) {
                cell.showsBadge = true;
                cell.badgeNumber = numberOfPendingComments;
            }
        } else if ([self isRowForStats:indexPath]) {
            text = NSLocalizedString(@"Stats", nil);
            image = [UIImage imageNamed:@"icon-menu-stats"];
            selectedImage = [UIImage imageNamed:@"icon-menu-stats-active"];
        } else if ([self isRowForViewSite:indexPath]) {
            text = NSLocalizedString(@"View Site", nil);
            image = [UIImage imageNamed:@"icon-menu-viewsite"];
            selectedImage = [UIImage imageNamed:@"icon-menu-viewsite-active"];
        } else if ([self isRowForThemes:indexPath]) {
            text = NSLocalizedString(@"Themes", @"Menu item for themes");
            image = [UIImage imageNamed:@"icon-menu-themes"];
            selectedImage = [UIImage imageNamed:@"icon-menu-themes-active"];
        }
        
        cell.cellBackgroundColor = SidebarTableViewCellBackgroundColorLight;
        cell.title = text;
        cell.mainImage = image;
        cell.selectedImage = selectedImage;
        
        return cell;
    }
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [self processRowSelectionAtIndexPath:indexPath];
}

- (BOOL)isLastSection:(NSUInteger)section
{
    return (section == [[self.resultsController fetchedObjects] count]);
}

# pragma mark - Private Methods

- (void)processRowSelectionAtIndexPath:(NSIndexPath *)indexPath
{
    [self processRowSelectionAtIndexPath:indexPath closingSidebar:YES];
}

- (void)processRowSelectionAtIndexPath:(NSIndexPath *)indexPath closingSidebar:(BOOL)closingSidebar
{
    if ([_currentIndexPath compare:indexPath] == NSOrderedSame && closingSidebar) {
        [self.panelNavigationController closeSidebar];
    }
    
    if (![self isIndexPathForSettings:indexPath]) {
        _currentIndexPath = indexPath;
    }
    
    [self saveCurrentlySelectedItemForRestoration:indexPath];
    
    UIViewController *detailViewController;
    if ([self isIndexPathSectionForReaderAndNotifications:indexPath]) {
        if ([self isRowForSettings:indexPath]) {
            [self.panelNavigationController closeSidebar];
            [self showSettings];
            if (_currentIndexPath != nil) {
                [self.tableView selectRowAtIndexPath:_currentIndexPath animated:NO scrollPosition:UITableViewScrollPositionNone];
            }
            return;
        } else if ([self isRowForReader:indexPath]) {
            [WPMobileStats incrementProperty:StatsPropertySidebarClickedReader forEvent:StatsEventAppClosed];
			ReaderPostsViewController *readerViewController = [[ReaderPostsViewController alloc] init];
            detailViewController = readerViewController;
            [self closeCurrentlyOpenedSection];
        } else if ([self isRowForNotifications:indexPath]) {
            [WPMobileStats incrementProperty:StatsPropertySidebarClickedNotifications forEvent:StatsEventAppClosed];
            _unseenNotificationCount = 0;
            NotificationsViewController *notificationsViewController = [[NotificationsViewController alloc] init];
            detailViewController = notificationsViewController;
            [self closeCurrentlyOpenedSection];
        }
    } else {
        Blog *blog = [self.resultsController objectAtIndexPath:[NSIndexPath indexPathForRow:indexPath.section inSection:0]];
        
        Class controllerClass = nil;
        if ([self isRowForPosts:indexPath]) {
            [WPMobileStats incrementProperty:StatsPropertySidebarSiteClickedPosts forEvent:StatsEventAppClosed];
            
            controllerClass = [PostsViewController class];
        } else if ([self isRowForPages:indexPath]) {
            [WPMobileStats incrementProperty:StatsPropertySidebarSiteClickedPages forEvent:StatsEventAppClosed];
            
            controllerClass = [PagesViewController class];
        } else if ([self isRowForComments:indexPath]) {
            [WPMobileStats incrementProperty:StatsPropertySidebarSiteClickedComments forEvent:StatsEventAppClosed];
            
            controllerClass = [CommentsViewController class];
        } else if ([self isRowForStats:indexPath]) {
            [WPMobileStats incrementProperty:StatsPropertySidebarSiteClickedStats forEvent:StatsEventAppClosed];
            
            controllerClass =  [StatsWebViewController class];
        } else if ([self isRowForThemes:indexPath]) {
            [WPMobileStats incrementProperty:StatsPropertySidebarSiteClickedThemes forEvent:StatsEventAppClosed];
            
            controllerClass = [ThemeBrowserViewController class];
        } else if ([self isRowForViewSite:indexPath]) {
            [self showViewSiteForBlog:blog andClosingSidebar:closingSidebar];
        } else {
            controllerClass = [PostsViewController class];
        }
        
        [[NSNotificationCenter defaultCenter] postNotificationName:kSelectedBlogChanged
                                                            object:nil
                                                          userInfo:[NSDictionary dictionaryWithObject:blog forKey:@"blog"]];
        
        //Check if the controller is already on the screen
        if ([self.panelNavigationController.detailViewController isMemberOfClass:controllerClass] && [self.panelNavigationController.detailViewController respondsToSelector:@selector(setBlog:)]) {
            [self.panelNavigationController.detailViewController performSelector:@selector(setBlog:) withObject:blog];
            if (IS_IPAD) {
                [self.panelNavigationController showSidebar];
            } else {
                if (closingSidebar)
                    [self.panelNavigationController closeSidebar];
            }
            [self.panelNavigationController popToRootViewControllerAnimated:NO];
            
            return;
        } else {
            detailViewController = (UIViewController *)[[controllerClass alloc] init];
            if ([detailViewController respondsToSelector:@selector(setBlog:)]) {
                [detailViewController performSelector:@selector(setBlog:) withObject:blog];
            }
        }
    }
    
    if (detailViewController) {
        [self.panelNavigationController setDetailViewController:detailViewController closingSidebar:closingSidebar];
    }
}

- (void)saveCurrentlySelectedItemForRestoration:(NSIndexPath *)indexPath
{
    NSDictionary *dict = [NSDictionary dictionaryWithObjectsAndKeys:[NSNumber numberWithInteger:indexPath.row], @"row", [NSNumber numberWithInteger:indexPath.section], @"section", nil];
    [[NSUserDefaults standardUserDefaults] setObject:dict forKey:@"kSelectedSidebarIndexDictionary"];
    [NSUserDefaults resetStandardUserDefaults];
}

- (BOOL)areReaderAndNotificationsEnabled
{
    return [WPAccount defaultWordPressComAccount] != nil;
}

- (NSIndexPath *)indexPathForNotifications
{
    NSInteger section = [[self.resultsController fetchedObjects] count];
    return [NSIndexPath indexPathForRow:1 inSection:section];
}

- (NSIndexPath *)indexPathForReader
{
    NSInteger section = [[self.resultsController fetchedObjects] count];
    return [NSIndexPath indexPathForRow:0 inSection:section];
}

- (BOOL)isIndexPathSectionForReaderAndNotifications:(NSIndexPath *)indexPath
{
    return [self isLastSection:indexPath.section];
}

- (BOOL)isRowForSettings:(NSIndexPath *)indexPath
{
    return indexPath.row == ([WPAccount defaultWordPressComAccount] == nil ? 0 : 2);
}

- (BOOL)isRowForReader:(NSIndexPath *)indexPath
{
    return indexPath.row == ([WPAccount defaultWordPressComAccount] == nil ? 2 : 0);
}

- (BOOL)isRowForNotifications:(NSIndexPath *)indexPath
{
    return indexPath.row == 1;
}

- (BOOL)isRowForPosts:(NSIndexPath *)indexPath
{
    return indexPath.row == 0;
}

- (BOOL)isRowForPages:(NSIndexPath *)indexPath
{
    return indexPath.row == 1;
}

- (NSIndexPath *)indexPathForComments:(NSInteger)section
{
    return [NSIndexPath indexPathForRow:2 inSection:section];
}

- (BOOL)isRowForComments:(NSIndexPath *)indexPath
{
    return indexPath.row == 2;
}

- (BOOL)isRowForStats:(NSIndexPath *)indexPath
{
    return indexPath.row == 3;
}

- (BOOL)isRowForViewSite:(NSIndexPath *)indexPath
{
    return indexPath.row == 4;
}

- (BOOL)isRowForThemes:(NSIndexPath *)indexPath
{
    return indexPath.row == 5;
}

- (void)showSettings
{
    [WPMobileStats incrementProperty:StatsPropertySidebarClickedSettings forEvent:StatsEventAppClosed];
    
    SettingsViewController *settingsViewController = [[SettingsViewController alloc] initWithStyle:UITableViewStyleGrouped];
    UINavigationController *aNavigationController = [[UINavigationController alloc] initWithRootViewController:settingsViewController];
    aNavigationController.navigationBar.translucent = NO;
    if (IS_IPAD)
        aNavigationController.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    aNavigationController.modalPresentationStyle = UIModalPresentationFormSheet;
    
    [self.panelNavigationController presentViewController:aNavigationController animated:YES completion:nil];
}

- (void)showViewSiteForBlog:(Blog *)blog andClosingSidebar:(BOOL)closingSidebar
{
    [WPMobileStats incrementProperty:StatsPropertySidebarSiteClickedViewSite forEvent:StatsEventAppClosed];
    
    NSString *blogURL = blog.url;
    if (![blogURL hasPrefix:@"http"]) {
        blogURL = [NSString stringWithFormat:@"http://%@", blogURL];
    } else if ([blog isWPcom] && [blog.url rangeOfString:@"wordpress.com"].location == NSNotFound) {
        blogURL = [blog.xmlrpc stringByReplacingOccurrencesOfString:@"xmlrpc.php" withString:@""];
    }
    
    //check if the same site already loaded
    if ([self.panelNavigationController.detailViewController isMemberOfClass:[WPWebViewController class]]
        &&
        [((WPWebViewController*)self.panelNavigationController.detailViewController).url.absoluteString isEqual:blogURL]
        ) {
        if (IS_IPAD) {
            [self.panelNavigationController showSidebar];
        } else {
            [self.panelNavigationController popToRootViewControllerAnimated:NO];
            [self.panelNavigationController closeSidebar];
        }
    } else {
        WPWebViewController *webViewController = [[WPWebViewController alloc] init];
        [webViewController setUrl:[NSURL URLWithString:blogURL]];
        if( [blog isPrivate] ) {
            [webViewController setUsername:blog.username];
            [webViewController setPassword:blog.password];
            [webViewController setWpLoginURL:[NSURL URLWithString:blog.loginUrl]];
        }
        [self.panelNavigationController setDetailViewController:webViewController closingSidebar:closingSidebar];
    }
    if (IS_IPAD) {
        [SoundUtil playSwipeSound];
    }
    return;
}

- (void)restorePreservedSelection
{
    NSDictionary *dict = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"kSelectedSidebarIndexDictionary"];
    if (!dict) {
        return [self selectFirstAvailableItem];
    }

    NSIndexPath *preservedIndexPath = [NSIndexPath indexPathForRow:[[dict objectForKey:@"row"] integerValue] inSection:[[dict objectForKey:@"section"] integerValue]];
    
    if ([self isIndexPathInvalid:preservedIndexPath]) {
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"kSelectedSidebarIndexDictionary"];
        [self selectFirstAvailableItem];
        return;
    }
    
    if ([self isIndexPathForBlog:preservedIndexPath]) {
        [self toggleSection:preservedIndexPath.section forRow:preservedIndexPath.row];
    } else {
        [self processRowSelectionAtIndexPath:preservedIndexPath closingSidebar:NO];
        [self.tableView selectRowAtIndexPath:preservedIndexPath animated:NO scrollPosition:UITableViewScrollPositionNone];
    }
}

- (BOOL)isIndexPathValid:(NSIndexPath *)indexPath
{
    return ![self isIndexPathInvalid:indexPath];
}

- (BOOL)isIndexPathInvalid:(NSIndexPath *)indexPath
{
    NSInteger numSections = [self numberOfSectionsInTableView:self.tableView];
    NSInteger numRows;
    if ([self isIndexPathForBlog:indexPath]) {
        numRows = SidebarViewControllerNumberOfRowsForBlog;
    } else {
        numRows = [self.tableView numberOfRowsInSection:indexPath.section];
    }
    
    BOOL sectionOutOfBounds = indexPath.section >= numSections;
    BOOL rowOutOfBounds = indexPath.row >= numRows;
    
    return sectionOutOfBounds || rowOutOfBounds || [self isIndexPathForSettings:indexPath];
}

- (BOOL)isIndexPathForSettings:(NSIndexPath *)indexPath
{
    return [self isLastSection:indexPath.section] && [self isRowForSettings:indexPath];
}

- (BOOL)isIndexPathForBlog:(NSIndexPath *)indexPath
{
    BOOL atLeastOneBlog = [[self.resultsController fetchedObjects] count] > 0;
    return atLeastOneBlog && ![self isLastSection:indexPath.section];
}

- (NSUInteger)sectionForBlog:(Blog *)blog
{
    NSParameterAssert(blog != nil);
    return [[self.resultsController fetchedObjects] indexOfObject:blog];
}

- (BOOL)noBlogs
{
    return [[self.resultsController fetchedObjects] count] == 0;
}

- (BOOL)noBlogsOrWordPressDotComAccount
{
    return [self noBlogs] || ([WPAccount defaultWordPressComAccount] == nil);
}

- (BOOL)noBlogsAndNoWordPressDotComAccount
{
    return [[self.resultsController fetchedObjects] count] == 0 && ![WPAccount defaultWordPressComAccount];
}

- (void)selectFirstAvailableItem {
    if ([self.tableView indexPathForSelectedRow] != nil) {
        return;
    }
    
    if ([self.tableView numberOfRowsInSection:0] > 0) {
        NSIndexPath *indexPath;
        if ([self isLastSection:0]) {
            // There should always be a reader here because we can't have a last section without reader/notifications
            // if the user is in a logged in state.
            indexPath = [self indexPathForReader];
        } else {
            indexPath = [NSIndexPath indexPathForRow:0 inSection:0];
        }
        [self processRowSelectionAtIndexPath:indexPath];
        [self.tableView selectRowAtIndexPath:indexPath animated:NO scrollPosition:UITableViewScrollPositionNone];
    } else {
        [self selectFirstAvailableBlog];
    }
    
    [self checkNothingToShow];
}

- (void)checkNothingToShow
{
    if ([self noBlogsAndNoWordPressDotComAccount]) {
        [self.panelNavigationController clearDetailViewController];
    }
}

- (BOOL)shouldShowThemesOption {
    if (_currentlyOpenedBlog) {
        WPAccount *currentAccount = [WPAccount defaultWordPressComAccount];
        if (_currentlyOpenedBlog.isWPcom) {
            return [_currentlyOpenedBlog.isAdmin isEqualToNumber:@(1)] && [currentAccount.username isEqualToString:_currentlyOpenedBlog.username];
        }
    }
    return NO;
}

- (void)showWelcomeScreenIfNeeded {
    if ([self noBlogsAndNoWordPressDotComAccount]) {
        _showingWelcomeScreen = YES;
        
        GeneralWalkthroughViewController *welcomeViewController = [[GeneralWalkthroughViewController alloc] init];
        
        UINavigationController *aNavigationController = [[UINavigationController alloc] initWithRootViewController:welcomeViewController];
        aNavigationController.navigationBar.translucent = NO;
        aNavigationController.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
        aNavigationController.modalPresentationStyle = UIModalPresentationFormSheet;
        
        [self.panelNavigationController presentViewController:aNavigationController animated:YES completion:nil];
        [self checkNothingToShow];
    }
}

- (void)presentContent
{
    [self showWelcomeScreenIfNeeded];
}

- (void)showReader
{
    NSAssert([self areReaderAndNotificationsEnabled] == true, nil);
    
    NSInteger section = [[self.resultsController fetchedObjects] count];
    NSIndexPath *indexPath = [NSIndexPath indexPathForRow:1 inSection:section];
    [self.tableView selectRowAtIndexPath:indexPath animated:NO scrollPosition:UITableViewScrollPositionNone];
}

- (void)selectFirstAvailableBlog {
    if ([[self.resultsController fetchedObjects] count] > 0) {
        [self selectBlogWithSection:0];
    }
}

- (void)selectBlogWithSection:(NSUInteger)index {
    [self toggleSection:index];
    NSIndexPath *indexPath = [NSIndexPath indexPathForRow:0 inSection:index];
    [self processRowSelectionAtIndexPath:indexPath closingSidebar:NO];
    [self.tableView selectRowAtIndexPath:indexPath animated:NO scrollPosition:UITableViewScrollPositionNone];
}

- (void)selectBlog:(Blog *)blog
{
    __block BOOL blogFound;
    __block int blogIndex;
    
    [[self.resultsController fetchedObjects] enumerateObjectsUsingBlock:^(Blog *curBlog, NSUInteger idx, BOOL *stop){
        if ([curBlog isEqual:blog]) {
            blogFound = YES;
            blogIndex = idx;
            *stop = YES;
        }
    }];
    
    if (blogFound) {
        Blog *foundBlog = [[self.resultsController fetchedObjects] objectAtIndex:blogIndex];
        if ([_currentlyOpenedBlog isEqual:foundBlog]) {
            // Don't toggle the section again
            NSIndexPath *indexPath = [NSIndexPath indexPathForRow:0 inSection:blogIndex];
            [self processRowSelectionAtIndexPath:indexPath];
            [self.tableView selectRowAtIndexPath:indexPath animated:NO scrollPosition:UITableViewScrollPositionNone];
        } else {
            [self selectBlogWithSection:blogIndex];
        }
    }
}

- (void)registerForWordPressDotComAccountChangingNotification
{
    void (^wpcomNotificationBlock)(NSNotification *) = ^(NSNotification *note) {
        NSIndexPath *selectedIndexPath = [self.tableView indexPathForSelectedRow];
        [self.tableView reloadData];
        if (selectedIndexPath == nil || ([WPAccount defaultWordPressComAccount] == nil && [self isLastSection:selectedIndexPath.section])) {
            [self selectFirstAvailableItem];
        }
        [self checkNothingToShow];
    };
    [[NSNotificationCenter defaultCenter] addObserverForName:WPAccountDefaultWordPressComAccountChangedNotification object:nil queue:nil usingBlock:wpcomNotificationBlock];
}

- (void)registerForNewNotificationsNotifications
{
    //WPCom notifications
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(selectNotificationsRow)
												 name:@"SelectNotificationsRow" object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(didReceiveUnseenNotesNotification:)
												 name:@"WordPressComUnseenNotes" object:nil];
}

- (void)selectNotificationsRow {
    if (![self areReaderAndNotificationsEnabled]) {
        // No notifications available. We probably got a push notification after sign out
        return;
    }
    
    NSIndexPath *notificationsIndexPath = [self indexPathForNotifications];
    [self.tableView selectRowAtIndexPath:notificationsIndexPath animated:NO scrollPosition:UITableViewScrollPositionTop];
    _currentIndexPath = notificationsIndexPath;
    [self saveCurrentlySelectedItemForRestoration:notificationsIndexPath];
}

- (void)didReceiveUnseenNotesNotification:(NSNotification *)notification {
    NSIndexPath *notificationsIndexPath = [self indexPathForNotifications];
    if ([notificationsIndexPath compare:_currentIndexPath] != NSOrderedSame) {
        NSNumber *unseenNotificationCount = [notification.userInfo objectForKey:@"note_count"];
        _unseenNotificationCount = [unseenNotificationCount integerValue];
        [self.tableView reloadRowsAtIndexPaths:[NSArray arrayWithObject:notificationsIndexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
    }
}


- (void)showCommentWithId:(NSNumber *)itemId blogId:(NSNumber *)blogId {
    __block BOOL blogFound;
    __block NSInteger sectionNumber = -1;
    __block Blog *blog;
    [[self.resultsController fetchedObjects] enumerateObjectsUsingBlock:^(Blog *curBlog, NSUInteger idx, BOOL *stop){
        if (([curBlog isWPcom] && [curBlog.blogID isEqualToNumber:blogId])
            ||
            ( [curBlog getOptionValue:@"jetpack_client_id"] != nil && [[[curBlog getOptionValue:@"jetpack_client_id"] numericValue]  isEqualToNumber:blogId] ) ) {
            blogFound = YES;
            sectionNumber = idx;
            curBlog = blog;
            *stop = YES;
        }
    }];
    
    
    if (blogFound && [self isLastSection:sectionNumber]) {
        if (![blog isEqual:_currentlyOpenedBlog]) {
            [self toggleSection:sectionNumber forRow:2];
        }
        if ([self.panelNavigationController.detailViewController respondsToSelector:@selector(setWantedCommentId:)]) {
            [self.panelNavigationController.detailViewController performSelector:@selector(setWantedCommentId:) withObject:itemId];
        }
    }    
}

#pragma mark - Quick Photo Related

- (void)showQuickPhotoForFrame:(CGRect)frame {
    if (_quickPhotoActionSheet) {
        // Dismiss the previous action sheet without invoking a button click.
        [_quickPhotoActionSheet dismissWithClickedButtonIndex:-1 animated:NO];
    }
    
    if ([UIImagePickerController isSourceTypeAvailable:UIImagePickerControllerSourceTypeCamera]) {
        UIActionSheet *actionSheet = [[UIActionSheet alloc] initWithTitle:@""
                                                  delegate:self
                                         cancelButtonTitle:NSLocalizedString(@"Cancel", @"")
                                    destructiveButtonTitle:nil
                                         otherButtonTitles:NSLocalizedString(@"Add Photo from Library", @""),NSLocalizedString(@"Take Photo", @""),nil];
        
        actionSheet.actionSheetStyle = UIActionSheetStyleDefault;
        if (IS_IPAD) {
            [actionSheet showFromRect:frame inView:self.view animated:YES];
        } else {
            [actionSheet showInView:self.panelNavigationController.view];
        }
        _quickPhotoActionSheet = actionSheet;
	} else {
        [self showQuickPhoto:UIImagePickerControllerSourceTypePhotoLibrary withImage:nil];
        return;
	}
}

- (void)actionSheet:(UIActionSheet *)actionSheet clickedButtonAtIndex:(NSInteger)buttonIndex
{
    NSString *buttonTitle = [actionSheet buttonTitleAtIndex:buttonIndex];
    if ([buttonTitle isEqualToString:NSLocalizedString(@"Take Photo", @"")]) {
        [self showQuickPhoto:UIImagePickerControllerSourceTypeCamera withImage:nil];
    } else if ([buttonTitle isEqualToString:NSLocalizedString(@"Add Photo from Library", @"")]) {
        [self showQuickPhoto:UIImagePickerControllerSourceTypePhotoLibrary withImage:nil];
    }
}

- (void)showQuickPhoto:(UIImagePickerControllerSourceType)sourceType withImage:(UIImage *)image {
    [WPMobileStats incrementProperty:StatsPropertySidebarClickedQuickPhoto forEvent:StatsEventAppClosed];
    
    QuickPhotoViewController *quickPhotoViewController = [[QuickPhotoViewController alloc] init];
    quickPhotoViewController.sidebarViewController = self;
    quickPhotoViewController.photo = image;
    if (!image) {
        quickPhotoViewController.sourceType = sourceType;
    }
    
    UINavigationController *navController = [[UINavigationController alloc] initWithRootViewController:quickPhotoViewController];
    navController.navigationBar.translucent = NO;
    if (IS_IPAD) {
        navController.modalPresentationStyle = UIModalPresentationFormSheet;
        navController.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
        [self.panelNavigationController presentViewController:navController animated:YES completion:nil];
    } else {
        [self.panelNavigationController presentViewController:navController animated:YES completion:nil];
    }
}

- (void)uploadQuickPhoto:(Post *)post
{
    if (post != nil) {
        self.currentQuickPost = post;
        
        if (IS_IPHONE) {
            [self selectBlog:post.blog];
        }
    }
}

- (void)setCurrentQuickPost:(Post *)currentQuickPost
{
    if (currentQuickPost != _currentQuickPost) {
        if (_currentQuickPost) {
            [[NSNotificationCenter defaultCenter] removeObserver:self name:@"PostUploaded" object:_currentQuickPost];
            [[NSNotificationCenter defaultCenter] removeObserver:self name:@"PostUploadFailed" object:_currentQuickPost];
            [[NSNotificationCenter defaultCenter] removeObserver:self name:@"PostUploadCancelled" object:_currentQuickPost];
        }
        _currentQuickPost = currentQuickPost;
        if (_currentQuickPost) {
            [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(postDidUploadSuccessfully:) name:@"PostUploaded" object:currentQuickPost];
            [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(postUploadFailed:) name:@"PostUploadFailed" object:currentQuickPost];
            [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(postUploadCancelled:) name:@"PostUploadCancelled" object:currentQuickPost];
        }
    }
}

- (void)postDidUploadSuccessfully:(NSNotification *)notification {
    self.currentQuickPost = nil;
}

- (void)postUploadFailed:(NSNotification *)notification {
    self.currentQuickPost = nil;
    
    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:NSLocalizedString(@"Quick Photo Failed", @"")
                                                    message:NSLocalizedString(@"The photo could not be published. It's been saved as a local draft.", @"")
                                                   delegate:nil
                                          cancelButtonTitle:NSLocalizedString(@"OK", @"")
                                          otherButtonTitles:nil];
    [alert show];
}

- (void)postUploadCancelled:(NSNotification *)notification {
    self.currentQuickPost = nil;
}

-(void)quickAddNewPost:(NSIndexPath *)indexPath {
    [self processRowSelectionAtIndexPath:indexPath];
    [self.tableView selectRowAtIndexPath:indexPath animated:NO scrollPosition:UITableViewScrollPositionNone];

    if ([self.panelNavigationController.topViewController respondsToSelector:@selector(showAddPostView)]) {
        [self.panelNavigationController.topViewController performSelector:@selector(showAddPostView)];
    }
}

#pragma mark - NSFetchedResultsControllerDelegate methods

- (void)controllerWillChangeContent:(NSFetchedResultsController *)controller {
    NSIndexPath *indexPath = [self.tableView indexPathForSelectedRow];
    if (indexPath) {
        _wantedSection = indexPath.section;
    } else {
        _wantedSection = 0;
    }
    [self.tableView beginUpdates];
}

- (void)controllerDidChangeContent:(NSFetchedResultsController *)controller {
    [self.tableView endUpdates];
    NSIndexPath *indexPath = [self.tableView indexPathForSelectedRow];
    if (indexPath != nil) {
        if (indexPath.section != _wantedSection || _changingContentForSelectedSection) {
            NSUInteger sec = _wantedSection;
            
            if (![self isLastSection:sec] && [self isIndexPathValid:[NSIndexPath indexPathForRow:0 inSection:sec]]) {
                // Section is a blog
                [self selectBlogWithSection:sec];
            } else {
                [self selectFirstAvailableItem];
            }
            
            _changingContentForSelectedSection = NO;
        }
    } else {
        [self selectFirstAvailableItem];
    }
}

- (void)controller:(NSFetchedResultsController *)controller
   didChangeObject:(id)anObject
       atIndexPath:(NSIndexPath *)indexPath
     forChangeType:(NSFetchedResultsChangeType)type
      newIndexPath:(NSIndexPath *)newIndexPath {
    
    if (NSFetchedResultsChangeUpdate == type && newIndexPath != nil) {
        // Seriously, Apple?
        // http://developer.apple.com/library/ios/#releasenotes/iPhone/NSFetchedResultsChangeMoveReportedAsNSFetchedResultsChangeUpdate/_index.html
        type = NSFetchedResultsChangeMove;
    }
    
    switch (type) {
        case NSFetchedResultsChangeInsert:
        {
            NSLog(@"Inserting row %d: %@", newIndexPath.row, anObject);
            NSIndexPath *openIndexPath = [self.tableView indexPathForSelectedRow];
            if (openIndexPath.section == newIndexPath.row) {
                // We're swapping the content for the currently selected section and need to update accordingly.
                _changingContentForSelectedSection = YES;
            }
            [self.tableView insertSections:[NSIndexSet indexSetWithIndex:newIndexPath.row] withRowAnimation:UITableViewRowAnimationAutomatic];
            _wantedSection = newIndexPath.row;
            break;
        }
        case NSFetchedResultsChangeDelete:
        {
            NSLog(@"Deleting row %d: %@", indexPath.row, anObject);
            Blog *blog = (Blog *)anObject;
            if ([blog isEqual:_currentlyOpenedBlog]) {
                _currentlyOpenedBlog = nil;
            }
            NSIndexPath *openIndexPath = [self.tableView indexPathForSelectedRow];
            if (openIndexPath.section == newIndexPath.row) {
                // We're swapping the content for the currently selected section and need to update accordingly.
                _changingContentForSelectedSection = YES;
            }

            [self.tableView deleteSections:[NSIndexSet indexSetWithIndex:indexPath.row] withRowAnimation:UITableViewRowAnimationNone];
            _wantedSection = 0;
            break;
        }
    }
}

@end
