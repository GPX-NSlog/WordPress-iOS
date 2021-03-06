#import "MediaService.h"
#import "AccountService.h"
#import "Media.h"
#import "WPAccount.h"
#import "ContextManager.h"
#import "Blog.h"
#import "UIImage+Resize.h"
#import <MobileCoreServices/MobileCoreServices.h>
#import "WordPress-Swift.h"
#import "WPXMLRPCDecoder.h"
#import <WordPressShared/WPImageSource.h>
#import "MediaService+Legacy.h"
#import <WordPressShared/WPAnalytics.h>
@import WordPressKit;
@import WordPressShared;

@interface MediaService ()

@property (nonatomic, strong) MediaThumbnailService *thumbnailService;

@end

@implementation MediaService

- (instancetype)initWithManagedObjectContext:(NSManagedObjectContext *)context
{
    self = [super initWithManagedObjectContext:context];
    if (self) {
        _concurrentThumbnailGeneration = NO;
    }
    return self;
}

#pragma mark - Creating media

- (void)createMediaWithURL:(NSURL *)url
           forPostObjectID:(NSManagedObjectID *)postObjectID
         thumbnailCallback:(void (^)(NSURL *thumbnailURL))thumbnailCallback
                completion:(void (^)(Media *media, NSError *error))completion
{
    NSString *mediaName = [[url pathComponents] lastObject];
    [self createMediaWith:url
                 objectID:postObjectID
                mediaName:mediaName
        thumbnailCallback:thumbnailCallback
               completion:completion
     ];
}

- (void)createMediaWithURL:(NSURL *)url
           forBlogObjectID:(NSManagedObjectID *)blogObjectID
         thumbnailCallback:(void (^)(NSURL *thumbnailURL))thumbnailCallback
                completion:(void (^)(Media *media, NSError *error))completion
{
    NSString *mediaName = [[url pathComponents] lastObject];
    [self createMediaWith:url
                 objectID:blogObjectID
                mediaName:mediaName
        thumbnailCallback:thumbnailCallback
               completion:completion
     ];
}

- (void)createMediaWithImage:(UIImage *)image
                 withMediaID:(NSString *)mediaID
             forPostObjectID:(NSManagedObjectID *)postObjectID
           thumbnailCallback:(void (^)(NSURL *thumbnailURL))thumbnailCallback
                  completion:(void (^)(Media *media, NSError *error))completion
{
    [self createMediaWith:image
                 objectID:postObjectID
                mediaName:mediaID
        thumbnailCallback:thumbnailCallback
               completion:completion
     ];
}

- (void)createMediaWithPHAsset:(PHAsset *)asset
               forPostObjectID:(NSManagedObjectID *)postObjectID
             thumbnailCallback:(void (^)(NSURL *thumbnailURL))thumbnailCallback
                    completion:(void (^)(Media *media, NSError *error))completion
{
    NSString *mediaName = [asset originalFilename];
    [self createMediaWith:asset
                 objectID:postObjectID
                mediaName:mediaName
        thumbnailCallback:thumbnailCallback
               completion:completion
     ];
}

- (void)createMediaWithPHAsset:(PHAsset *)asset
               forBlogObjectID:(NSManagedObjectID *)blogObjectID
             thumbnailCallback:(void (^)(NSURL *thumbnailURL))thumbnailCallback
                    completion:(void (^)(Media *media, NSError *error))completion
{
    NSString *mediaName = [asset originalFilename];
    [self createMediaWith:asset
                 objectID:blogObjectID
                mediaName:mediaName
        thumbnailCallback:thumbnailCallback
               completion:completion
     ];
}

- (void)createMediaWithImage:(UIImage *)image
             forBlogObjectID:(NSManagedObjectID *)blogObjectID
           thumbnailCallback:(void (^)(NSURL *thumbnailURL))thumbnailCallback
                  completion:(void (^)(Media *media, NSError *error))completion
{
    [self createMediaWith:image
                 objectID:blogObjectID
                mediaName:[[NSUUID UUID] UUIDString]
        thumbnailCallback:thumbnailCallback
               completion:completion];
}

