#import <UIKit/UIKit.h>
#import <PhotosUI/PhotosUI.h>
#import <CoreImage/CoreImage.h>
#import <AVFoundation/AVFoundation.h>
#import <notify.h>

// FakeCam (app de contrôle) : choix de la photo OU vidéo, zoom, rotation, position, filtres, on/off.
// L'app écrit le média (original.jpg ou video.mp4) + settings.plist ; le tweak les applique
// à la taille réelle de l'aperçu de l'Appareil photo (adaptation automatique à chaque mode).

static NSString * const kReloadNote = @"com.lemaso.fakecam.reload";
static CGFloat const kMaxPixel = 2048.0;
static CGSize const kPreviewCanvas = {360, 480};

// {dossier, racine qui doit exister}
static NSArray<NSArray<NSString *> *> *SharedDirs(void) {
    return @[@[@"/var/jb/var/mobile/Library/FakeCam", @"/var/jb"],
             @[@"/var/mobile/Media/FakeCam", @"/var/mobile/Media"]];
}

static NSArray<NSString *> *UsableDirs(void) {
    NSMutableArray *out = [NSMutableArray array];
    for (NSArray<NSString *> *pair in SharedDirs()) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:pair[1]]) [out addObject:pair[0]];
    }
    return out;
}

static NSString *ImagePathIn(NSString *dir)    { return [dir stringByAppendingPathComponent:@"fake.jpg"]; }   // ancien format
static NSString *VideoPathIn(NSString *dir)    { return [dir stringByAppendingPathComponent:@"video.mp4"]; }
static NSString *DisabledPathIn(NSString *dir) { return [dir stringByAppendingPathComponent:@"disabled"]; }
static NSString *OriginalPathIn(NSString *dir) { return [dir stringByAppendingPathComponent:@"original.jpg"]; }
static NSString *SettingsPathIn(NSString *dir) { return [dir stringByAppendingPathComponent:@"settings.plist"]; }

static void EnsureDir(NSString *dir) {
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES
                                               attributes:@{NSFilePosixPermissions: @0777} error:nil];
}

static NSString *StoreDir(void) { return UsableDirs().firstObject; }

static void NotifyTweak(void) {
    notify_post([kReloadNote UTF8String]);
}

#pragma mark - Image

static UIImage *Normalized(UIImage *src) {
    if (!src || !src.CGImage) return nil;
    CGSize s = src.size;
    CGFloat maxSide = MAX(s.width, s.height);
    if (maxSide <= 0) return nil;
    CGFloat ratio = maxSide > kMaxPixel ? kMaxPixel / maxSide : 1.0;
    CGSize target = CGSizeMake(floor(s.width * ratio), floor(s.height * ratio));
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat preferredFormat];
    fmt.scale = 1.0;
    fmt.opaque = YES;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:target format:fmt];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [src drawInRect:CGRectMake(0, 0, target.width, target.height)];
    }];
}

static NSArray<NSString *> *FilterNames(void) {
    return @[@"Aucun", @"Noir & blanc", @"Noir", @"Sépia", @"Chrome", @"Instantané", @"Vif", @"Chaud", @"Froid"];
}

static UIImage *ApplyFilter(UIImage *img, NSInteger idx) {
    if (!img || idx <= 0) return img;
    CIImage *ci = [[CIImage alloc] initWithImage:img];
    if (!ci) return img;

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
    if (!f) return img;
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

// Rendu final : recadrage (cover) + zoom + rotation + décalage, puis filtre.
static UIImage *Render(UIImage *orig, CGFloat zoom, CGFloat rotDeg, CGFloat ox, CGFloat oy,
                       NSInteger filter, CGSize canvas) {
    if (!orig) return nil;
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat preferredFormat];
    fmt.scale = 1.0;
    fmt.opaque = YES;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:canvas format:fmt];

    UIImage *base = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGContextRef c = ctx.CGContext;
        [[UIColor blackColor] setFill];
        CGContextFillRect(c, CGRectMake(0, 0, canvas.width, canvas.height));

        CGFloat th = rotDeg * M_PI / 180.0;
        CGSize s = orig.size;
        // Échelle minimale pour que l'image tournée couvre tout le cadre.
        CGFloat kw = (canvas.width * fabs(cos(th)) + canvas.height * fabs(sin(th))) / s.width;
        CGFloat kh = (canvas.width * fabs(sin(th)) + canvas.height * fabs(cos(th))) / s.height;
        CGFloat k = MAX(kw, kh) * zoom;

        CGContextTranslateCTM(c, canvas.width / 2 + ox * canvas.width / 2,
                                 canvas.height / 2 + oy * canvas.height / 2);
        CGContextRotateCTM(c, th);
        [orig drawInRect:CGRectMake(-s.width * k / 2, -s.height * k / 2, s.width * k, s.height * k)];
    }];
    return ApplyFilter(base, filter);
}

