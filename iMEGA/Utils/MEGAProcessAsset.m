
#import "MEGAProcessAsset.h"
#import "NSFileManager+MNZCategory.h"
#import "MEGASdkManager.h"
#import "MEGAReachabilityManager.h"

static const NSUInteger DOWNSCALE_IMAGES_PX = 2000000;

@interface MEGAProcessAsset ()

@property (nonatomic, copy) PHAsset *asset;
@property (nonatomic, copy) void (^filePath)(NSString *filePath);
@property (nonatomic, copy) void (^node)(MEGANode *node);
@property (nonatomic, copy) void (^error)(NSError *error);
@property (nonatomic, strong) MEGANode *parentNode;

@property (nonatomic, assign) NSUInteger retries;
@property (nonatomic, getter=toShareThroughChat) BOOL shareThroughChat;

@end

@implementation MEGAProcessAsset

- (instancetype)initWithAsset:(PHAsset *)asset parentNode:(MEGANode *)parentNode filePath:(void (^)(NSString *filePath))filePath node:(void(^)(MEGANode *node))node error:(void (^)(NSError *error))error {
    self = [super init];
    
    if (self) {
        _asset = asset;
        _filePath = filePath;
        _node = node;
        _error = error;
        _retries = 0;
        _parentNode = parentNode;
    }
    
    return self;
}


- (instancetype)initToShareThroughChatWithAsset:(PHAsset *)asset filePath:(void (^)(NSString *filePath))filePath node:(void(^)(MEGANode *node))node error:(void (^)(NSError *error))error {
    self = [super init];
    
    if (self) {
        _asset = asset;
        _filePath = filePath;
        _node = node;
        _error = error;
        _retries = 0;
        _shareThroughChat = YES;
        _parentNode = [[MEGASdkManager sharedMEGASdk] nodeForPath:@"/My chat files"];
    }
    
    return self;
}

- (void)prepare {
    switch (self.asset.mediaType) {
        case PHAssetMediaTypeImage:
            [self requestImageAsset];
            break;
            
        case PHAssetMediaTypeVideo:
            [self requestVideoAsset];
            break;
            
        default:
            break;
    }
}

- (void)requestImageAsset {
    PHImageRequestOptions *options = [[PHImageRequestOptions alloc] init];
    options.networkAccessAllowed = YES;
    if (self.retries < 10) {
        options.version = PHImageRequestOptionsVersionCurrent;
    } else {
        options.version = PHImageRequestOptionsVersionOriginal;
    }
    
    
    if (self.toShareThroughChat && ![MEGAReachabilityManager isReachableViaWiFi]) {
        NSUInteger totalPixels = self.asset.pixelWidth * self.asset.pixelHeight;
        float factor = MIN(sqrtf((float)DOWNSCALE_IMAGES_PX / totalPixels), 1);
        if (factor >= 1) {
            [self requestImageWithOptions:options];
        } else { // Optimize image
            options.synchronous = YES;
            options.resizeMode = PHImageRequestOptionsResizeModeExact;
            [[PHImageManager defaultManager] requestImageForAsset:self.asset targetSize:CGSizeMake(self.asset.pixelWidth * factor, self.asset.pixelHeight * factor) contentMode:PHImageContentModeAspectFit options:options resultHandler:^(UIImage * _Nullable result, NSDictionary * _Nullable info) {
                if (result) {
                    NSData *imageData = UIImageJPEGRepresentation(result, 0.75);
                    [self proccessImageData:imageData withInfo:info];
                } else {
                    NSError *error = [info objectForKey:@"PHImageErrorKey"];
                    MEGALogError(@"Request image data for asset: %@ failed with error: %@", self.asset, error);
                    if (self.retries < 20) {
                        self.retries++;
                        [self requestImageAsset];
                    } else {
                        if (self.error) {
                            MEGALogDebug(@"Max attempts reached");
                            self.error(error);
                        }
                    }
                }
            }];
        }
    } else {
        [self requestImageWithOptions:options];
    }
}

// Request image and don't downscale it
- (void)requestImageWithOptions:(PHImageRequestOptions *)options {
    [[PHImageManager defaultManager]
     requestImageDataForAsset:self.asset
     options:options
     resultHandler:^(NSData *imageData, NSString *dataUTI, UIImageOrientation orientation, NSDictionary *info) {
         [self proccessImageData:imageData withInfo:info];
     }];
}