#pragma mark - Private exporting

- (void)createMediaWith:(id<ExportableAsset>)exportable
               objectID:(NSManagedObjectID *)objectID
              mediaName:(NSString *)mediaName
      thumbnailCallback:(void (^)(NSURL *thumbnailURL))thumbnailCallback
             completion:(void (^)(Media *media, NSError *error))completion
{
    // Revert to legacy category methods if not using the new exporting services.
    if (![self supportsNewMediaExports]) {
        [self createMediaWith:exportable
                  forObjectID:objectID
                    mediaName:mediaName
            thumbnailCallback:thumbnailCallback
                   completion:completion];
        return;
    }

    // Use the new export services as indicated by the FeatureFlag.
    AbstractPost *post = nil;
    Blog *blog = nil;
    NSError *error = nil;
    NSManagedObject *existingObject = [self.managedObjectContext existingObjectWithID:objectID error:&error];
    if ([existingObject isKindOfClass:[AbstractPost class]]) {
        post = (AbstractPost *)existingObject;
        blog = post.blog;
    } else if ([existingObject isKindOfClass:[Blog class]]) {
        blog = (Blog *)existingObject;
    }
    if (!post && !blog) {
        if (completion) {
            completion(nil, error);
        }
        return;
    }

    Media *media;
    if (post != nil) {
        media = [Media makeMediaWithPost:post];
    } else {
        media = [Media makeMediaWithBlog:blog];
    }

    // Setup completion handlers
    void(^completionWithMedia)(Media *) = ^(Media *media) {
        // Pre-generate a thumbnail image, see the method notes.
        [self exportPlaceholderThumbnailForMedia:media
                                      completion:thumbnailCallback];
        if (completion) {
            completion(media, nil);
        }
    };
    void(^completionWithError)( NSError *) = ^(NSError *error) {
        if (completion) {
            completion(nil, error);
        }
    };

    // Export based on the type of the exportable.
    MediaImportService *importService = [[MediaImportService alloc] initWithManagedObjectContext:self.managedObjectContext];
    if ([exportable isKindOfClass:[PHAsset class]]) {
        [importService importAsset:(PHAsset *)exportable
                           toMedia:media
                      onCompletion:completionWithMedia
                           onError:completionWithError];
    } else if ([exportable isKindOfClass:[UIImage class]]) {
        [importService importImage:(UIImage *)exportable
                           toMedia:media
                      onCompletion:completionWithMedia
                           onError:completionWithError];
    } else if ([exportable isKindOfClass:[NSURL class]]) {
        [importService importURL:(NSURL *)exportable
                         toMedia:media
                    onCompletion:completionWithMedia
                         onError:completionWithError];
    } else {
        completionWithError(nil);
    }
}

/**
 Generate a thumbnail image for the Media asset so that consumers of the absoluteThumbnailLocalURL property
 will have an image ready to load, without using the async methods provided via MediaThumbnailService.
 
 This is primarily used as a placeholder image throughout the code-base, particulary within the editors.
 
 Note: Ideally we wouldn't need this at all, but the synchronous usage of absoluteThumbnailLocalURL across the code-base
       to load a thumbnail image is relied on quite heavily. In the future, transitioning to asynchronous thumbnail loading
       via the new thumbnail service methods is much preferred, but would indeed take a good bit of refactoring away from
       using absoluteThumbnailLocalURL.
*/
- (void)exportPlaceholderThumbnailForMedia:(Media *)media completion:(void (^)(NSURL *thumbnailURL))thumbnailCallback
{
    [self.thumbnailService thumbnailURLForMedia:media
                                  preferredSize:CGSizeZero
                                   onCompletion:^(NSURL *url) {
                                       [self.managedObjectContext performBlock:^{
                                           if (url) {
                                               // Set the absoluteThumbnailLocalURL with the generated thumbnail's URL.
                                               media.absoluteThumbnailLocalURL = url;
                                               [[ContextManager sharedInstance] saveContext:self.managedObjectContext];
                                           }
                                           if (thumbnailCallback) {
                                               thumbnailCallback(url);
                                           }
                                       }];
                                   }
                                        onError:^(NSError *error) {
                                            DDLogError(@"Error occurred exporting placeholder thumbnail: %@", error);
                                        }];
}