#pragma mark - Fichiers partagés

static BOOL IsEnabled(void) {
    for (NSString *dir in UsableDirs()) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:DisabledPathIn(dir)]) return NO;
    }
    return YES;
}

static UIImage *CurrentFakeImage(void) {
    for (NSString *dir in UsableDirs()) {
        UIImage *img = [UIImage imageWithContentsOfFile:ImagePathIn(dir)];
        if (img) return img;
    }
    return nil;
}

static void Chmod666(NSString *path) {
    [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @0666} ofItemAtPath:path error:nil];
}

// Écrit le média (image OU vidéo) dans tous les dossiers partagés et prévient le tweak.
static NSString *WriteMedia(UIImage *image, NSString *videoFile) {
    NSData *data = image ? UIImageJPEGRepresentation(image, 0.92) : nil;
    if (!data && !videoFile) return @"❌ Média illisible.";

    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray *ok = [NSMutableArray array];
    NSMutableArray *errs = [NSMutableArray array];

    for (NSString *dir in UsableDirs()) {
        EnsureDir(dir);
        // Un seul média à la fois : on supprime l'ancien.
        [fm removeItemAtPath:OriginalPathIn(dir) error:nil];
        [fm removeItemAtPath:VideoPathIn(dir) error:nil];
        [fm removeItemAtPath:ImagePathIn(dir) error:nil];

        NSError *err = nil;
        BOOL success;
        NSString *dest;
        if (data) {
            dest = OriginalPathIn(dir);
            success = [data writeToFile:dest options:NSDataWritingAtomic error:&err];
        } else {
            dest = VideoPathIn(dir);
            success = [fm copyItemAtPath:videoFile toPath:dest error:&err];
        }
        if (success) {
            Chmod666(dest);
            [fm removeItemAtPath:DisabledPathIn(dir) error:nil];
            [ok addObject:dir];
        } else {
            [errs addObject:[NSString stringWithFormat:@"%@ : %@", dir, err.localizedDescription]];
        }
    }
    NotifyTweak();

    if (ok.count == 0) {
        BOOL jb = [fm fileExistsAtPath:@"/var/jb"];
        return [NSString stringWithFormat:@"❌ Écriture impossible.\n%@\n\nDiagnostic : /var/jb visible = %@.",
                [errs componentsJoinedByString:@"\n"], jb ? @"OUI" : @"NON"];
    }
    NSString *msg = [NSString stringWithFormat:@"✅ %@ appliquée dans l'Appareil photo.", data ? @"Photo" : @"Vidéo"];
    if (errs.count) msg = [msg stringByAppendingFormat:@"\n⚠️ %@", [errs componentsJoinedByString:@"\n"]];
    return msg;
}

static void WriteSettings(NSDictionary *settings) {
    for (NSString *dir in UsableDirs()) {
        EnsureDir(dir);
        NSString *path = SettingsPathIn(dir);
        [settings writeToFile:path atomically:YES];
        Chmod666(path);
    }
    NotifyTweak();
}

static UIImage *VideoThumbnail(NSString *path) {
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:nil];
    AVAssetImageGenerator *gen = [[AVAssetImageGenerator alloc] initWithAsset:asset];
    gen.appliesPreferredTrackTransform = YES;
    gen.maximumSize = CGSizeMake(1080, 1920);
    CGImageRef cg = [gen copyCGImageAtTime:CMTimeMake(1, 10) actualTime:NULL error:NULL];
    if (!cg) cg = [gen copyCGImageAtTime:kCMTimeZero actualTime:NULL error:NULL];
    if (!cg) return nil;
    UIImage *img = [UIImage imageWithCGImage:cg];
    CGImageRelease(cg);
    return img;
}

