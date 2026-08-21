@import Foundation;
@import UIKit;

#import <objc/message.h>
#import <objc/runtime.h>

#import "FilzaDiagnostics.h"
#import "FilzaSSHServer.h"

static NSInteger (*FilzaSSHOriginalSections)(id, SEL, UITableView *) = NULL;
static NSInteger (*FilzaSSHOriginalRows)(id, SEL, UITableView *, NSInteger) = NULL;
static NSString *(*FilzaSSHOriginalHeader)(id, SEL, UITableView *, NSInteger) = NULL;
static NSString *(*FilzaSSHOriginalFooter)(id, SEL, UITableView *, NSInteger) = NULL;
static UITableViewCell *(*FilzaSSHOriginalCell)(id, SEL, UITableView *, NSIndexPath *) = NULL;
static void (*FilzaSSHOriginalDidSelect)(id, SEL, UITableView *, NSIndexPath *) = NULL;
static BOOL FilzaSSHPreferencesInstalled = NO;

static UIViewController *FilzaSSHViewController(id controller)
{
    return [controller isKindOfClass:UIViewController.class] ? controller : nil;
}

static void FilzaSSHReloadController(id controller)
{
    UITableView *table = nil;
    if ([controller isKindOfClass:UITableViewController.class]) table = ((UITableViewController *)controller).tableView;
    if (!table && [controller respondsToSelector:@selector(tableView)]) {
        id candidate = ((id (*)(id, SEL))objc_msgSend)(controller, @selector(tableView));
        if ([candidate isKindOfClass:UITableView.class]) table = candidate;
    }
    [table reloadData];
}

static void FilzaSSHShowError(UIViewController *controller, NSError *error)
{
    if (!controller || !error) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"SSH Server"
                                                                   message:error.localizedDescription
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [controller presentViewController:alert animated:YES completion:nil];
}

static BOOL FilzaSSHStartAndPersist(id controller, UISwitch *toggle)
{
    NSError *error = nil;
    if (FilzaSSHServerStart(&error)) {
        [NSUserDefaults.standardUserDefaults setBool:YES forKey:FilzaSSHEnabledKey];
        toggle.on = YES;
        FilzaDiagnosticsAppend(@"SSH", @"SSH/SFTP enabled from preferences after verified listener start");
        FilzaSSHReloadController(controller);
        return YES;
    }
    [NSUserDefaults.standardUserDefaults setBool:NO forKey:FilzaSSHEnabledKey];
    toggle.on = NO;
    FilzaSSHShowError(FilzaSSHViewController(controller), error);
    FilzaSSHReloadController(controller);
    return NO;
}

static void FilzaSSHPromptForInitialPassword(id controller, UISwitch *toggle)
{
    UIViewController *presenter = FilzaSSHViewController(controller);
    if (!presenter) {
        toggle.on = NO;
        return;
    }

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Set SSH Password"
                                                                   message:@"Authentication is enabled. Create a password before the SSH/SFTP listener starts."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"Password (6+ characters)";
        field.secureTextEntry = YES;
        field.textContentType = UITextContentTypeNewPassword;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(__unused UIAlertAction *action) {
        [NSUserDefaults.standardUserDefaults setBool:NO forKey:FilzaSSHEnabledKey];
        toggle.on = NO;
        FilzaSSHReloadController(controller);
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Start SSH + SFTP" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        NSString *password = alert.textFields.firstObject.text ?: @"";
        NSError *error = nil;
        if (!FilzaSSHStorePassword(password, &error)) {
            toggle.on = NO;
            [NSUserDefaults.standardUserDefaults setBool:NO forKey:FilzaSSHEnabledKey];
            FilzaSSHShowError(presenter, error);
            FilzaSSHReloadController(controller);
            return;
        }
        FilzaSSHStartAndPersist(controller, toggle);
    }]];
    [presenter presentViewController:alert animated:YES completion:nil];
}