- (BOOL)supportsNewMediaExports
{
    return [Feature enabled:FeatureFlagNewMediaExports];
}

#pragma mark - Uploading media

- (void)uploadMedia:(Media *)media
           progress:(NSProgress **)progress
            success:(void (^)(void))success
            failure:(void (^)(NSError *error))failure
{
    Blog *blog = media.blog;
    id<MediaServiceRemote> remote = [self remoteForBlog:blog];
    RemoteMedia *remoteMedia = [self remoteMediaFromMedia:media];

    // Even though jpeg is a valid extension, use jpg instead for the widest possible
    // support.  Some third-party image related plugins prefer the .jpg extension.
    // See https://github.com/wordpress-mobile/WordPress-iOS/issues/4663
    remoteMedia.file = [remoteMedia.file stringByReplacingOccurrencesOfString:@".jpeg" withString:@".jpg"];

    media.remoteStatus = MediaRemoteStatusPushing;
    [[ContextManager sharedInstance] saveContext:self.managedObjectContext];
    NSManagedObjectID *mediaObjectID = media.objectID;
    void (^successBlock)(RemoteMedia *media) = ^(RemoteMedia *media) {
        [self.managedObjectContext performBlock:^{
            [WPAppAnalytics track:WPAnalyticsStatMediaServiceUploadSuccessful withBlog:blog];

            NSError * error = nil;
            Media *mediaInContext = (Media *)[self.managedObjectContext existingObjectWithID:mediaObjectID error:&error];
            if (!mediaInContext){
                DDLogError(@"Error retrieving media object: %@", error);
                if (failure){
                    failure(error);
                }
                return;
            }

            [self updateMedia:mediaInContext withRemoteMedia:media];
            [[ContextManager sharedInstance] saveContext:self.managedObjectContext withCompletionBlock:^{
                if (success) {
                    success();
                }
            }];
        }];
    };
    void (^failureBlock)(NSError *error) = ^(NSError *error) {
        [self.managedObjectContext performBlock:^{
            if (error) {
                [self trackUploadError:error];
            }

            Media *mediaInContext = (Media *)[self.managedObjectContext existingObjectWithID:mediaObjectID error:nil];
            if (mediaInContext) {
                mediaInContext.remoteStatus = MediaRemoteStatusFailed;
                [[ContextManager sharedInstance] saveContext:self.managedObjectContext];
            }
            if (failure) {
                failure([self customMediaUploadError:error remote:remote]);
            }
        }];
    };

    [WPAppAnalytics track:WPAnalyticsStatMediaServiceUploadStarted withBlog:blog];

    [remote uploadMedia:remoteMedia
               progress:progress
                success:successBlock
                failure:failureBlock];
}

#pragma mark - Private helpers

- (void)trackUploadError:(NSError *)error
{
    if (error.code == NSURLErrorCancelled) {
        [WPAppAnalytics track:WPAnalyticsStatMediaServiceUploadCanceled];
    } else {
        [WPAppAnalytics track:WPAnalyticsStatMediaServiceUploadFailed error:error];
    }
}

#pragma mark - Updating media