- (void)requestVideoAsset {
    PHVideoRequestOptions *options = [[PHVideoRequestOptions alloc] init];
    options.version = PHImageRequestOptionsVersionOriginal;
    options.networkAccessAllowed = YES;
    [[PHImageManager defaultManager]
     requestAVAssetForVideo:self.asset
     options:options resultHandler:^(AVAsset *asset, AVAudioMix *audioMix, NSDictionary *info) {
         if (asset) {
             if ([asset isKindOfClass:[AVURLAsset class]]) {
                 NSURL *avassetUrl = [(AVURLAsset *)asset URL];
                 NSDictionary *fileAtributes = [[NSFileManager defaultManager] attributesOfItemAtPath:avassetUrl.path error:nil];
                 NSString *filePath = [self filePathAsCreationDateWithInfo:info];
                 [self deleteLocalFileIfExists:filePath];
                 long long fileSize = [[fileAtributes objectForKey:NSFileSize] longLongValue];
                 if ([self hasFreeSpaceOnDiskForWriteFile:fileSize]) {
                     NSError *error;
                     if ([[NSFileManager defaultManager] copyItemAtPath:avassetUrl.path toPath:filePath error:&error]) {
                         NSDictionary *attributesDictionary = [NSDictionary dictionaryWithObject:self.asset.creationDate forKey:NSFileModificationDate];
                         if (![[NSFileManager defaultManager] setAttributes:attributesDictionary ofItemAtPath:filePath error:&error]) {
                             MEGALogError(@"Set attributes failed with error: %@", error);
                         }
                         NSString *fingerprint = [[MEGASdkManager sharedMEGASdk] fingerprintForFilePath:filePath];
                         MEGANode *node = [[MEGASdkManager sharedMEGASdk] nodeForFingerprint:fingerprint parent:self.parentNode];
                         if (node) {
                             if (self.node) {
                                 self.node(node);
                             }
                             if (![[NSFileManager defaultManager] removeItemAtPath:filePath error:&error]) {
                                 MEGALogError(@"Remove item at path failed with error: %@", error);
                             }
                         } else {
                             if (self.filePath) {
                                 filePath = [filePath stringByReplacingOccurrencesOfString:[NSHomeDirectory() stringByAppendingString:@"/"] withString:@""];
                                 self.filePath(filePath);
                             }
                         }
                     } else {
                         MEGALogError(@"Copy item at path failed with error: %@", error);
                         if (self.error) {
                             self.error(error);
                         }
                     }
                 }
             }
         } else {
             NSError *error = [info objectForKey:@"PHImageErrorKey"];
             MEGALogError(@"Request AVAsset %@ failed with error: %@", self.asset, error);
             if (self.retries < 10) {
                 self.retries++;
                 [self requestVideoAsset];
             } else {
                 if (self.error) {
                     MEGALogDebug(@"Max attempts reached");
                     self.error(error);
                 }
             }
         }
     }];
}

#pragma mark - Private

- (void)deleteLocalFileIfExists:(NSString *)filePath {
    BOOL fileExists = [[NSFileManager defaultManager] fileExistsAtPath:filePath];
    if (fileExists) {
        NSError *error;
        if (![[NSFileManager defaultManager] removeItemAtPath:filePath error:&error]) {
            MEGALogError(@"Remove item at path failed with error: %@", error);
        }
    }
}

- (BOOL)hasFreeSpaceOnDiskForWriteFile:(long long)fileSize {
    uint64_t freeSpace = 0;
    NSError *error;
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSDictionary *dictionary = [[NSFileManager defaultManager] attributesOfFileSystemForPath:paths.lastObject error:&error];

    if (dictionary) {
        NSNumber *freeFileSystemSizeInBytes = [dictionary objectForKey:NSFileSystemFreeSize];
        freeSpace = freeFileSystemSizeInBytes.unsignedLongLongValue;
    } else {
        MEGALogError(@"Obtaining device storage info failed with error: %@", error);
    }
    
    MEGALogDebug(@"File size: %lld - Free size: %lld", fileSize, freeSpace);
    if (fileSize > freeSpace) {
        if (self.error) {
            NSDictionary *dict = @{NSLocalizedDescriptionKey:AMLocalizedString(@"nodeTooBig", @"Title shown inside an alert if you don't have enough space on your device to download something")};
            NSError *error = [NSError errorWithDomain:MEGAProcessAssetErrorDomain code:-2 userInfo:dict];
            self.error(error);
        }        
        return NO;
    }
    return YES;
}

