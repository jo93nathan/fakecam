#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
#import <Photos/Photos.h>
#import <objc/runtime.h>
#import <notify.h>

/*
 * FakeCam v8
 * ----------
 * - Remplace l'aperçu de l'app Camera par une PHOTO ou une VIDÉO choisie dans l'app FakeCam.
 * - Le média est toujours recadré (aspect-fill) à la taille réelle de l'aperçu :
 *   il s'adapte tout seul à chaque mode (Photo 4:3, Vidéo 16:9, Carré 1:1...).
 * - NOUVEAU : au déclenchement, la photo enregistrée est EXACTEMENT la vue affichée à
 *   l'écran (même recadrage, zoom, rotation, décalage, filtre et image vidéo courante),
 *   et non l'image du capteur réel. Vaut aussi pour la vignette affichée par Camera.
 * - Réglages de l'app (zoom, rotation, position, filtre) lus dans settings.plist.
 * - Pinch = zoom, drag = recentrage dans l'Appareil photo ; volume +/- = zoom.
 * - Notification Darwin : l'app prévient le tweak, qui recharge aussitôt.
 */

static NSString * const kFakeCamReloadNote = @"com.lemaso.fakecam.reload";
static CGFloat    const kFCMaxPixel        = 2048.0;

// Dossiers partagés avec l'app FakeCam (le premier qui contient le fichier gagne).
static NSArray<NSString *> *FCSharedDirs(void) {
    return @[@"/var/jb/var/mobile/Library/FakeCam", @"/var/mobile/Media/FakeCam"];
}

static char kFCImageLayerKey;
static char kFCVideoLayerKey;
static char kFCAudioContext;

static __weak AVCaptureVideoPreviewLayer *FCPreviewLayer = nil;
static __weak CALayer *FCActiveLayer = nil;
static __weak UIViewController *FCHostVC = nil;

// État chargé depuis le disque
static BOOL FCStateLoaded = NO;
static BOOL FCDisabledCached = NO;
static UIImage *FCCachedImage = nil;          // image filtrée (nil si vidéo / rien)
static NSString *FCVideoPath = nil;           // chemin de la vidéo (nil si image)
static NSString *FCImageKey = nil;            // cache du rendu image
static double FCVideoMTime = 0;
static NSInteger FCFilter = 0;
static CGFloat FCZoom0 = 1.0, FCRot0 = 0.0, FCOffX = 0.0, FCOffY = 0.0; // réglages de l'app

// Gestes dans l'Appareil photo
static CGFloat FCScale = 1.0;
static CGPoint FCTranslation = {0, 0};
static CGFloat FCBeginScale = 1.0;
static CGPoint FCBeginTranslation = {0, 0};
static double FCStateMTime = 0;
static float FCLastVolume = -1.0f;

// Lecteur vidéo
static AVPlayer *FCPlayer = nil;
static NSString *FCPlayerKey = nil;
static id FCEndObserver = nil;

#pragma mark - Fichiers / état

static NSString *FCDocumentsDir(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    return [paths firstObject];
}
static NSString *FCStatePath(void) { return [FCDocumentsDir() stringByAppendingPathComponent:@"fakecam.state.plist"]; }

static void FCSaveTransform(void) {
    NSDictionary *d = @{@"scale": @(FCScale), @"tx": @(FCTranslation.x), @"ty": @(FCTranslation.y),
                        @"mtime": @(FCStateMTime)};
    [d writeToFile:FCStatePath() atomically:YES];
}

static void FCLoadTransform(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:FCStatePath()];
    if (!d) return;
    double sc = [d[@"scale"] doubleValue];
    FCScale = sc >= 1.0 ? sc : 1.0;
    FCTranslation = CGPointMake([d[@"tx"] doubleValue], [d[@"ty"] doubleValue]);
    FCStateMTime = [d[@"mtime"] doubleValue];
}