- (void)updateMedia:(Media *)media
            success:(void (^)(void))success
            failure:(void (^)(NSError *error))failure
{
    id<MediaServiceRemote> remote = [self remoteForBlog:media.blog];
    RemoteMedia *remoteMedia = [self remoteMediaFromMedia:media];
    NSManagedObjectID *mediaObjectID = media.objectID;
    void (^successBlock)(RemoteMedia *media) = ^(RemoteMedia *media) {
        [self.managedObjectContext performBlock:^{
            NSError * error = nil;
            Media *mediaInContext = (Media *)[self.managedObjectContext existingObjectWithID:mediaObjectID error:&error];
            if (!mediaInContext){
                DDLogError(@"Error updating media object: %@", error);
                if (failure){
                    failure(error);
                }
                return;
            }

            [self updateMedia:mediaInContext withRemoteMedia:media];
            [[ContextManager sharedInstance] saveContext:self.managedObjectContext withCompletionBlock:^{
                if (success) {
                    success();
                }
            }];
        }];
    };
    void (^failureBlock)(NSError *error) = ^(NSError *error) {
        [self.managedObjectContext performBlock:^{
            Media *mediaInContext = (Media *)[self.managedObjectContext existingObjectWithID:mediaObjectID error:nil];
            if (mediaInContext) {
                [[ContextManager sharedInstance] saveContext:self.managedObjectContext];
            }
            if (failure) {
                failure(error);
            }
        }];
    };

    [remote updateMedia:remoteMedia
                success:successBlock
                failure:failureBlock];
}

- (void)updateMedia:(NSArray<Media *> *)mediaObjects
     overallSuccess:(void (^)(void))overallSuccess
            failure:(void (^)(NSError *error))failure
{
    if (mediaObjects.count == 0) {
        if (overallSuccess) {
            overallSuccess();
        }
        return;
    }

    NSNumber *totalOperations = @(mediaObjects.count);
    __block NSUInteger completedOperations = 0;
    __block NSUInteger failedOperations = 0;

    void (^individualOperationCompletion)(BOOL success) = ^(BOOL success) {
        @synchronized (totalOperations) {
            completedOperations += 1;
            failedOperations += success ? 0 : 1;

            if (completedOperations >= totalOperations.unsignedIntegerValue) {
                if (overallSuccess && failedOperations != totalOperations.unsignedIntegerValue) {
                    overallSuccess();
                } else if (failure && failedOperations == totalOperations.unsignedIntegerValue) {
                    NSError *error = [NSError errorWithDomain:WordPressComRestApiErrorDomain
                                                         code:WordPressComRestApiErrorUnknown
                                                     userInfo:@{NSLocalizedDescriptionKey : NSLocalizedString(@"An error occurred when attempting to attach uploaded media to the post.", @"Error recorded when all of the media associated with a post fail to be attached to the post on the server.")}];
                    failure(error);
                }
            }
        }
    };

    for (Media *media in mediaObjects) {
        // This effectively ignores any errors presented
        [self updateMedia:media success:^{
            individualOperationCompletion(true);
        } failure:^(NSError *error) {
            individualOperationCompletion(false);
        }];
    }
}

#pragma mark - Private helpers

- (NSError *)customMediaUploadError:(NSError *)error remote:(id <MediaServiceRemote>)remote {
    NSString *customErrorMessage = nil;
    if ([remote isKindOfClass:[MediaServiceRemoteXMLRPC class]]) {
        // For self-hosted sites we should generally pass on the raw system/network error message.
        // Which should help debug issues with a self-hosted site.
        if ([error.domain isEqualToString:WPXMLRPCFaultErrorDomain]) {
            switch (error.code) {
                case 500:{
                    customErrorMessage = NSLocalizedString(@"Your site does not support this media file format.", @"Message to show to user when media upload failed because server doesn't support media type");
                } break;
                case 401:{
                    customErrorMessage = NSLocalizedString(@"Your site is out of storage space for media uploads.", @"Message to show to user when media upload failed because user doesn't have enough space on quota/disk");
                } break;
            }
        }
    } else if ([remote isKindOfClass:[MediaServiceRemoteREST class]]) {
        // For WPCom/Jetpack sites and NSURLErrors we should use a more general error message to encourage a user to try again,
        // rather than raw NSURLError messaging.
        if ([error.domain isEqualToString:NSURLErrorDomain]) {
            switch (error.code) {
                case NSURLErrorUnknown:
                    // Unknown error, encourage the user to try again
                    // Note: if support requests show up with this error message we can rule out known NSURLError codes
                    customErrorMessage = NSLocalizedString(@"An unknown error occurred. Please try again.", @"Error message shown when a media upload fails for unknown reason and the user should try again.");
                    break;
                case NSURLErrorNetworkConnectionLost:
                case NSURLErrorNotConnectedToInternet:
                    // Clear lack of device internet connection, notify the user
                    customErrorMessage = NSLocalizedString(@"The internet connection appears to be offline.", @"Error message shown when a media upload fails because the user isn't connected to the internet.");
                    break;
                default:
                    // Default NSURL error messaging, probably server-side, encourage user to try again
                    customErrorMessage = NSLocalizedString(@"Something went wrong. Please try again.", @"Error message shown when a media upload fails for a general network issue and the user should try again in a moment.");
                    break;
            }
        }
    }
    if (customErrorMessage) {
        NSMutableDictionary *userInfo = [error.userInfo mutableCopy];
        userInfo[NSLocalizedDescriptionKey] = customErrorMessage;
        error = [[NSError alloc] initWithDomain:error.domain code:error.code userInfo:userInfo];
    }
    return error;
}