static void SetEnabled(BOOL enabled) {
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *dir in UsableDirs()) {
        EnsureDir(dir);
        if (enabled) {
            [fm removeItemAtPath:DisabledPathIn(dir) error:nil];
        } else {
            [@"" writeToFile:DisabledPathIn(dir) atomically:YES encoding:NSUTF8StringEncoding error:nil];
            [fm setAttributes:@{NSFilePosixPermissions: @0666} ofItemAtPath:DisabledPathIn(dir) error:nil];
        }
    }
    NotifyTweak();
}

static void DeleteAll(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *dir in UsableDirs()) {
        [fm removeItemAtPath:ImagePathIn(dir) error:nil];
        [fm removeItemAtPath:OriginalPathIn(dir) error:nil];
        [fm removeItemAtPath:VideoPathIn(dir) error:nil];
        [fm removeItemAtPath:SettingsPathIn(dir) error:nil];
    }
    NotifyTweak();
}

#pragma mark - UI

@interface FCViewController : UIViewController <PHPickerViewControllerDelegate>
@property (nonatomic, strong) UIImage *original;
@property (nonatomic, assign) CGFloat zoom, rot, offX, offY;
@property (nonatomic, assign) NSInteger filter;
@property (nonatomic, strong) UIImageView *preview;
@property (nonatomic, strong) UISwitch *toggle;
@property (nonatomic, strong) UILabel *status;
@property (nonatomic, strong) UISlider *zoomS, *rotS, *xS, *yS;
@property (nonatomic, strong) UILabel *zoomL, *rotL, *xL, *yL;
@property (nonatomic, strong) UIButton *filterBtn;
@property (nonatomic, strong) dispatch_queue_t queue;
@end

@implementation FCViewController