// Redresse l'image (EXIF) et la réduit : CALayer ignore imageOrientation
// et une photo 12 MP en plein écran fait exploser la mémoire de Camera.
static UIImage *FCNormalizedImage(UIImage *src) {
    if (!src || !src.CGImage) return nil;
    CGSize s = src.size;
    CGFloat maxSide = MAX(s.width, s.height);
    if (maxSide <= 0) return nil;
    CGFloat ratio = maxSide > kFCMaxPixel ? kFCMaxPixel / maxSide : 1.0;
    if (ratio == 1.0 && src.imageOrientation == UIImageOrientationUp) return src;

    CGSize target = CGSizeMake(floor(s.width * ratio), floor(s.height * ratio));
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat preferredFormat];
    fmt.scale = 1.0;
    fmt.opaque = YES;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:target format:fmt];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [src drawInRect:CGRectMake(0, 0, target.width, target.height)];
    }];
}

#pragma mark - Filtres (mêmes réglages que l'app)

static CIFilter *FCMakeFilter(NSInteger idx) {
    CIFilter *f = nil;
    switch (idx) {
        case 1: f = [CIFilter filterWithName:@"CIPhotoEffectMono"]; break;
        case 2: f = [CIFilter filterWithName:@"CIPhotoEffectNoir"]; break;
        case 3: f = [CIFilter filterWithName:@"CISepiaTone"]; [f setValue:@0.9 forKey:kCIInputIntensityKey]; break;
        case 4: f = [CIFilter filterWithName:@"CIPhotoEffectChrome"]; break;
        case 5: f = [CIFilter filterWithName:@"CIPhotoEffectInstant"]; break;
        case 6: f = [CIFilter filterWithName:@"CIColorControls"];
                [f setValue:@1.5 forKey:kCIInputSaturationKey];
                [f setValue:@1.1 forKey:kCIInputContrastKey]; break;
        case 7:
        case 8: {
            BOOL warm = (idx == 7);
            f = [CIFilter filterWithName:@"CIColorMatrix"];
            [f setValue:[CIVector vectorWithX:(warm ? 1.12 : 0.9) Y:0 Z:0 W:0] forKey:@"inputRVector"];
            [f setValue:[CIVector vectorWithX:0 Y:1 Z:0 W:0] forKey:@"inputGVector"];
            [f setValue:[CIVector vectorWithX:0 Y:0 Z:(warm ? 0.88 : 1.12) W:0] forKey:@"inputBVector"];
            [f setValue:[CIVector vectorWithX:0 Y:0 Z:0 W:1] forKey:@"inputAVector"];
            break;
        }
        default: break;
    }
    return f;
}

static UIImage *FCApplyFilter(UIImage *img, NSInteger idx) {
    if (!img || idx <= 0) return img;
    CIImage *ci = [[CIImage alloc] initWithImage:img];
    CIFilter *f = FCMakeFilter(idx);
    if (!ci || !f) return img;
    [f setValue:ci forKey:kCIInputImageKey];
    CIImage *out = f.outputImage;
    if (!out) return img;

    static CIContext *context;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ context = [CIContext contextWithOptions:nil]; });
    CGImageRef cg = [context createCGImage:out fromRect:ci.extent];
    if (!cg) return img;
    UIImage *res = [UIImage imageWithCGImage:cg];
    CGImageRelease(cg);
    return res;
}

#pragma mark - Chargement