#pragma mark - Deleting media

- (void)deleteMedia:(nonnull Media *)media
            success:(nullable void (^)(void))success
            failure:(nullable void (^)(NSError * _Nonnull error))failure
{
    id<MediaServiceRemote> remote = [self remoteForBlog:media.blog];
    RemoteMedia *remoteMedia = [self remoteMediaFromMedia:media];
    NSManagedObjectID *mediaObjectID = media.objectID;

    void (^successBlock)(void) = ^() {
        [self.managedObjectContext performBlock:^{
            Media *mediaInContext = (Media *)[self.managedObjectContext existingObjectWithID:mediaObjectID error:nil];
            [self.managedObjectContext deleteObject:mediaInContext];
            [[ContextManager sharedInstance] saveContext:self.managedObjectContext
                                     withCompletionBlock:^{
                                         if (success) {
                                             success();
                                         }
                                     }];
        }];
    };
    
    [remote deleteMedia:remoteMedia
                success:successBlock
                failure:failure];
}

- (void)deleteMedia:(nonnull NSArray<Media *> *)mediaObjects
           progress:(nullable void (^)(NSProgress *_Nonnull progress))progress
            success:(nullable void (^)(void))success
            failure:(nullable void (^)(void))failure
{
    if (mediaObjects.count == 0) {
        if (success) {
            success();
        }
        return;
    }

    NSProgress *currentProgress = [NSProgress progressWithTotalUnitCount:mediaObjects.count];

    dispatch_group_t group = dispatch_group_create();

    [mediaObjects enumerateObjectsUsingBlock:^(Media *media, NSUInteger idx, BOOL *stop) {
        dispatch_group_enter(group);
        [self deleteMedia:media success:^{
            currentProgress.completedUnitCount++;
            if (progress) {
                progress(currentProgress);
            }
            dispatch_group_leave(group);
        } failure:^(NSError *error) {
            dispatch_group_leave(group);
        }];
    }];

    // After all the operations have succeeded (or failed)
    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        if (currentProgress.completedUnitCount >= currentProgress.totalUnitCount) {
            if (success) {
                success();
            }
        } else {
            if (failure) {
                failure();
            }
        }
    });
}

#pragma mark - Getting media

- (void) getMediaWithID:(NSNumber *) mediaID inBlog:(Blog *) blog
            withSuccess:(void (^)(Media *media))success
                failure:(void (^)(NSError *error))failure
{
    id<MediaServiceRemote> remote = [self remoteForBlog:blog];
    NSManagedObjectID *blogID = blog.objectID;
    
    [remote getMediaWithID:mediaID success:^(RemoteMedia *remoteMedia) {
       [self.managedObjectContext performBlock:^{
           Blog *blog = (Blog *)[self.managedObjectContext existingObjectWithID:blogID error:nil];
           if (!blog) {
               return;
           }
           Media *media = [Media existingMediaWithMediaID:remoteMedia.mediaID inBlog:blog];
           if (!media) {
               media = [Media makeMediaWithBlog:blog];
           }
           [self updateMedia:media withRemoteMedia:remoteMedia];
           if (success){
               success(media);
           }
           [[ContextManager sharedInstance] saveDerivedContext:self.managedObjectContext];
       }];
    } failure:^(NSError *error) {
        if (failure) {
            [self.managedObjectContext performBlock:^{
                failure(error);
            }];
        }

    }];
}