- (UIButton *)buttonWithTitle:(NSString *)title color:(UIColor *)color action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    b.backgroundColor = color;
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    b.layer.cornerRadius = 12;
    [b.heightAnchor constraintEqualToConstant:46].active = YES;
    if (action) [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (UISlider *)sliderMin:(float)min max:(float)max {
    UISlider *s = [[UISlider alloc] init];
    s.minimumValue = min;
    s.maximumValue = max;
    [s addTarget:self action:@selector(sliderMoved) forControlEvents:UIControlEventValueChanged];
    [s addTarget:self action:@selector(sliderDone)
        forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    return s;
}

- (UIStackView *)rowTitle:(NSString *)title label:(UILabel * __strong *)outLabel slider:(UISlider *)slider {
    UILabel *name = [[UILabel alloc] init];
    name.text = title;
    name.font = [UIFont systemFontOfSize:14];
    [name.widthAnchor constraintEqualToConstant:78].active = YES;
    UILabel *val = [[UILabel alloc] init];
    val.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightRegular];
    val.textColor = [UIColor secondaryLabelColor];
    val.textAlignment = NSTextAlignmentRight;
    [val.widthAnchor constraintEqualToConstant:52].active = YES;
    *outLabel = val;
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[name, slider, val]];
    row.spacing = 8;
    row.alignment = UIStackViewAlignmentCenter;
    return row;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.queue = dispatch_queue_create("fakecam.commit", DISPATCH_QUEUE_SERIAL);
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.zoom = 1; self.rot = 0; self.offX = 0; self.offY = 0; self.filter = 0;

    UILabel *title = [[UILabel alloc] init];
    title.text = @"FakeCam";
    title.font = [UIFont boldSystemFontOfSize:28];

    self.preview = [[UIImageView alloc] init];
    self.preview.contentMode = UIViewContentModeScaleAspectFit;
    self.preview.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.preview.layer.cornerRadius = 12;
    self.preview.clipsToBounds = YES;
    [self.preview.heightAnchor constraintEqualToConstant:330].active = YES;

    UIButton *pick = [self buttonWithTitle:@"Choisir une photo / vidéo" color:[UIColor systemBlueColor] action:@selector(pickPhoto)];

    self.zoomS = [self sliderMin:1.0 max:4.0];
    self.rotS  = [self sliderMin:-180 max:180];
    self.xS    = [self sliderMin:-1 max:1];
    self.yS    = [self sliderMin:-1 max:1];
    UIStackView *zoomRow = [self rowTitle:@"Zoom" label:&_zoomL slider:self.zoomS];
    UIStackView *rotRow  = [self rowTitle:@"Rotation" label:&_rotL slider:self.rotS];
    UIStackView *xRow    = [self rowTitle:@"Position X" label:&_xL slider:self.xS];
    UIStackView *yRow    = [self rowTitle:@"Position Y" label:&_yL slider:self.yS];

    UIButton *left  = [self buttonWithTitle:@"↺ 90°" color:[UIColor systemGrayColor] action:@selector(rotateLeft)];
    UIButton *right = [self buttonWithTitle:@"↻ 90°" color:[UIColor systemGrayColor] action:@selector(rotateRight)];
    UIStackView *rotButtons = [[UIStackView alloc] initWithArrangedSubviews:@[left, right]];
    rotButtons.distribution = UIStackViewDistributionFillEqually;
    rotButtons.spacing = 12;

    self.filterBtn = [self buttonWithTitle:@"Filtre : Aucun" color:[UIColor systemPurpleColor] action:nil];
    [self rebuildFilterMenu];

    UILabel *switchLabel = [[UILabel alloc] init];
    switchLabel.text = @"Faux aperçu activé";
    self.toggle = [[UISwitch alloc] init];
    [self.toggle addTarget:self action:@selector(toggleChanged) forControlEvents:UIControlEventValueChanged];
    UIStackView *switchRow = [[UIStackView alloc] initWithArrangedSubviews:@[switchLabel, self.toggle]];
    switchRow.distribution = UIStackViewDistributionEqualSpacing;

    UIButton *reset = [self buttonWithTitle:@"Réinitialiser les réglages" color:[UIColor systemOrangeColor] action:@selector(resetSettings)];
    UIButton *del = [self buttonWithTitle:@"Supprimer le média" color:[UIColor systemRedColor] action:@selector(deletePhoto)];

    self.status = [[UILabel alloc] init];
    self.status.numberOfLines = 0;
    self.status.font = [UIFont systemFontOfSize:13];
    self.status.textColor = [UIColor secondaryLabelColor];
    self.status.text = @"Choisis une photo ou une vidéo, règle-la, puis ouvre l'Appareil photo.";

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:
        @[title, self.preview, pick, zoomRow, rotRow, rotButtons, xRow, yRow, self.filterBtn, switchRow, reset, del, self.status]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 14;
    stack.translatesAutoresizingMaskIntoConstraints = NO;

    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.alwaysBounceVertical = YES;
    [self.view addSubview:scroll];
    [scroll addSubview:stack];

    UILayoutGuide *g = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:g.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:16],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-40],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.leadingAnchor constant:20],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.trailingAnchor constant:-20],
    ]];

    [self loadState];
    [self syncUI];
}

#pragma mark État

- (void)loadState {
    NSString *dir = StoreDir();
    if (dir) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:VideoPathIn(dir)]) {
            self.original = Normalized(VideoThumbnail(VideoPathIn(dir)));
        } else {
            self.original = [UIImage imageWithContentsOfFile:OriginalPathIn(dir)];
        }
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:SettingsPathIn(dir)];
        if (d && self.original) {
            self.zoom = [d[@"zoom"] doubleValue] ?: 1;
            self.rot = [d[@"rot"] doubleValue];
            self.offX = [d[@"x"] doubleValue];
            self.offY = [d[@"y"] doubleValue];
            self.filter = [d[@"filter"] integerValue];
        }
    }
    // Ancienne photo sans original enregistré : on la reprend telle quelle.
    if (!self.original) self.original = Normalized(CurrentFakeImage());
    self.toggle.on = IsEnabled();
}

- (NSDictionary *)settingsDict {
    return @{@"zoom": @(self.zoom), @"rot": @(self.rot), @"x": @(self.offX), @"y": @(self.offY), @"filter": @(self.filter)};
}

// Remet les curseurs / labels / aperçu en accord avec les valeurs.
- (void)syncUI {
    self.zoomS.value = self.zoom;
    self.rotS.value = self.rot;
    self.xS.value = self.offX;
    self.yS.value = self.offY;
    [self updateLabels];
    [self rebuildFilterMenu];
    [self updatePreview];
}