- (NSString *)filePathAsCreationDateWithInfo:(NSDictionary *)info {
    MEGALogDebug(@"Asset %@\n%@", self.asset, info);
    NSString *name;
    
    if (self.originalName) {
        NSURL *url = [info objectForKey:@"PHImageFileURLKey"];
        if (url) {
            name = url.path.lastPathComponent;
        } else {
            NSString *imageFileSandbox = [info objectForKey:@"PHImageFileSandboxExtensionTokenKey"];
            name = imageFileSandbox.lastPathComponent;
        }
    } else {
        NSString *extension = [self extensionWithInfo:info];
        NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
        dateFormatter.dateFormat = @"yyyy'-'MM'-'dd' 'HH'.'mm'.'ss";
        NSLocale *locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
        dateFormatter.locale = locale;
        name = [[dateFormatter stringFromDate:self.asset.creationDate] stringByAppendingPathExtension:extension];
    }
    
    NSString *filePath = [[[NSFileManager defaultManager] uploadsDirectory] stringByAppendingPathComponent:name];
    return filePath;
}

- (NSString *)extensionWithInfo:(NSDictionary *)info {
    if (self.shareThroughChat && self.asset.mediaType == PHAssetMediaTypeImage) {
        return @"jpg";
    }
    
    NSString *extension;
    
    NSURL *url = [info objectForKey:@"PHImageFileURLKey"];
    if (url) {
        extension = url.path.pathExtension;
    } else {
        NSString *imageFileSandbox = [info objectForKey:@"PHImageFileSandboxExtensionTokenKey"];
        extension = imageFileSandbox.pathExtension;
    }
    
    if (!extension) {
        switch (self.asset.mediaType) {
            case PHAssetMediaTypeImage:
                extension = @"jpg";
                break;
                
            case PHAssetMediaTypeVideo:
                extension = @"mov";
                break;
                
            default:
                break;
        }
    }
    
    return extension.lowercaseString;
}

- (void)proccessImageData:(NSData *)imageData withInfo:(NSDictionary *)info {
    if (imageData) {
        NSString *fingerprint = [[MEGASdkManager sharedMEGASdk] fingerprintForData:imageData modificationTime:self.asset.creationDate];
        MEGANode *node = [[MEGASdkManager sharedMEGASdk] nodeForFingerprint:fingerprint parent:self.parentNode];
        if (node) {
            if (self.node) {
                self.node(node);
            }
        } else {
            NSString *filePath = [self filePathAsCreationDateWithInfo:info];
            [self deleteLocalFileIfExists:filePath];
            long long imageSize = imageData.length;
            if ([self hasFreeSpaceOnDiskForWriteFile:imageSize]) {
                NSError *error;
                if ([imageData writeToFile:filePath options:NSDataWritingFileProtectionNone error:&error]) {
                    NSDictionary *attributesDictionary = [NSDictionary dictionaryWithObject:self.asset.creationDate forKey:NSFileModificationDate];
                    if (![[NSFileManager defaultManager] setAttributes:attributesDictionary ofItemAtPath:filePath error:&error]) {
                        MEGALogError(@"Set attributes failed with error: %@", error);
                    }
                    if (self.filePath) {
                        filePath = [filePath stringByReplacingOccurrencesOfString:[NSHomeDirectory() stringByAppendingString:@"/"] withString:@""];
                        self.filePath(filePath);
                    }
                } else {
                    if (self.error) {
                        MEGALogError(@"Write to file failed with error %@", error);
                        self.error(error);
                    }
                }
            }
        }
    } else {
        NSError *error = [info objectForKey:@"PHImageErrorKey"];
        MEGALogError(@"Request image data for asset: %@ failed with error: %@", self.asset, error);
        if (self.retries < 20) {
            self.retries++;
            [self requestImageAsset];
        } else {
            if (self.error) {
                MEGALogDebug(@"Max attempts reached");
                self.error(error);
            }
        }
    }
}

@end