// Lit le disque (et à chaque notification), pas à chaque layout / geste.
static void FCReloadState(void) {
    BOOL first = !FCStateLoaded;
    NSFileManager *fm = [NSFileManager defaultManager];

    BOOL disabled = NO;
    NSString *videoPath = nil, *imagePath = nil, *settingsPath = nil;
    for (NSString *dir in FCSharedDirs()) {
        if ([fm fileExistsAtPath:[dir stringByAppendingPathComponent:@"disabled"]]) disabled = YES;
        NSString *v = [dir stringByAppendingPathComponent:@"video.mp4"];
        if (!videoPath && [fm fileExistsAtPath:v]) videoPath = v;
        for (NSString *name in @[@"original.jpg", @"fake.jpg"]) {
            NSString *c = [dir stringByAppendingPathComponent:name];
            if (!imagePath && [fm fileExistsAtPath:c]) imagePath = c;
        }
        NSString *s = [dir stringByAppendingPathComponent:@"settings.plist"];
        if (!settingsPath && [fm fileExistsAtPath:s]) settingsPath = s;
    }
    FCDisabledCached = disabled;

    // Réglages de l'app
    FCZoom0 = 1.0; FCRot0 = 0.0; FCOffX = 0.0; FCOffY = 0.0; FCFilter = 0;
    double settingsMTime = 0;
    if (settingsPath) {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:settingsPath];
        double z = [d[@"zoom"] doubleValue];
        FCZoom0 = z >= 1.0 ? z : 1.0;
        FCRot0 = [d[@"rot"] doubleValue];
        FCOffX = [d[@"x"] doubleValue];
        FCOffY = [d[@"y"] doubleValue];
        FCFilter = [d[@"filter"] integerValue];
        settingsMTime = [[fm attributesOfItemAtPath:settingsPath error:nil][NSFileModificationDate] timeIntervalSince1970];
    }

    NSString *mediaPath = videoPath ?: imagePath;
    double mediaMTime = 0;
    if (mediaPath) {
        mediaMTime = [[fm attributesOfItemAtPath:mediaPath error:nil][NSFileModificationDate] timeIntervalSince1970];
    }

    if (videoPath) {
        FCVideoPath = videoPath;
        FCVideoMTime = mediaMTime;
        FCCachedImage = nil;
        FCImageKey = nil;
    } else {
        FCVideoPath = nil;
        NSString *key = imagePath ? [NSString stringWithFormat:@"%@|%.0f|%ld", imagePath, mediaMTime, (long)FCFilter] : nil;
        if (![key isEqualToString:FCImageKey] || (!key && FCCachedImage)) {
            FCImageKey = key;
            UIImage *raw = imagePath ? [UIImage imageWithContentsOfFile:imagePath] : nil;
            FCCachedImage = FCApplyFilter(FCNormalizedImage(raw), FCFilter);
        }
    }

    FCStateLoaded = YES;
    if (first) FCLoadTransform();

    // Nouveau média ou nouveaux réglages venant de l'app = gestes remis à zéro.
    double stamp = mediaMTime + settingsMTime;
    if (fabs(stamp - FCStateMTime) > 0.5) {
        FCStateMTime = stamp;
        FCScale = 1.0;
        FCTranslation = CGPointZero;
        FCSaveTransform();
    }
}

static BOOL FCIsDisabled(void) {
    if (!FCStateLoaded) FCReloadState();
    return FCDisabledCached;
}

#pragma mark - Géométrie

// Réglages de l'app : recadrage + zoom + rotation + décalage, centrés sur l'aperçu.
static CGAffineTransform FCBaseTransform(CGSize b) {
    CGFloat w = b.width, h = b.height;
    CGFloat th = FCRot0 * M_PI / 180.0;
    // Échelle minimale pour que le cadre tourné couvre tout l'aperçu (pas de bord noir).
    CGFloat kw = (w * fabs(cos(th)) + h * fabs(sin(th))) / w;
    CGFloat kh = (w * fabs(sin(th)) + h * fabs(cos(th))) / h;
    CGFloat k = MAX(kw, kh) * FCZoom0;

    CGAffineTransform t = CGAffineTransformMakeTranslation(FCOffX * w / 2.0, FCOffY * h / 2.0);
    t = CGAffineTransformRotate(t, th);
    t = CGAffineTransformScale(t, k, k);
    return t;
}

static void FCClampTransform(void) {
    AVCaptureVideoPreviewLayer *preview = FCPreviewLayer;
    if (!preview) return;
    CGSize b = preview.bounds.size;
    if (b.width <= 0 || b.height <= 0) return;

    FCScale = MIN(4.0, MAX(1.0, FCScale));
    CGFloat maxX = MAX(0, (b.width  * FCScale - b.width)  / 2.0);
    CGFloat maxY = MAX(0, (b.height * FCScale - b.height) / 2.0);
    FCTranslation.x = MIN(maxX, MAX(-maxX, FCTranslation.x));
    FCTranslation.y = MIN(maxY, MAX(-maxY, FCTranslation.y));
}

