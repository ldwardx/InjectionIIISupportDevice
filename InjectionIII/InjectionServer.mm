//
//  InjectionServer.mm
//  InjectionIII
//
//  Created by John Holdsworth on 06/11/2017.
//  Copyright © 2017 John Holdsworth. All rights reserved.
//

#import "InjectionServer.h"
#import "SignerService.h"
#import "AppDelegate.h"
#import "FileWatcher.h"
#import <sys/stat.h>

#import "Xcode.h"
#import "XcodeHash.h"
#import "UserDefaults.h"

#import "InjectionIII-Swift.h"

#define kDerivedDataBookmarkKey @"kDerivedDataBookmarkKey"

static NSString *XcodeBundleID = @"com.apple.dt.Xcode";
static dispatch_queue_t injectionQueue = dispatch_queue_create("InjectionQueue", DISPATCH_QUEUE_SERIAL);

static NSMutableDictionary *projectInjected = [NSMutableDictionary new];
#define MIN_INJECTION_INTERVAL 1.

@implementation InjectionServer {
    void (^injector)(NSArray *changed);
    FileWatcher *fileWatcher;
    SwiftEval *builder;
    NSURL *derivedData;
    NSMutableArray *pending;
}

+ (int)error:(NSString *)message {
    int saveno = errno;
    dispatch_async(dispatch_get_main_queue(), ^{
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        [[NSAlert alertWithMessageText:@"Injection Error"
                         defaultButton:@"OK" alternateButton:nil otherButton:nil
             informativeTextWithFormat:message, strerror(saveno)] runModal];
#pragma clang diagnostic pop
    });
    return -1;
}