static void FilzaSSHRestartForSettings(UIViewController *controller)
{
    if (!FilzaSSHServerIsRunning()) return;
    NSError *error = nil;
    if (!FilzaSSHServerRestart(&error)) {
        [NSUserDefaults.standardUserDefaults setBool:NO forKey:FilzaSSHEnabledKey];
        FilzaSSHShowError(controller, error);
    }
}

@interface FilzaSSHPortController : UITableViewController
@end
@implementation FilzaSSHPortController
- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }
- (void)viewDidLoad { [super viewDidLoad]; self.title = @"Port"; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return 5; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSArray<NSNumber *> *ports = @[@2222, @10022, @2022, @8022, @22222];
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"FilzaSSHPort"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"FilzaSSHPort"];
    NSInteger port = ports[indexPath.row].integerValue;
    cell.textLabel.text = [NSString stringWithFormat:@"%ld", (long)port];
    cell.accessoryType = (FilzaSSHConfiguredPort() == port) ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    NSArray<NSNumber *> *ports = @[@2222, @10022, @2022, @8022, @22222];
    [NSUserDefaults.standardUserDefaults setInteger:ports[indexPath.row].integerValue forKey:FilzaSSHPortKey];
    FilzaSSHRestartForSettings(self);
    [self.navigationController popViewControllerAnimated:YES];
}
@end

@interface FilzaSSHBonjourController : UITableViewController
@end
@implementation FilzaSSHBonjourController
- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }
- (void)viewDidLoad { [super viewDidLoad]; self.title = @"Bonjour"; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return 2; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"FilzaSSHBonjour"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"FilzaSSHBonjour"];
    BOOL value = indexPath.row == 0;
    cell.textLabel.text = value ? @"Yes" : @"No";
    cell.accessoryType = (FilzaSSHBonjourEnabled() == value) ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [NSUserDefaults.standardUserDefaults setBool:(indexPath.row == 0) forKey:FilzaSSHBonjourKey];
    FilzaSSHRestartForSettings(self);
    [self.navigationController popViewControllerAnimated:YES];
}
@end