static void FCApplyTransform(void) {
    FCClampTransform();
    AVCaptureVideoPreviewLayer *preview = FCPreviewLayer;
    CALayer *layer = FCActiveLayer;
    if (!preview || !layer) return;

    CGAffineTransform gesture = CGAffineTransformMake(FCScale, 0, 0, FCScale, FCTranslation.x, FCTranslation.y);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    layer.affineTransform = CGAffineTransformConcat(FCBaseTransform(preview.bounds.size), gesture);
    [CATransaction commit];
}

#pragma mark - Vidéo

static void FCStopPlayer(void) {
    [FCPlayer pause];
}

static void FCEnsurePlayer(void) {
    if (!FCVideoPath) return;
    NSString *key = [NSString stringWithFormat:@"%@|%.0f|%ld", FCVideoPath, FCVideoMTime, (long)FCFilter];
    if (FCPlayer && [key isEqualToString:FCPlayerKey]) {
        if (FCPlayer.rate == 0) [FCPlayer play];
        return;
    }
    FCPlayerKey = key;
    if (FCEndObserver) {
        [[NSNotificationCenter defaultCenter] removeObserver:FCEndObserver];
        FCEndObserver = nil;
    }

    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:FCVideoPath] options:nil];
    AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:asset];
    NSInteger filter = FCFilter;
    if (filter > 0) {
        item.videoComposition = [AVVideoComposition videoCompositionWithAsset:asset
                                                 applyingCIFiltersWithHandler:^(AVAsynchronousCIImageFilteringRequest *request) {
            CIFilter *f = FCMakeFilter(filter);
            if (!f) { [request finishWithImage:request.sourceImage context:nil]; return; }
            [f setValue:[request.sourceImage imageByClampingToExtent] forKey:kCIInputImageKey];
            CIImage *out = [f.outputImage imageByCroppingToRect:request.sourceImage.extent];
            [request finishWithImage:(out ?: request.sourceImage) context:nil];
        }];
    }

    if (!FCPlayer) {
        FCPlayer = [AVPlayer playerWithPlayerItem:item];
        FCPlayer.muted = YES;
        FCPlayer.actionAtItemEnd = AVPlayerActionAtItemEndNone;
        FCPlayer.automaticallyWaitsToMinimizeStalling = NO;
    } else {
        [FCPlayer replaceCurrentItemWithPlayerItem:item];
    }

    // Lecture en boucle
    FCEndObserver = [[NSNotificationCenter defaultCenter]
        addObserverForName:AVPlayerItemDidPlayToEndTimeNotification object:item queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
        [FCPlayer seekToTime:kCMTimeZero];
        [FCPlayer play];
    }];
    [FCPlayer play];
}

#pragma mark - Photo enregistrée = vue affichée

// Image figée au moment du déclenchement (une seule fois par photo, pour garder
// exactement ce que l'utilisateur avait à l'écran, même si l'aperçu bouge ensuite).
static UIImage *FCCaptureImage = nil;
static NSDate *FCCaptureDate = nil;

static void FCClearCaptureImage(void) {
    FCCaptureImage = nil;
    FCCaptureDate = nil;
}

static UIImage *FCRenderDisplayedImage(void);

// Rendu sur le main thread, avec timeout pour ne jamais bloquer Camera.
static UIImage *FCRenderOnMain(void) {
    if ([NSThread isMainThread]) return FCRenderDisplayedImage();
    __block UIImage *shot = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_main_queue(), ^{
        shot = FCRenderDisplayedImage();
        dispatch_semaphore_signal(sem);
    });
    dispatch_time_t limit = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC));
    if (dispatch_semaphore_wait(sem, limit) != 0) return nil;
    return shot;
}