- (void)runInBackground {
    [self writeString:NSHomeDirectory()];

    NSString *projectFile = appDelegate.selectedProject;
    static BOOL MAS = false;

//    if (!projectFile) {
//        XcodeApplication *xcode = (XcodeApplication *)[SBApplication
//                           applicationWithBundleIdentifier:XcodeBundleID];
//        XcodeWorkspaceDocument *workspace = [xcode activeWorkspaceDocument];
//        projectFile = workspace.file.path;
//    }

    if (!projectFile) {
        dispatch_sync(dispatch_get_main_queue(), ^{
            [appDelegate openProject:self];
        });
        projectFile = appDelegate.selectedProject;
        MAS = true;
    }
    if (!projectFile)
        return;

    NSLog(@"Connection with project file: %@", projectFile);

    // tell client app the inferred project being watched
    if (![[self readString] isEqualToString:INJECTION_KEY])
        return;

    builder = [SwiftEval new];
    builder.tmpDir = NSHomeDirectory();
    
    // client spcific data for building
    if (NSString *frameworks = [self readString])
        builder.frameworks = frameworks;
    else
        return;

    if (NSString *arch = [self readString]) {
        builder.arch = arch;
        if ([arch isEqualToString:@"arm64"]) {
            if (NSString *sign = [self readString]) {
                builder.sign = sign;
            }
        }
    }
    else
        return;

    // Xcode specific config
    if (NSRunningApplication *xcode = [NSRunningApplication
                                       runningApplicationsWithBundleIdentifier:XcodeBundleID].firstObject)
        builder.xcodeDev = [xcode.bundleURL.path stringByAppendingPathComponent:@"Contents/Developer"];

    // locate derived data and ask permission
    derivedData = [builder findDerivedDataWithUrl:[NSURL fileURLWithPath:NSHomeDirectory()]];
    if (derivedData) {
        if (![[ScopedBookmarkManager bookmarkFor:kDerivedDataBookmarkKey].path isEqualToString:derivedData.path]) {
            __block BOOL permission = NO;
            dispatch_sync(dispatch_get_main_queue(), ^{
                permission = [[DirectoryAccessHelper new] askPermissionFor:derivedData
                                                                  bookmark:kDerivedDataBookmarkKey
                                                                       app:@"InjectionIII"];
            });
            if (!permission) {
                NSLog(@"Could not access derived data.");
                return;
            }
        }
    } else {
        NSLog(@"Could not locate derived data. Is the project under you home directory?");
        return;
    }
    
    // callback on errors
    builder.evalError = ^NSError *(NSString *message) {
        [self writeCommand:InjectionLog withString:message];
        return [[NSError alloc] initWithDomain:@"SwiftEval" code:-1
                                      userInfo:@{NSLocalizedDescriptionKey: message}];
    };

    [appDelegate setMenuIcon:@"InjectionOK"];
    appDelegate.lastConnection = self;
    pending = [NSMutableArray new];

    auto inject = ^(NSString *swiftSource) {
        NSControlStateValue watcherState = appDelegate.enableWatcher.state;
        dispatch_async(injectionQueue, ^{
            if (watcherState == NSControlStateValueOn) {
                [appDelegate setMenuIcon:@"InjectionBusy"];
//                if (!MAS) {
//                    if (NSString *tmpfile = [builder rebuildClassWithOldClass:nil
//                                                              classNameOrFile:swiftSource extra:nil error:nil])
//                        [self writeString:[@"LOAD " stringByAppendingString:tmpfile]];
//                    else
//                        [appDelegate setMenuIcon:@"InjectionError"];
//                }
//                else
                    [self injectWithSource:swiftSource];;
            }
            else
                [self writeCommand:InjectionLog withString:@"The file watcher is turned off"];
        });
    };

    NSMutableDictionary<NSString *, NSNumber *> *lastInjected = projectInjected[projectFile];
    if (!lastInjected)
        projectInjected[projectFile] = lastInjected = [NSMutableDictionary new];

    if (NSString *executable = [self readString]) {
        auto mtime = ^time_t (NSString *path) {
            struct stat info;
            return stat(path.UTF8String, &info) == 0 ? info.st_mtimespec.tv_sec : 0;
        };
        time_t executableBuild = mtime(executable);
        for(NSString *source in lastInjected)
            if (![source hasSuffix:@"storyboard"] && ![source hasSuffix:@"xib"] &&
                mtime(source) > executableBuild)
                inject(source);
    }
    else
        return;

    __block NSTimeInterval pause = 0.;

    // start up a file watcher to write generated tmpfile path to client app

    NSMutableDictionary<NSString *, NSArray *> *testCache = [NSMutableDictionary new];

    injector = ^(NSArray *changed) {
        NSMutableArray *changedFiles = [NSMutableArray arrayWithArray:changed];

        if ([[NSUserDefaults standardUserDefaults] boolForKey:UserDefaultsTDDEnabled]) {
            for (NSString *injectedFile in changed) {
                NSArray *matchedTests = testCache[injectedFile] ?:
                    (testCache[injectedFile] = [InjectionServer searchForTestWithFile:injectedFile
                                    projectRoot:projectFile.stringByDeletingLastPathComponent
                                    fileManager:[NSFileManager defaultManager]]);
                [changedFiles addObjectsFromArray:matchedTests];
            }
        }

        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
        BOOL automatic = appDelegate.enableWatcher.state == NSControlStateValueOn;
        for (NSString *swiftSource in changedFiles)
            if (![pending containsObject:swiftSource])
                if (now > lastInjected[swiftSource].doubleValue + MIN_INJECTION_INTERVAL && now > pause) {
                    lastInjected[swiftSource] = [NSNumber numberWithDouble:now];
                    [pending addObject:swiftSource];
                    if (!automatic)
                        [self writeCommand:InjectionLog
                                withString:[NSString stringWithFormat:
                                            @"'%@' saved, type ctrl-= to inject",
                                            swiftSource.lastPathComponent]];
                }

        if (automatic)
            [self injectPending];
    };

    [self setProject:projectFile];

    // read status requests from client app
    InjectionCommand command;
    while ((command = (InjectionCommand)[self readInt]) != InjectionEOF) {
        switch (command) {
        case InjectionComplete:
            [appDelegate setMenuIcon:@"InjectionOK"];
            break;
        case InjectionPause:
            pause = [NSDate timeIntervalSinceReferenceDate] +
                [self readString].doubleValue;
            break;
        case InjectionSign: {
            BOOL signedOK = [SignerService codesignDylib:[self readString]];
            [self writeCommand:InjectionSigned withString: signedOK ? @"1": @"0"];
            break;
        }
        case InjectionError:
            [appDelegate setMenuIcon:@"InjectionError"];
            NSLog(@"Injection error: %@", [self readString]);
//            dispatch_async(dispatch_get_main_queue(), ^{
//                [[NSAlert alertWithMessageText:@"Injection Error"
//                                 defaultButton:@"OK" alternateButton:nil otherButton:nil
//                     informativeTextWithFormat:@"%@",
//                  [dylib substringFromIndex:@"ERROR ".length]] runModal];
//            });
            break;
        default:
            NSLog(@"InjectionServer: Unexpected case %d", command);
            break;
        }
    }

    // client app disconnected
    injector = nil;
    fileWatcher = nil;
    [appDelegate setMenuIcon:@"InjectionIdle"];
    [appDelegate.traceItem setState:NSOffState];
}