- (void)getMediaURLFromVideoPressID:(NSString *)videoPressID
                             inBlog:(Blog *)blog
                            success:(void (^)(NSString *videoURL, NSString *posterURL))success
                            failure:(void (^)(NSError *error))failure
{
    id<MediaServiceRemote> remote = [self remoteForBlog:blog];
    [remote getVideoURLFromVideoPressID:videoPressID success:^(NSURL *videoURL, NSURL *posterURL) {
        if (success) {
            success(videoURL.absoluteString, posterURL.absoluteString);
        }
    } failure:^(NSError * error) {
        if (failure) {
            failure(error);
        }
    }];
}

- (void)syncMediaLibraryForBlog:(Blog *)blog
                        success:(void (^)(void))success
                        failure:(void (^)(NSError *error))failure
{
    id<MediaServiceRemote> remote = [self remoteForBlog:blog];
    NSManagedObjectID *blogObjectID = [blog objectID];
    [remote getMediaLibraryWithSuccess:^(NSArray *media) {
                               [self.managedObjectContext performBlock:^{
                                   Blog *blogInContext = (Blog *)[self.managedObjectContext objectWithID:blogObjectID];
                                   [self mergeMedia:media forBlog:blogInContext completionHandler:success];
                               }];
                           }
                           failure:^(NSError *error) {
                               if (failure) {
                                   [self.managedObjectContext performBlock:^{
                                       failure(error);
                                   }];
                               }
                           }];
}

- (NSInteger)getMediaLibraryCountForBlog:(Blog *)blog
                           forMediaTypes:(NSSet *)mediaTypes
{
    NSString *entityName = NSStringFromClass([Media class]);
    NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:entityName];
    request.predicate = [self predicateForMediaTypes:mediaTypes blog:blog];
    NSError *error;
    NSArray *mediaAssets = [self.managedObjectContext executeFetchRequest:request error:&error];
    return mediaAssets.count;
}

- (void)getMediaLibraryServerCountForBlog:(Blog *)blog
                            forMediaTypes:(NSSet *)mediaTypes
                                  success:(void (^)(NSInteger count))success
                                  failure:(void (^)(NSError *error))failure
{
    NSMutableSet *remainingMediaTypes = [NSMutableSet setWithSet:mediaTypes];
    NSNumber *currentMediaType = [mediaTypes anyObject];
    NSString *currentMimeType = nil;
    if (currentMediaType != nil) {
        currentMimeType = [self mimeTypeForMediaType:currentMediaType];
        [remainingMediaTypes removeObject:currentMediaType];
    }
    id<MediaServiceRemote> remote = [self remoteForBlog:blog];
    [remote getMediaLibraryCountForType:currentMimeType
                            withSuccess:^(NSInteger count) {
        if( remainingMediaTypes.count == 0) {
            if (success) {
                success(count);
            }
        } else {
            [self getMediaLibraryServerCountForBlog:blog forMediaTypes:remainingMediaTypes success:^(NSInteger otherCount) {
                if (success) {
                    success(count + otherCount);
                }
            } failure:^(NSError * _Nonnull error) {
                if (failure) {
                    failure(error);
                }
            }];
        }
    } failure:^(NSError *error) {
        if (failure) {
            failure(error);
        }
    }];
}

#pragma mark - Thumbnails