// Image de la vidéo à l'instant T (le calque AVPlayer ne se rend pas dans un contexte).
static UIImage *FCCurrentVideoFrame(void) {
    AVPlayerItem *item = FCPlayer.currentItem;
    AVAsset *asset = item.asset;
    if (!asset) return nil;

    AVAssetImageGenerator *gen = [[AVAssetImageGenerator alloc] initWithAsset:asset];
    gen.appliesPreferredTrackTransform = YES;
    gen.maximumSize = CGSizeMake(kFCMaxPixel, kFCMaxPixel);
    CMTime t = item.currentTime;
    if (!CMTIME_IS_VALID(t)) t = kCMTimeZero;

    NSError *err = nil;
    CGImageRef cg = [gen copyCGImageAtTime:t actualTime:NULL error:&err];
    if (!cg) return nil;
    UIImage *frame = [UIImage imageWithCGImage:cg];
    CGImageRelease(cg);
    return FCApplyFilter(frame, FCFilter);
}

// Rendu de l'aperçu tel qu'affiché. -[CALayer renderInContext:] ignore la position et
// l'affineTransform du calque qu'on lui donne (zoom / rotation / décalage perdus) :
// on dessine donc l'image nous-mêmes, avec exactement la même géométrie que le calque
// installé dans FCUpdateLayer (aspect-fill dans les bounds, puis affineTransform autour du centre).
static UIImage *FCRenderDisplayedImage(void) {
    AVCaptureVideoPreviewLayer *preview = FCPreviewLayer;
    CALayer *active = FCActiveLayer;
    CGSize viewport = preview ? preview.bounds.size : CGSizeZero;
    if (!active || viewport.width <= 0 || viewport.height <= 0) return nil;

    UIImage *source = FCVideoPath ? FCCurrentVideoFrame() : FCCachedImage;
    if (!source || !source.CGImage) return nil;

    CGSize layerSize = active.bounds.size;
    CGSize imgSize = source.size;
    if (layerSize.width <= 0 || layerSize.height <= 0 || imgSize.width <= 0 || imgSize.height <= 0) return nil;

    CGFloat fill = MAX(layerSize.width / imgSize.width, layerSize.height / imgSize.height);
    CGSize drawn = CGSizeMake(imgSize.width * fill, imgSize.height * fill);
    CGRect imageRect = CGRectMake((layerSize.width - drawn.width) / 2.0,
                                  (layerSize.height - drawn.height) / 2.0,
                                  drawn.width, drawn.height);
    CGPoint position = active.position;
    CGAffineTransform transform = active.affineTransform;

    CGFloat scale = MAX([UIScreen mainScreen].scale, kFCMaxPixel / MAX(viewport.width, viewport.height));
    if (scale > 4.0) scale = 4.0;
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat preferredFormat];
    fmt.scale = scale;
    fmt.opaque = YES;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:viewport format:fmt];

    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGContextRef c = ctx.CGContext;
        CGContextSetFillColorWithColor(c, [UIColor blackColor].CGColor);
        CGContextFillRect(c, CGRectMake(0, 0, viewport.width, viewport.height));

        CGContextTranslateCTM(c, position.x, position.y);
        CGContextConcatCTM(c, transform);
        CGContextTranslateCTM(c, -layerSize.width / 2.0, -layerSize.height / 2.0);
        CGContextClipToRect(c, CGRectMake(0, 0, layerSize.width, layerSize.height));
        [source drawInRect:imageRect];
    }];
}

static UIImage *FCFakeCaptureImage(void) {
    if (FCCaptureImage && FCCaptureDate && -[FCCaptureDate timeIntervalSinceNow] < 5.0) {
        return FCCaptureImage;
    }
    // Filet de sécurité : si le hook de capture n'a pas pu figer l'image, on la
    // rend à la demande (uniquement sur le main thread, pour éviter tout blocage).
    if ([NSThread isMainThread] && !FCIsDisabled() && FCPreviewLayer && FCActiveLayer) {
        UIImage *shot = FCRenderDisplayedImage();
        if (shot) {
            FCCaptureImage = shot;
            FCCaptureDate = [NSDate date];
            return shot;
        }
    }
    return nil;
}

// On garde le conteneur d'origine (JPEG ou HEIC) pour ne pas perturber Photos.
static BOOL FCOriginalWasHEIF(NSData *data) {
    if (data.length < 12) return NO;
    const unsigned char *b = (const unsigned char *)data.bytes;
    if (b[0] == 0xFF && b[1] == 0xD8) return NO; // JPEG
    if (b[4] == 'f' && b[5] == 't' && b[6] == 'y' && b[7] == 'p') return YES;
    return NO;
}