- (void)injectPending {
    for (NSString *swiftSource in pending)
        [self injectWithSource:swiftSource];
    [pending removeAllObjects];
}

- (void)injectWithSource:(NSString *)source {
    dispatch_async(injectionQueue, ^{
        if ([ScopedBookmarkManager startAccessingFor:kDerivedDataBookmarkKey]) {
            NSString *tmpFile = [builder rebuildClassWithOldClass:nil
                                                  classNameOrFile:source extra:nil error:nil];
            [ScopedBookmarkManager stopAccessingFor:kDerivedDataBookmarkKey];
            if (tmpFile) {
                [self writeCommand:InjectionLoad withString:tmpFile];
                if ([builder.arch isEqualToString:@"arm64"]) {
                    NSString *dylib = [tmpFile stringByAppendingPathExtension:@"dylib"];
                    NSData *dylibData = [NSData dataWithContentsOfFile:dylib];
                    [self writeData:dylibData];
                    
                    NSString *classes = [tmpFile stringByAppendingPathExtension:@"classes"];
                    NSData *classesData = [NSData dataWithContentsOfFile:classes];
                    [self writeData:classesData];
                }
            } else
                NSLog(@"dylib generate failed");
        } else
            NSLog(@"Could not access derived data.");
    });
}

- (void)setProject:(NSString *)project {
    if (!injector) return;
    
    builder.projectFile = project;
    if ([ScopedBookmarkManager startAccessingFor:kDerivedDataBookmarkKey]) {
        builder.derivedLogs = [builder logsDirWithProject:[NSURL fileURLWithPath:project] derivedData:derivedData].path;
        [ScopedBookmarkManager stopAccessingFor:kDerivedDataBookmarkKey];
    }
    if (!builder.derivedLogs) {
        NSLog(@"Could not locate derived logs.");
        return;
    }
    
    [self writeCommand:InjectionProject withString:project];
    [self writeCommand:InjectionVaccineSettingChanged withString:[appDelegate vaccineConfiguration]];
    [self watchDirectories:appDelegate.watchedDirectories.allObjects];
}

- (void)watchDirectories:(NSArray<NSString *> *)directories {
    if (!injector) return;
    [self writeCommand:InjectionDirectory withString:directories.description];
    fileWatcher = [[FileWatcher alloc] initWithPaths:directories plugin:injector];
}

+ (NSArray *)searchForTestWithFile:(NSString *)injectedFile projectRoot:(NSString *)projectRoot fileManager:(NSFileManager *)fileManager;
{
    NSMutableArray *matchedTests = [NSMutableArray array];
    NSString *injectedFileName = [[injectedFile lastPathComponent] stringByDeletingPathExtension];
    NSURL *projectUrl = [NSURL URLWithString:[self urlEncodeString:projectRoot]];
    NSDirectoryEnumerator *enumerator = [fileManager enumeratorAtURL:projectUrl
                                          includingPropertiesForKeys:@[NSURLNameKey, NSURLIsDirectoryKey]
                                                             options:NSDirectoryEnumerationSkipsHiddenFiles
                                                        errorHandler:^BOOL(NSURL *url, NSError *error)
                                         {
                                             if (error) {
                                                 NSLog(@"[Error] %@ (%@)", error, url);
                                                 return NO;
                                             }

                                             return YES;
                                         }];


    for (NSURL *fileURL in enumerator) {
        NSString *filename;
        NSNumber *isDirectory;

        [fileURL getResourceValue:&filename forKey:NSURLNameKey error:nil];
        [fileURL getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:nil];

        if ([filename hasPrefix:@"_"] && [isDirectory boolValue]) {
            [enumerator skipDescendants];
            continue;
        }

        if (![isDirectory boolValue] &&
            ![[filename lastPathComponent] isEqualToString:[injectedFile lastPathComponent]] &&
            [[filename lowercaseString] containsString:[injectedFileName lowercaseString]]) {
            [matchedTests addObject:fileURL.path];
        }
    }

    return matchedTests;
}

+ (nullable NSString *)urlEncodeString:(NSString *)string {
    NSString *unreserved = @"-._~/?";
    NSMutableCharacterSet *allowed = [NSMutableCharacterSet alphanumericCharacterSet];
    [allowed addCharactersInString:unreserved];
    return [string stringByAddingPercentEncodingWithAllowedCharacters: allowed];
}

- (void)dealloc {
    NSLog(@"- [%@ dealloc]", self);
}

@end