- (void)updateLabels {
    self.zoomL.text = [NSString stringWithFormat:@"%.2f×", self.zoom];
    self.rotL.text  = [NSString stringWithFormat:@"%.0f°", self.rot];
    self.xL.text    = [NSString stringWithFormat:@"%+.2f", self.offX];
    self.yL.text    = [NSString stringWithFormat:@"%+.2f", self.offY];
}

- (void)updatePreview {
    if (!self.original) { self.preview.image = nil; return; }
    self.preview.image = Render(self.original, self.zoom, self.rot, self.offX, self.offY,
                                self.filter, kPreviewCanvas);
}

// Écrit les réglages (le tweak applique le recadrage / zoom / rotation / filtre à la bonne taille).
- (void)commit {
    if (!self.original) return;
    NSDictionary *settings = [self settingsDict];
    dispatch_async(self.queue, ^{
        WriteSettings(settings);
        dispatch_async(dispatch_get_main_queue(), ^{ self.status.text = @"✅ Réglages appliqués dans l'Appareil photo."; });
    });
}

#pragma mark Actions

- (void)sliderMoved {
    self.zoom = self.zoomS.value;
    self.rot = roundf(self.rotS.value);
    self.offX = self.xS.value;
    self.offY = self.yS.value;
    [self updateLabels];
    [self updatePreview];
}

- (void)sliderDone {
    [self commit];
}

- (void)rotateBy:(CGFloat)delta {
    CGFloat r = self.rot + delta;
    while (r > 180) r -= 360;
    while (r < -180) r += 360;
    self.rot = r;
    [self syncUI];
    [self commit];
}
- (void)rotateLeft  { [self rotateBy:-90]; }
- (void)rotateRight { [self rotateBy:90]; }

- (void)rebuildFilterMenu {
    NSMutableArray<UIAction *> *actions = [NSMutableArray array];
    NSArray<NSString *> *names = FilterNames();
    for (NSInteger i = 0; i < (NSInteger)names.count; i++) {
        UIAction *a = [UIAction actionWithTitle:names[i] image:nil identifier:nil
                                        handler:^(__kindof UIAction *action) {
            self.filter = i;
            [self syncUI];
            [self commit];
        }];
        a.state = (i == self.filter) ? UIMenuElementStateOn : UIMenuElementStateOff;
        [actions addObject:a];
    }
    self.filterBtn.menu = [UIMenu menuWithTitle:@"Filtre" children:actions];
    self.filterBtn.showsMenuAsPrimaryAction = YES;
    [self.filterBtn setTitle:[NSString stringWithFormat:@"Filtre : %@", names[self.filter]] forState:UIControlStateNormal];
}

- (void)resetSettings {
    self.zoom = 1; self.rot = 0; self.offX = 0; self.offY = 0; self.filter = 0;
    [self syncUI];
    [self commit];
}

- (void)pickPhoto {
    PHPickerConfiguration *config = [[PHPickerConfiguration alloc] init];
    config.filter = [PHPickerFilter anyFilterMatchingSubfilters:@[[PHPickerFilter imagesFilter], [PHPickerFilter videosFilter]]];
    config.selectionLimit = 1;
    PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:config];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    NSItemProvider *provider = results.firstObject.itemProvider;
    if (!provider) return;

    if ([provider hasItemConformingToTypeIdentifier:@"public.movie"]) {
        [self importVideoFrom:provider];
        return;
    }
    if (![provider canLoadObjectOfClass:[UIImage class]]) return;

    [provider loadObjectOfClass:[UIImage class] completionHandler:^(id<NSItemProviderReading> object, NSError *error) {
        UIImage *image = [(id)object isKindOfClass:[UIImage class]] ? (UIImage *)object : nil;
        UIImage *norm = Normalized(image);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!norm) { self.status.text = @"❌ Impossible de charger la photo."; return; }
            [self adoptNewMedia:norm videoFile:nil];
        });
    }];
}