static NSData *FCEncodeFakeImage(UIImage *img, BOOL heic) {
    if (!img) return nil;
    CFMutableDataRef data = CFDataCreateMutable(kCFAllocatorDefault, 0);
    if (!data) return nil;
    CGImageDestinationRef dest = NULL;
    if (heic) dest = CGImageDestinationCreateWithData(data, (__bridge CFStringRef)AVFileTypeHEIC, 1, NULL);
    if (!dest) { // JPEG par défaut, et si l'encodage HEIC n'est pas disponible
        dest = CGImageDestinationCreateWithData(data, (__bridge CFStringRef)AVFileTypeJPEG, 1, NULL);
    }
    if (!dest) { CFRelease(data); return nil; }
    NSDictionary *props = @{(__bridge NSString *)kCGImageDestinationLossyCompressionQuality: @0.95};
    CGImageDestinationAddImage(dest, img.CGImage, (__bridge CFDictionaryRef)props);
    BOOL ok = CGImageDestinationFinalize(dest);
    CFRelease(dest);
    if (!ok) { CFRelease(data); return nil; }
    return CFBridgingRelease(data);
}

static NSData *FCFakePhotoData(NSData *originalData) {
    UIImage *img = FCFakeCaptureImage();
    return img ? FCEncodeFakeImage(img, FCOriginalWasHEIF(originalData)) : nil;
}

static CGImageRef FCFakePhotoCGImage(void) {
    UIImage *img = FCFakeCaptureImage();
    // CGImageRepresentation / previewCGImageRepresentation ne transfèrent pas la propriété :
    // l'appelant ne libère pas, donc on renvoie un +1 autoreleasé (sinon fuite à chaque photo).
    return img ? (CGImageRef)CFAutorelease(CGImageRetain(img.CGImage)) : NULL;
}

#pragma mark - Calque factice

static void FCStartObserverOnce(void);

static void FCUpdateLayer(AVCaptureVideoPreviewLayer *preview) {
    if (!preview) return;
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ FCUpdateLayer(preview); });
        return;
    }

    CGRect b = preview.bounds;
    if (b.size.width <= 0 || b.size.height <= 0) return;

    FCStartObserverOnce();
    FCPreviewLayer = preview;
    if (!FCStateLoaded) FCReloadState();

    CALayer *imageLayer = objc_getAssociatedObject(preview, &kFCImageLayerKey);
    AVPlayerLayer *videoLayer = objc_getAssociatedObject(preview, &kFCVideoLayerKey);

    BOOL showVideo = !FCDisabledCached && FCVideoPath != nil;
    BOOL showImage = !FCDisabledCached && FCVideoPath == nil && FCCachedImage != nil;

    if (!showVideo) FCStopPlayer();
    if (!showVideo && videoLayer.superlayer) [videoLayer removeFromSuperlayer];
    if (!showImage && imageLayer.superlayer) [imageLayer removeFromSuperlayer];
    if (!showVideo && !showImage) { FCActiveLayer = nil; return; }

    CALayer *target = nil;
    if (showVideo) {
        if (!videoLayer) {
            FCEnsurePlayer();
            videoLayer = [AVPlayerLayer playerLayerWithPlayer:FCPlayer];
            videoLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
            videoLayer.zPosition = CGFLOAT_MAX;
            objc_setAssociatedObject(preview, &kFCVideoLayerKey, videoLayer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        FCEnsurePlayer();
        if (videoLayer.player != FCPlayer) videoLayer.player = FCPlayer;
        target = videoLayer;
    } else {
        if (!imageLayer) {
            imageLayer = [CALayer layer];
            imageLayer.contentsGravity = kCAGravityResizeAspectFill; // recadrage auto à la taille de l'aperçu
            imageLayer.masksToBounds = YES;
            imageLayer.zPosition = CGFLOAT_MAX;
            objc_setAssociatedObject(preview, &kFCImageLayerKey, imageLayer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        id contents = (__bridge id)FCCachedImage.CGImage;
        if (imageLayer.contents != contents) imageLayer.contents = contents;
        target = imageLayer;
    }

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    preview.masksToBounds = YES;
    // bounds + position (jamais "frame" : indéfini quand une transform est appliquée)
    target.bounds = CGRectMake(0, 0, b.size.width, b.size.height);
    target.position = CGPointMake(CGRectGetMidX(b), CGRectGetMidY(b));
    if (target.superlayer != preview) [preview addSublayer:target];
    [CATransaction commit];

    FCActiveLayer = target;
    FCApplyTransform();
}

static AVCaptureVideoPreviewLayer *FCFindPreviewLayer(CALayer *layer) {
    if ([layer isKindOfClass:[AVCaptureVideoPreviewLayer class]]) {
        return (AVCaptureVideoPreviewLayer *)layer;
    }
    for (CALayer *sub in layer.sublayers) {
        AVCaptureVideoPreviewLayer *found = FCFindPreviewLayer(sub);
        if (found) return found;
    }
    return nil;
}

#pragma mark - Contrôleur (gestes, volume, notifications)

@interface FCObserver : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)shared;
- (void)start;
- (void)fc_changed;
- (void)handlePinch:(UIPinchGestureRecognizer *)g;
- (void)handlePan:(UIPanGestureRecognizer *)g;
@end

static void FCDarwinCallback(CFNotificationCenterRef center, void *observer, CFNotificationName name,
                             const void *object, CFDictionaryRef userInfo) {
    [[FCObserver shared] fc_changed];
}

@implementation FCObserver

+ (instancetype)shared {
    static FCObserver *obj;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ obj = [[FCObserver alloc] init]; });
    return obj;
}