- (void)thumbnailFileURLForMedia:(Media *)mediaInRandomContext
                   preferredSize:(CGSize)preferredSize
                      completion:(void (^)(NSURL * _Nullable, NSError * _Nullable))completion
{
    NSManagedObjectID *mediaID = [mediaInRandomContext objectID];
    [self.managedObjectContext performBlock:^{
        /*
         When using the new Media export services, return the URL via the MediaThumbnailService.
         Otherwise, use the original implementation's `absoluteThumbnailLocalURL`.
         */
        Media *media = (Media *)[self.managedObjectContext objectWithID: mediaID];
        if ([self supportsNewMediaExports]) {
            [self.thumbnailService thumbnailURLForMedia:media
                                          preferredSize:preferredSize
                                           onCompletion:^(NSURL *url) {
                                               completion(url, nil);
                                           }
                                                onError:^(NSError *error) {
                                                    completion(nil, error);
                                                }];
        } else {
            completion(media.absoluteThumbnailLocalURL, nil);
        }
    }];
}

- (void)thumbnailImageForMedia:(nonnull Media *)mediaInRandomContext
                 preferredSize:(CGSize)preferredSize
                    completion:(void (^)(UIImage * _Nullable image, NSError * _Nullable error))completion
{
    NSManagedObjectID *mediaID = [mediaInRandomContext objectID];
    [self.managedObjectContext performBlock:^{
        /*
         When using the new Media export services, generate a thumbnail image from the URL
         of the MediaThumbnailService.
         Otherwise, use the legacy category method `imageForMedia:`.
         */
        Media *media = (Media *)[self.managedObjectContext objectWithID: mediaID];
        if ([self supportsNewMediaExports]) {
            [self.thumbnailService thumbnailURLForMedia:media
                                          preferredSize:preferredSize
                                           onCompletion:^(NSURL *url) {
                                               dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0),^{
                                                   UIImage *image = [UIImage imageWithContentsOfFile:url.path];
                                                   [self.managedObjectContext performBlock:^{
                                                       completion(image, nil);
                                                   }];
                                               });
                                           }
                                                onError:^(NSError *error) {
                                                    completion(nil, error);
                                                }];
        } else {
            [self imageForMedia:mediaInRandomContext
                           size:preferredSize
                        success:^(UIImage *image) {
                            completion(image, nil);
                        } failure:^(NSError *error) {
                            completion(nil, error);
                        }];
        }
    }];
}

- (MediaThumbnailService *)thumbnailService
{
    if (!_thumbnailService) {
        _thumbnailService = [[MediaThumbnailService alloc] initWithManagedObjectContext:self.managedObjectContext];
        if (self.concurrentThumbnailGeneration) {
            _thumbnailService.exportQueue = dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0);
        }
    }
    return _thumbnailService;
}

#pragma mark - Private helpers

- (NSString *)mimeTypeForMediaType:(NSNumber *)mediaType
{
    MediaType filter = (MediaType)[mediaType intValue];
    NSString *mimeType = [Media stringFromMediaType:filter];
    return mimeType;
}

- (NSPredicate *)predicateForMediaTypes:(NSSet *)mediaTypes blog:(Blog *)blog
{
    NSMutableArray * filters = [NSMutableArray array];
    [mediaTypes enumerateObjectsUsingBlock:^(NSNumber *obj, BOOL *stop){
        MediaType filter = (MediaType)[obj intValue];
        NSString *filterString = [Media stringFromMediaType:filter];
        [filters addObject:[NSString stringWithFormat:@"mediaTypeString == \"%@\"", filterString]];
    }];

    NSPredicate *predicate = [NSPredicate predicateWithFormat:@"blog == %@", blog];
    if (filters.count > 0) {
        NSString *mediaFilters = [filters componentsJoinedByString:@" || "];
        NSPredicate *mediaPredicate = [NSPredicate predicateWithFormat:mediaFilters];
        predicate = [NSCompoundPredicate andPredicateWithSubpredicates:
                     @[predicate, mediaPredicate]];
    }

    return predicate;
}

#pragma mark - Media helpers