@interface FilzaSSHAuthenticationController : UITableViewController <UITextFieldDelegate>
@property(nonatomic, strong) UISwitch *authenticationSwitch;
@property(nonatomic, strong) UITextField *usernameField;
@property(nonatomic, strong) UITextField *passwordField;
@end
@implementation FilzaSSHAuthenticationController
- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Authentication";
    self.authenticationSwitch = UISwitch.new;
    self.authenticationSwitch.on = FilzaSSHAuthenticationEnabled();
    [self.authenticationSwitch addTarget:self action:@selector(authenticationChanged:) forControlEvents:UIControlEventValueChanged];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return section == 0 ? 1 : 2; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"FilzaSSHAuthSwitch"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"FilzaSSHAuthSwitch"];
        cell.textLabel.text = @"Enable authentication";
        cell.accessoryView = self.authenticationSwitch;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"FilzaSSHAuthField"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"FilzaSSHAuthField"];
    UITextField *field = [[UITextField alloc] initWithFrame:CGRectZero];
    field.translatesAutoresizingMaskIntoConstraints = NO;
    field.delegate = self;
    field.enabled = FilzaSSHAuthenticationEnabled();
    field.textColor = field.enabled ? UIColor.labelColor : UIColor.secondaryLabelColor;
    [cell.contentView.subviews makeObjectsPerformSelector:@selector(removeFromSuperview)];
    [cell.contentView addSubview:field];
    [NSLayoutConstraint activateConstraints:@[
        [field.leadingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.leadingAnchor],
        [field.trailingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.trailingAnchor],
        [field.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor],
        [field.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor]
    ]];
    if (indexPath.row == 0) {
        field.placeholder = @"Username";
        field.text = FilzaSSHConfiguredUsername();
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
        self.usernameField = field;
    } else {
        field.placeholder = FilzaSSHPasswordConfigured() ? @"Password (configured)" : @"Password";
        field.secureTextEntry = YES;
        field.textContentType = UITextContentTypePassword;
        self.passwordField = field;
    }
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    return cell;
}
- (void)authenticationChanged:(UISwitch *)sender {
    [NSUserDefaults.standardUserDefaults setBool:sender.on forKey:FilzaSSHAuthenticationKey];
    [self.tableView reloadData];
    if (sender.on && FilzaSSHServerIsRunning() && !FilzaSSHPasswordConfigured()) {
        FilzaSSHServerStop();
        [NSUserDefaults.standardUserDefaults setBool:NO forKey:FilzaSSHEnabledKey];
        NSError *error = [NSError errorWithDomain:@"FilzaSSH" code:30 userInfo:@{NSLocalizedDescriptionKey: @"Set a password before re-enabling the SSH/SFTP server."}];
        FilzaSSHShowError(self, error);
        return;
    }
    FilzaSSHRestartForSettings(self);
}
- (BOOL)textFieldShouldReturn:(UITextField *)textField { [textField resignFirstResponder]; return YES; }
- (void)textFieldDidEndEditing:(UITextField *)textField {
    if (textField == self.usernameField) {
        NSString *name = [textField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (name.length) [NSUserDefaults.standardUserDefaults setObject:name forKey:FilzaSSHUsernameKey];
        FilzaSSHRestartForSettings(self);
        return;
    }
    if (textField == self.passwordField && textField.text.length) {
        NSError *error = nil;
        if (!FilzaSSHStorePassword(textField.text, &error)) FilzaSSHShowError(self, error);
        else FilzaSSHRestartForSettings(self);
        textField.text = @"";
        textField.placeholder = FilzaSSHPasswordConfigured() ? @"Password (configured)" : @"Password";
    }
}
@end

static NSInteger FilzaSSHOriginalSectionCount(id controller, UITableView *table)
{
    return FilzaSSHOriginalSections ? FilzaSSHOriginalSections(controller, @selector(numberOfSectionsInTableView:), table) : 1;
}

static NSInteger FilzaSSHInsertionBoundary(id controller, UITableView *table)
{
    NSInteger count = FilzaSSHOriginalSectionCount(controller, table);
    NSInteger viewers = NSNotFound;
    if (FilzaSSHOriginalHeader) {
        for (NSInteger section = 0; section < count; section++) {
            NSString *title = FilzaSSHOriginalHeader(controller, @selector(tableView:titleForHeaderInSection:), table, section);
            NSString *normalized = [title stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].uppercaseString;
            if ([normalized isEqualToString:@"WEBDAV SERVER"]) return section + 1;
            if ([normalized isEqualToString:@"VIEWERS"]) viewers = section;
        }
    }
    if (viewers != NSNotFound) return viewers;
    return count;
}

static BOOL FilzaSSHIsSyntheticSection(id controller, UITableView *table, NSInteger displaySection)
{
    return displaySection == FilzaSSHInsertionBoundary(controller, table);
}

static NSInteger FilzaSSHOriginalSectionForDisplay(id controller, UITableView *table, NSInteger displaySection)
{
    NSInteger insertion = FilzaSSHInsertionBoundary(controller, table);
    return displaySection > insertion ? displaySection - 1 : displaySection;
}

static NSInteger FilzaSSHSections(id controller, __unused SEL selector, UITableView *table)
{
    return FilzaSSHOriginalSectionCount(controller, table) + 1;
}

static NSInteger FilzaSSHRows(id controller, __unused SEL selector, UITableView *table, NSInteger displaySection)
{
    if (FilzaSSHIsSyntheticSection(controller, table, displaySection)) return 4;
    NSInteger originalSection = FilzaSSHOriginalSectionForDisplay(controller, table, displaySection);
    return FilzaSSHOriginalRows ? FilzaSSHOriginalRows(controller, @selector(tableView:numberOfRowsInSection:), table, originalSection) : 0;
}

static NSString *FilzaSSHHeader(id controller, __unused SEL selector, UITableView *table, NSInteger displaySection)
{
    if (FilzaSSHIsSyntheticSection(controller, table, displaySection)) return @"SSH SERVER";
    NSInteger originalSection = FilzaSSHOriginalSectionForDisplay(controller, table, displaySection);
    return FilzaSSHOriginalHeader ? FilzaSSHOriginalHeader(controller, @selector(tableView:titleForHeaderInSection:), table, originalSection) : nil;
}

static NSString *FilzaSSHFooter(id controller, __unused SEL selector, UITableView *table, NSInteger displaySection)
{
    if (FilzaSSHIsSyntheticSection(controller, table, displaySection)) {
        if (FilzaSSHServerIsRunning()) return FilzaSSHServerConnectionSummary();
        NSString *failure = FilzaSSHServerLastError();
        return failure.length ? [@"Not listening: " stringByAppendingString:failure] : @"SSH + SFTP. Enable the server to show the LAN connection address.";
    }
    NSInteger originalSection = FilzaSSHOriginalSectionForDisplay(controller, table, displaySection);
    return FilzaSSHOriginalFooter ? FilzaSSHOriginalFooter(controller, @selector(tableView:titleForFooterInSection:), table, originalSection) : nil;
}

static UITableViewCell *FilzaSSHCell(id controller, __unused SEL selector, UITableView *table, NSIndexPath *displayPath)
{
    if (!FilzaSSHIsSyntheticSection(controller, table, displayPath.section)) {
        NSInteger originalSection = FilzaSSHOriginalSectionForDisplay(controller, table, displayPath.section);
        NSIndexPath *originalPath = [NSIndexPath indexPathForRow:displayPath.row inSection:originalSection];
        return FilzaSSHOriginalCell ? FilzaSSHOriginalCell(controller, @selector(tableView:cellForRowAtIndexPath:), table, originalPath) : UITableViewCell.new;
    }
    UITableViewCell *cell = [table dequeueReusableCellWithIdentifier:@"FilzaSSHPreference"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"FilzaSSHPreference"];
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.detailTextLabel.text = nil;
    switch (displayPath.row) {
        case 0:
            cell.textLabel.text = @"Port";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%ld", (long)FilzaSSHConfiguredPort()];
            break;
        case 1:
            cell.textLabel.text = @"Bonjour";
            cell.detailTextLabel.text = FilzaSSHBonjourEnabled() ? @"Yes" : @"No";
            break;
        case 2:
            cell.textLabel.text = @"Authentication";
            cell.detailTextLabel.text = FilzaSSHAuthenticationEnabled() ? (FilzaSSHPasswordConfigured() ? @"Yes" : @"Needs password") : @"No";
            break;
        default: {
            cell.textLabel.text = @"Enable SSH + SFTP";
            cell.accessoryType = UITableViewCellAccessoryNone;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            UISwitch *toggle = UISwitch.new;
            toggle.on = FilzaSSHServerIsRunning();
            [toggle addTarget:controller action:NSSelectorFromString(@"filzaSSHServerSwitchChanged:") forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = toggle;
            break;
        }
    }
    return cell;
}

static void FilzaSSHDidSelect(id controller, __unused SEL selector, UITableView *table, NSIndexPath *displayPath)
{
    if (!FilzaSSHIsSyntheticSection(controller, table, displayPath.section)) {
        NSInteger originalSection = FilzaSSHOriginalSectionForDisplay(controller, table, displayPath.section);
        NSIndexPath *originalPath = [NSIndexPath indexPathForRow:displayPath.row inSection:originalSection];
        if (FilzaSSHOriginalDidSelect) FilzaSSHOriginalDidSelect(controller, @selector(tableView:didSelectRowAtIndexPath:), table, originalPath);
        return;
    }
    [table deselectRowAtIndexPath:displayPath animated:YES];
    UIViewController *next = nil;
    if (displayPath.row == 0) next = FilzaSSHPortController.new;
    else if (displayPath.row == 1) next = FilzaSSHBonjourController.new;
    else if (displayPath.row == 2) next = FilzaSSHAuthenticationController.new;
    if (next && [controller respondsToSelector:@selector(navigationController)]) {
        UINavigationController *nav = ((id (*)(id, SEL))objc_msgSend)(controller, @selector(navigationController));
        [nav pushViewController:next animated:YES];
    }
}

static void FilzaSSHServerSwitchChanged(id controller, __unused SEL selector, UISwitch *toggle)
{
    if (toggle.on) {
        if (FilzaSSHAuthenticationEnabled() && !FilzaSSHPasswordConfigured()) {
            FilzaSSHPromptForInitialPassword(controller, toggle);
            return;
        }
        FilzaSSHStartAndPersist(controller, toggle);
    } else {
        [NSUserDefaults.standardUserDefaults setBool:NO forKey:FilzaSSHEnabledKey];
        FilzaSSHServerStop();
        FilzaSSHReloadController(controller);
    }
}

static void FilzaSSHInstallOverride(Class cls, SEL selector, IMP replacement, IMP *original)
{
    Method inheritedOrOwn = class_getInstanceMethod(cls, selector);
    if (!inheritedOrOwn) return;
    IMP previous = method_getImplementation(inheritedOrOwn);
    const char *types = method_getTypeEncoding(inheritedOrOwn);
    if (original) *original = previous;
    if (!class_addMethod(cls, selector, replacement, types)) {
        Method own = class_getInstanceMethod(cls, selector);
        method_setImplementation(own, replacement);
    }
}

static void FilzaSSHInstallPreferences(void)
{
    if (FilzaSSHPreferencesInstalled) return;
    Class cls = NSClassFromString(@"TGPreferencesTableViewController");
    if (!cls) { FilzaDiagnosticsAppend(@"SSH", @"SSH preferences deferred: TGPreferencesTableViewController unavailable"); return; }

    FilzaSSHInstallOverride(cls, @selector(numberOfSectionsInTableView:), (IMP)FilzaSSHSections, (IMP *)&FilzaSSHOriginalSections);
    FilzaSSHInstallOverride(cls, @selector(tableView:numberOfRowsInSection:), (IMP)FilzaSSHRows, (IMP *)&FilzaSSHOriginalRows);
    FilzaSSHInstallOverride(cls, @selector(tableView:titleForHeaderInSection:), (IMP)FilzaSSHHeader, (IMP *)&FilzaSSHOriginalHeader);
    FilzaSSHInstallOverride(cls, @selector(tableView:titleForFooterInSection:), (IMP)FilzaSSHFooter, (IMP *)&FilzaSSHOriginalFooter);
    FilzaSSHInstallOverride(cls, @selector(tableView:cellForRowAtIndexPath:), (IMP)FilzaSSHCell, (IMP *)&FilzaSSHOriginalCell);
    FilzaSSHInstallOverride(cls, @selector(tableView:didSelectRowAtIndexPath:), (IMP)FilzaSSHDidSelect, (IMP *)&FilzaSSHOriginalDidSelect);
    class_addMethod(cls, NSSelectorFromString(@"filzaSSHServerSwitchChanged:"), (IMP)FilzaSSHServerSwitchChanged, "v@:@");

    FilzaSSHPreferencesInstalled = YES;
    FilzaDiagnosticsAppend(@"SSH", @"SSH + SFTP v2 preferences installed with first-enable password setup");

    if ([NSUserDefaults.standardUserDefaults boolForKey:FilzaSSHEnabledKey]) {
        if (FilzaSSHAuthenticationEnabled() && !FilzaSSHPasswordConfigured()) {
            [NSUserDefaults.standardUserDefaults setBool:NO forKey:FilzaSSHEnabledKey];
            FilzaDiagnosticsAppend(@"SSH", @"saved enable state cleared because authentication has no password verifier");
        } else {
            NSError *error = nil;
            if (!FilzaSSHServerStart(&error)) {
                [NSUserDefaults.standardUserDefaults setBool:NO forKey:FilzaSSHEnabledKey];
                FilzaDiagnosticsAppend(@"SSH", [NSString stringWithFormat:@"saved SSH enable state could not be restored: %@", error.localizedDescription]);
            }
        }
    }
}

__attribute__((constructor)) static void FilzaSSHPreferencesInit(void)
{
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ FilzaSSHInstallPreferences(); });
            [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
                if (!FilzaSSHPreferencesInstalled) FilzaSSHInstallPreferences();
            }];
        });
    }
}