- (void)start {
    // Notification envoyée par l'app FakeCam quand le média / les réglages changent.
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, FCDarwinCallback,
                                    (__bridge CFStringRef)kFakeCamReloadNote, NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
    // Camera suspendue pendant le changement : on recharge aussi au retour au premier plan.
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(fc_changed)
                                                 name:UIApplicationDidBecomeActiveNotification
                                               object:nil];

    AVAudioSession *session = [AVAudioSession sharedInstance];
    FCLastVolume = session.outputVolume;
    // NB : sans NSKeyValueObservingOptionNew, change[NewKey] est nil -> volume = 0 (bug v3)
    [session addObserver:self
              forKeyPath:@"outputVolume"
                 options:NSKeyValueObservingOptionNew
                 context:&kFCAudioContext];
}

- (void)fc_changed {
    dispatch_async(dispatch_get_main_queue(), ^{
        FCReloadState();
        FCUpdateLayer(FCPreviewLayer);
    });
}

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary *)change
                       context:(void *)context {
    if (context != &kFCAudioContext) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    float volume = [change[NSKeyValueChangeNewKey] floatValue];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (FCLastVolume >= 0.0f && FCPreviewLayer && !FCIsDisabled()) {
            if (volume > FCLastVolume + 0.001f)      FCScale *= 1.15;
            else if (volume < FCLastVolume - 0.001f) FCScale /= 1.15;
            FCApplyTransform();
            FCSaveTransform();
        }
        FCLastVolume = volume;
    });
}

- (void)handlePinch:(UIPinchGestureRecognizer *)g {
    if (!FCPreviewLayer || FCIsDisabled()) return;
    if (g.state == UIGestureRecognizerStateBegan) {
        FCBeginScale = FCScale;
    } else if (g.state == UIGestureRecognizerStateChanged) {
        FCScale = FCBeginScale * g.scale;
        FCApplyTransform();
    } else if (g.state == UIGestureRecognizerStateEnded) {
        FCSaveTransform();
    }
}

- (void)handlePan:(UIPanGestureRecognizer *)g {
    if (!FCPreviewLayer || FCIsDisabled()) return;
    if (g.state == UIGestureRecognizerStateBegan) {
        FCBeginTranslation = FCTranslation;
    } else if (g.state == UIGestureRecognizerStateChanged) {
        CGPoint delta = [g translationInView:g.view];
        FCTranslation = CGPointMake(FCBeginTranslation.x + delta.x,
                                    FCBeginTranslation.y + delta.y);
        FCApplyTransform();
    } else if (g.state == UIGestureRecognizerStateEnded) {
        FCSaveTransform();
    }
}