// Nouveau média : réglages remis à zéro, écriture, mise à jour de l'écran.
- (void)adoptNewMedia:(UIImage *)preview videoFile:(NSString *)videoFile {
    self.original = preview;
    self.zoom = 1; self.rot = 0; self.offX = 0; self.offY = 0; self.filter = 0;
    self.toggle.on = YES;
    [self syncUI];
    NSDictionary *settings = [self settingsDict];
    self.status.text = @"⏳ Enregistrement…";
    dispatch_async(self.queue, ^{
        NSString *msg = WriteMedia(videoFile ? nil : preview, videoFile);
        WriteSettings(settings);
        dispatch_async(dispatch_get_main_queue(), ^{ self.status.text = msg; });
    });
}

// Vidéo : copie, suppression de l'audio, conversion 720p (léger pour l'Appareil photo), max 60 s.
- (void)importVideoFrom:(NSItemProvider *)provider {
    self.status.text = @"⏳ Conversion de la vidéo…";
    [provider loadFileRepresentationForTypeIdentifier:@"public.movie" completionHandler:^(NSURL *url, NSError *error) {
        if (!url) {
            dispatch_async(dispatch_get_main_queue(), ^{ self.status.text = @"❌ Impossible de charger la vidéo."; });
            return;
        }
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *tmpIn = [NSTemporaryDirectory() stringByAppendingPathComponent:@"fc_in.mov"];
        [fm removeItemAtPath:tmpIn error:nil];
        NSError *cerr = nil;
        if (![fm copyItemAtURL:url toURL:[NSURL fileURLWithPath:tmpIn] error:&cerr]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.status.text = [NSString stringWithFormat:@"❌ Copie de la vidéo impossible : %@", cerr.localizedDescription];
            });
            return;
        }
        [self convertVideoAtPath:tmpIn];
    }];
}

- (void)convertVideoAtPath:(NSString *)path {
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:nil];
    AVAssetTrack *vt = [[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
    if (!vt) {
        dispatch_async(dispatch_get_main_queue(), ^{ self.status.text = @"❌ Aucune piste vidéo."; });
        return;
    }
    AVMutableComposition *comp = [AVMutableComposition composition];
    AVMutableCompositionTrack *ct = [comp addMutableTrackWithMediaType:AVMediaTypeVideo
                                                      preferredTrackID:kCMPersistentTrackID_Invalid];
    CMTime duration = CMTimeMinimum(asset.duration, CMTimeMakeWithSeconds(60, 600));
    NSError *err = nil;
    [ct insertTimeRange:CMTimeRangeMake(kCMTimeZero, duration) ofTrack:vt atTime:kCMTimeZero error:&err];
    ct.preferredTransform = vt.preferredTransform;

    NSString *out = [NSTemporaryDirectory() stringByAppendingPathComponent:@"fc_out.mp4"];
    [[NSFileManager defaultManager] removeItemAtPath:out error:nil];

    AVAssetExportSession *ex = [[AVAssetExportSession alloc] initWithAsset:comp presetName:AVAssetExportPreset1280x720];
    ex.outputURL = [NSURL fileURLWithPath:out];
    ex.outputFileType = AVFileTypeMPEG4;
    [ex exportAsynchronouslyWithCompletionHandler:^{
        if (ex.status != AVAssetExportSessionStatusCompleted) {
            NSString *reason = ex.error.localizedDescription ?: @"inconnue";
            dispatch_async(dispatch_get_main_queue(), ^{
                self.status.text = [NSString stringWithFormat:@"❌ Conversion impossible : %@", reason];
            });
            return;
        }
        UIImage *thumb = Normalized(VideoThumbnail(out));
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!thumb) { self.status.text = @"❌ Aperçu de la vidéo impossible."; return; }
            [self adoptNewMedia:thumb videoFile:out];
        });
    }];
}

- (void)toggleChanged {
    SetEnabled(self.toggle.isOn);
    self.status.text = self.toggle.isOn ? @"✅ Faux aperçu activé." : @"⭕ Faux aperçu désactivé (vraie caméra).";
}

- (void)deletePhoto {
    DeleteAll();
    self.original = nil;
    self.zoom = 1; self.rot = 0; self.offX = 0; self.offY = 0; self.filter = 0;
    [self syncUI];
    self.status.text = @"Média supprimé : la vraie caméra s'affiche.";
}

@end

@interface FCAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation FCAppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.rootViewController = [[FCViewController alloc] init];
    [self.window makeKeyAndVisible];
    return YES;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([FCAppDelegate class]));
    }
}