- (id<MediaServiceRemote>)remoteForBlog:(Blog *)blog
{
    id <MediaServiceRemote> remote;
    if ([blog supports:BlogFeatureWPComRESTAPI]) {
        if (blog.wordPressComRestApi) {
            remote = [[MediaServiceRemoteREST alloc] initWithWordPressComRestApi:blog.wordPressComRestApi
                                                                          siteID:blog.dotComID];
        }
    } else if (blog.xmlrpcApi) {
        remote = [[MediaServiceRemoteXMLRPC alloc] initWithApi:blog.xmlrpcApi username:blog.username password:blog.password];
    }
    return remote;
}

- (void)mergeMedia:(NSArray *)media
           forBlog:(Blog *)blog
 completionHandler:(void (^)(void))completion
{
    NSParameterAssert(blog);
    NSParameterAssert(media);
    NSMutableSet *mediaToKeep = [NSMutableSet set];
    for (RemoteMedia *remote in media) {
        @autoreleasepool {
            Media *local = [Media existingMediaWithMediaID:remote.mediaID inBlog:blog];
            if (!local) {
                local = [Media makeMediaWithBlog:blog];                
            }
            [self updateMedia:local withRemoteMedia:remote];
            [mediaToKeep addObject:local];
        }
    }
    NSMutableSet *mediaToDelete = [NSMutableSet setWithSet:blog.media];
    [mediaToDelete minusSet:mediaToKeep];
    for (Media *deleteMedia in mediaToDelete) {
        // only delete media that is server based
        if ([deleteMedia.mediaID intValue] > 0) {
            [self.managedObjectContext deleteObject:deleteMedia];
        }
    }
    NSError *error;
    if (![self.managedObjectContext save:&error]){
        DDLogError(@"Error saving context afer adding media %@", [error localizedDescription]);
    }
    if (completion) {
        completion();
    }
}

- (void)updateMedia:(Media *)media withRemoteMedia:(RemoteMedia *)remoteMedia
{
    media.mediaID =  remoteMedia.mediaID;
    media.remoteURL = [remoteMedia.url absoluteString];
    if (remoteMedia.date) {
        media.creationDate = remoteMedia.date;
    }
    media.filename = remoteMedia.file;
    if (remoteMedia.mimeType.length > 0) {
        [media setMediaTypeForMimeType:remoteMedia.mimeType];
    } else if (remoteMedia.extension.length > 0) {
        [media setMediaTypeForExtension:remoteMedia.extension];
    }
    media.title = remoteMedia.title;
    media.caption = remoteMedia.caption;
    media.desc = remoteMedia.descriptionText;
    media.alt = remoteMedia.alt;
    media.height = remoteMedia.height;
    media.width = remoteMedia.width;
    media.shortcode = remoteMedia.shortcode;
    media.videopressGUID = remoteMedia.videopressGUID;
    media.length = remoteMedia.length;
    media.remoteThumbnailURL = remoteMedia.remoteThumbnailURL;
    media.postID = remoteMedia.postID;

    media.remoteStatus = MediaRemoteStatusSync;
}

- (RemoteMedia *)remoteMediaFromMedia:(Media *)media
{
    RemoteMedia *remoteMedia = [[RemoteMedia alloc] init];
    remoteMedia.mediaID = media.mediaID;
    remoteMedia.url = [NSURL URLWithString:media.remoteURL];
    remoteMedia.date = media.creationDate;
    remoteMedia.file = media.filename;
    remoteMedia.extension = [media fileExtension] ?: @"unknown";
    remoteMedia.title = media.title;
    remoteMedia.caption = media.caption;
    remoteMedia.descriptionText = media.desc;
    remoteMedia.alt = media.alt;
    remoteMedia.height = media.height;
    remoteMedia.width = media.width;
    remoteMedia.localURL = media.absoluteLocalURL;
    remoteMedia.mimeType = [media mimeType];
	remoteMedia.videopressGUID = media.videopressGUID;
    remoteMedia.remoteThumbnailURL = media.remoteThumbnailURL;
    remoteMedia.postID = media.postID;
    return remoteMedia;
}

@end