// Laisse Camera garder ses propres gestes (zoom natif, swipe de mode...).
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g
shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return YES;
}

@end

static void FCStartObserverOnce(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ [[FCObserver shared] start]; });
}

#pragma mark - Hook : aperçu caméra

%hook AVCaptureVideoPreviewLayer

- (void)setSession:(AVCaptureSession *)session {
    %orig;
    FCUpdateLayer(self);
}

// Appelé à chaque changement de taille (changement de mode Photo / Vidéo / Carré...).
- (void)layoutSublayers {
    %orig;
    FCUpdateLayer(self);
}

%end

#pragma mark - Hook : enregistrement de la photo

%hook AVCapturePhotoOutput

// On fige la vue affichée au moment précis où Camera demande la photo.
- (void)capturePhotoWithSettings:(AVCapturePhotoSettings *)settings delegate:(id)delegate {
    if (!FCIsDisabled() && FCPreviewLayer && FCActiveLayer) {
        FCCaptureImage = FCRenderOnMain();
        FCCaptureDate = FCCaptureImage ? [NSDate date] : nil;
    } else {
        FCClearCaptureImage();
    }
    %orig;
}

%end

%hook AVCapturePhoto

// Chemins utilisés par l'app Appareil photo pour écrire le fichier et la vignette.
- (NSData *)fileDataRepresentation {
    NSData *original = %orig;
    return FCFakePhotoData(original) ?: original;
}

- (NSData *)fileDataRepresentationWithCustomizer:(id)customizer {
    NSData *original = %orig;
    return FCFakePhotoData(original) ?: original;
}

- (NSData *)fileDataRepresentationWithReplacementMetadata:(NSDictionary *)metadata
                       replacementEmbeddedThumbnailPhotoFormat:(NSDictionary *)thumbFormat
                     replacementEmbeddedThumbnailPixelBuffer:(CVPixelBufferRef)thumbPixelBuffer
                                          replacementDepthData:(AVDepthData *)depthData {
    NSData *original = %orig;
    return FCFakePhotoData(original) ?: original;
}

- (CGImageRef)CGImageRepresentation {
    CGImageRef fake = FCFakePhotoCGImage();
    return fake ?: %orig;
}

- (CGImageRef)previewCGImageRepresentation {
    CGImageRef fake = FCFakePhotoCGImage();
    return fake ?: %orig;
}

%end

// Filet de sécurité : si Camera écrit directement les données dans Photos.
%hook PHAssetCreationRequest

- (void)addResourceWithType:(PHAssetResourceType)type data:(NSData *)data options:(NSDictionary *)options {
    if (type == PHAssetResourceTypePhoto) {
        NSData *fake = FCFakePhotoData(data);
        if (fake) data = fake;
    }
    %orig(type, data, options);
}

%end

#pragma mark - Hook : gestes (installés une seule fois)

static void FCInstallGesturesIfNeeded(UIViewController *vc) {
    // Un seul contrôleur "hôte" pour toute l'app (pas de gestes en double).
    if (FCHostVC) return;
    if (!vc.isViewLoaded) return;
    if (!FCFindPreviewLayer(vc.view.layer)) return;

    FCHostVC = vc;
    FCObserver *obs = [FCObserver shared];

    UIPinchGestureRecognizer *pinch = [[UIPinchGestureRecognizer alloc] initWithTarget:obs action:@selector(handlePinch:)];
    pinch.cancelsTouchesInView = NO;
    pinch.delegate = obs;
    [vc.view addGestureRecognizer:pinch];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:obs action:@selector(handlePan:)];
    pan.cancelsTouchesInView = NO;
    pan.delegate = obs;
    [vc.view addGestureRecognizer:pan];
}

%hook UIViewController

- (void)viewDidLayoutSubviews {
    %orig;
    FCInstallGesturesIfNeeded(self);
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    FCInstallGesturesIfNeeded(self);
}

%end
