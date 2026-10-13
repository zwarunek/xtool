// carcheck: asks Apple's CoreUI to resolve every asset of a reference .car from both the reference and a
// candidate .car, and compares the answers (image pixels, size, scale, template mode, colors, data).
// Usage: carcheck reference.car candidate.car    (one JSON line per query, then a summary line)
//        carcheck one.car                        (lists the names CoreUI enumerates)
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <ImageIO/ImageIO.h>

#define SEL_(n) sel_registerName(n)
static id msgO(id o, const char *n) { return ((id(*)(id, SEL))objc_msgSend)(o, SEL_(n)); }
static double msgD(id o, const char *n) { return ((double(*)(id, SEL))objc_msgSend)(o, SEL_(n)); }
static long long msgL(id o, const char *n) { return ((long long(*)(id, SEL))objc_msgSend)(o, SEL_(n)); }
static void *msgP(id o, const char *n) { return ((void *(*)(id, SEL))objc_msgSend)(o, SEL_(n)); }
static BOOL responds(id o, const char *n) { return o && [o respondsToSelector:SEL_(n)]; }

static id openCatalog(NSString *path, NSError **err) {
    dlopen("/System/Library/PrivateFrameworks/CoreUI.framework/CoreUI", RTLD_NOW);
    Class CUICatalog = NSClassFromString(@"CUICatalog");
    return ((id(*)(id, SEL, id, NSError **))objc_msgSend)([CUICatalog alloc], SEL_("initWithURL:error:"), [NSURL fileURLWithPath:path], err);
}

static NSDictionary *namesByClass(id catalog) {
    NSMutableDictionary *names = [NSMutableDictionary dictionary];
    ((void(*)(id, SEL, id))objc_msgSend)(catalog, SEL_("enumerateNamedLookupsUsingBlock:"), ^(id lookup) {
        NSString *cls = NSStringFromClass([lookup class]);
        NSString *name = msgO(lookup, "name");
        if (!name || [name hasPrefix:@"ZZZZPacked"]) return;
        NSMutableSet *s = names[cls] ?: (names[cls] = [NSMutableSet set]);
        [s addObject:name];
    });
    return names;
}

static id imageQuery(id catalog, NSString *name, double scale, long long idiom, NSString *appearance) {
    return ((id(*)(id, SEL, id, double, long long, unsigned long long, long long, long long, id))objc_msgSend)(
        catalog, SEL_("imageWithName:scaleFactor:deviceIdiom:deviceSubtype:sizeClassHorizontal:sizeClassVertical:appearanceName:"),
        name, scale, idiom, 0ULL, 0LL, 0LL, appearance);
}

static id colorQuery(id catalog, NSString *name, long long idiom, NSString *appearance) {
    return ((id(*)(id, SEL, id, long long, long long, id))objc_msgSend)(catalog, SEL_("colorWithName:displayGamut:deviceIdiom:appearanceName:"), name, 0LL, idiom, appearance);
}

typedef struct { int w, h; NSData *rgba; } Pixels;

static Pixels pixelsOf(CGImageRef img) {
    Pixels p = {0, 0, nil};
    if (!img) return p;
    p.w = (int)CGImageGetWidth(img);
    p.h = (int)CGImageGetHeight(img);
    NSMutableData *d = [NSMutableData dataWithLength:(NSUInteger)p.w * p.h * 4];
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(d.mutableBytes, p.w, p.h, 8, p.w * 4, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGContextDrawImage(ctx, CGRectMake(0, 0, p.w, p.h), img);
    CGContextRelease(ctx);
    CGColorSpaceRelease(cs);
    p.rgba = d;
    return p;
}

static NSArray *colorComponents(CGColorRef c) {
    if (!c) return @[];
    CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceExtendedSRGB);
    CGColorRef conv = CGColorCreateCopyByMatchingToColorSpace(srgb, kCGRenderingIntentDefault, c, NULL);
    CGColorSpaceRelease(srgb);
    NSMutableArray *a = [NSMutableArray array];
    CGColorRef use = conv ?: c;
    size_t n = CGColorGetNumberOfComponents(use);
    const CGFloat *comps = CGColorGetComponents(use);
    for (size_t i = 0; i < n; i++) [a addObject:@(round(comps[i] * 10000) / 10000)];
    if (conv) CGColorRelease(conv);
    return a;
}

static NSString *json(id obj) {
    NSData *d = [NSJSONSerialization dataWithJSONObject:obj options:NSJSONWritingSortedKeys error:nil];
    return [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
}

static NSDictionary *imageInfo(id img) {
    if (!img) return @{@"found": @NO};
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"found"] = @YES;
    d[@"scale"] = @(msgD(img, "scale"));
    if (responds(img, "templateRenderingMode")) d[@"template"] = @(msgL(img, "templateRenderingMode"));
    CGImageRef cg = responds(img, "image") ? (CGImageRef)msgP(img, "image") : NULL;
    d[@"pixels"] = cg ? [NSString stringWithFormat:@"%zux%zu", CGImageGetWidth(cg), CGImageGetHeight(cg)] : @"none";
    return d;
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr, "usage: carcheck reference.car [candidate.car]\n");
            return 64;
        }
        NSError *err = nil;
        if (argc == 7 && strcmp(argv[1], "--dump") == 0) {
            // carcheck --dump ref.car cand.car name scale outprefix: writes outprefix-ref.png and outprefix-cand.png
            for (int i = 0; i < 2; i++) {
                id cat = openCatalog(@(argv[2 + i]), &err);
                id img = imageQuery(cat, @(argv[4]), atof(argv[5]), 1, nil);
                CGImageRef cg = img ? (CGImageRef)msgP(img, "image") : NULL;
                if (!cg) { printf("no image in %s\n", argv[2 + i]); continue; }
                NSString *out = [NSString stringWithFormat:@"%s-%s.png", argv[6], i == 0 ? "ref" : "cand"];
                CGImageDestinationRef dst = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:out], CFSTR("public.png"), 1, NULL);
                CGImageDestinationAddImage(dst, cg, NULL);
                CGImageDestinationFinalize(dst);
                CFRelease(dst);
                printf("wrote %s\n", out.UTF8String);
            }
            return 0;
        }
        id ref = openCatalog(@(argv[1]), &err);
        if (!ref) {
            printf("%s\n", json(@{@"error": [NSString stringWithFormat:@"cannot load %s: %@", argv[1], err]}).UTF8String);
            return 1;
        }
        NSDictionary *names = namesByClass(ref);
        if (argc == 2) {
            for (NSString *cls in names) printf("%s\n", json(@{@"class": cls, @"names": [[names[cls] allObjects] sortedArrayUsingSelector:@selector(compare:)]}).UTF8String);
            return 0;
        }
        id cand = openCatalog(@(argv[2]), &err);
        if (!cand) {
            printf("%s\n", json(@{@"error": [NSString stringWithFormat:@"cannot load %s: %@", argv[2], err]}).UTF8String);
            return 1;
        }
        NSArray *appearances = @[ [NSNull null], @"UIAppearanceDark", @"UIAppearanceLight" ];
        int queries = 0, ok = 0, missing = 0, sizeDiff = 0, pixelDiff = 0, templateDiff = 0, colorDiff = 0, dataDiff = 0, scaleDiff = 0;
        NSMutableSet *imageNames = [NSMutableSet set];
        for (NSString *cls in names) if ([cls containsString:@"Image"] || [cls isEqual:@"CUINamedLayerStack"]) [imageNames unionSet:names[cls]];
        for (NSString *name in [[imageNames allObjects] sortedArrayUsingSelector:@selector(compare:)]) {
            for (NSNumber *idiom in @[ @1, @2 ]) {
                for (NSNumber *scale in @[ @1, @2, @3 ]) {
                    for (id app in appearances) {
                        NSString *appName = app == [NSNull null] ? nil : app;
                        id a = imageQuery(ref, name, scale.doubleValue, idiom.longLongValue, appName);
                        if (!a) continue;
                        queries++;
                        id b = imageQuery(cand, name, scale.doubleValue, idiom.longLongValue, appName);
                        NSMutableDictionary *row = [@{@"kind": @"image", @"name": name, @"idiom": idiom, @"scale": scale, @"appearance": appName ?: @"any", @"ref": imageInfo(a), @"cand": imageInfo(b)} mutableCopy];
                        NSMutableArray *problems = [NSMutableArray array];
                        if (!b) {
                            [problems addObject:@"missing"];
                            missing++;
                        } else {
                            if (msgD(a, "scale") != msgD(b, "scale")) { [problems addObject:@"scale"]; scaleDiff++; }
                            if (responds(a, "templateRenderingMode") && msgL(a, "templateRenderingMode") != msgL(b, "templateRenderingMode")) { [problems addObject:@"template"]; templateDiff++; }
                            Pixels pa = pixelsOf(responds(a, "image") ? (CGImageRef)msgP(a, "image") : NULL);
                            Pixels pb = pixelsOf(responds(b, "image") ? (CGImageRef)msgP(b, "image") : NULL);
                            if (pa.w != pb.w || pa.h != pb.h || !pa.rgba != !pb.rgba) {
                                [problems addObject:@"size"];
                                sizeDiff++;
                            } else if (pa.rgba) {
                                const uint8_t *x = pa.rgba.bytes, *y = pb.rgba.bytes;
                                long total = (long)pa.w * pa.h * 4, sum = 0, big = 0;
                                int maxd = 0;
                                for (long i = 0; i < total; i++) {
                                    int dd = abs((int)x[i] - (int)y[i]);
                                    sum += dd;
                                    if (dd > maxd) maxd = dd;
                                    if (dd > 48) big++;
                                }
                                double mean = total ? (double)sum / total : 0, over = total ? (double)big / total : 0;
                                row[@"meanDiff"] = @(round(mean * 1000) / 1000);
                                row[@"maxDiff"] = @(maxd);
                                row[@"over48"] = @(round(over * 10000) / 10000);
                                if (mean > 3.0 || over > 0.02) { [problems addObject:@"pixels"]; pixelDiff++; }
                            }
                        }
                        row[@"status"] = problems.count ? [problems componentsJoinedByString:@","] : @"ok";
                        if (!problems.count) ok++;
                        printf("%s\n", json(row).UTF8String);
                    }
                }
            }
        }
        // App icons: ask for the sizes SpringBoard uses.
        NSMutableSet *iconNames = [NSMutableSet set];
        for (NSString *cls in names) if ([cls containsString:@"Multisize"]) [iconNames unionSet:names[cls]];
        for (NSString *name in [[iconNames allObjects] sortedArrayUsingSelector:@selector(compare:)]) {
            for (NSArray *q in @[ @[ @1, @2, @60 ], @[ @1, @3, @60 ], @[ @2, @2, @76 ], @[ @2, @2, @83.5 ], @[ @1, @1, @1024 ], @[ @1, @2, @40 ] ]) {
                long long idiom = [q[0] longLongValue];
                double scale = [q[1] doubleValue], pts = [q[2] doubleValue];
                id (*fn)(id, SEL, id, double, long long, unsigned long long, long long, long long, long long, long long, CGSize, id) = (void *)objc_msgSend;
                SEL sel = SEL_("iconImageWithName:scaleFactor:deviceIdiom:deviceSubtype:displayGamut:layoutDirection:sizeClassHorizontal:sizeClassVertical:desiredSize:appearanceName:");
                id a = fn(ref, sel, name, scale, idiom, 0ULL, 0LL, 0LL, 0LL, 0LL, CGSizeMake(pts, pts), nil);
                if (!a) continue;
                queries++;
                id b = fn(cand, sel, name, scale, idiom, 0ULL, 0LL, 0LL, 0LL, 0LL, CGSizeMake(pts, pts), nil);
                NSMutableDictionary *row = [@{@"kind": @"icon", @"name": name, @"idiom": @(idiom), @"scale": @(scale), @"points": @(pts), @"ref": imageInfo(a), @"cand": imageInfo(b)} mutableCopy];
                NSString *status = @"ok";
                if (!b) { status = @"missing"; missing++; }
                else {
                    Pixels pa = pixelsOf((CGImageRef)msgP(a, "image")), pb = pixelsOf((CGImageRef)msgP(b, "image"));
                    if (pa.w != pb.w || pa.h != pb.h) { status = @"size"; sizeDiff++; }
                    else if (pa.rgba) {
                        const uint8_t *x = pa.rgba.bytes, *y = pb.rgba.bytes;
                        long total = (long)pa.w * pa.h * 4, sum = 0;
                        for (long i = 0; i < total; i++) sum += abs((int)x[i] - (int)y[i]);
                        double mean = total ? (double)sum / total : 0;
                        row[@"meanDiff"] = @(round(mean * 1000) / 1000);
                        if (mean > 3.0) { status = @"pixels"; pixelDiff++; }
                    }
                }
                if ([status isEqual:@"ok"]) ok++;
                row[@"status"] = status;
                printf("%s\n", json(row).UTF8String);
            }
        }
        // Symbol images (vector glyphs) at each size and a few weights.
        NSMutableSet *glyphNames = [NSMutableSet set];
        for (NSString *cls in names) if ([cls containsString:@"Glyph"]) [glyphNames unionSet:names[cls]];
        for (NSString *name in [[glyphNames allObjects] sortedArrayUsingSelector:@selector(compare:)]) {
            for (NSNumber *size in @[ @1, @2, @3 ]) {
                for (NSNumber *weight in @[ @1, @4, @6, @9 ]) {
                    id (*fn)(id, SEL, id, double, long long, long long, long long, long long, double, id) = (void *)objc_msgSend;
                    SEL sel = SEL_("namedVectorGlyphWithName:scaleFactor:deviceIdiom:layoutDirection:glyphSize:glyphWeight:glyphPointSize:appearanceName:");
                    id a = fn(ref, sel, name, 2.0, 1LL, 0LL, size.longLongValue, weight.longLongValue, 17.0, nil);
                    if (!a) continue;
                    queries++;
                    id b = fn(cand, sel, name, 2.0, 1LL, 0LL, size.longLongValue, weight.longLongValue, 17.0, nil);
                    NSMutableDictionary *row = [@{@"kind": @"glyph", @"name": name, @"size": size, @"weight": weight} mutableCopy];
                    NSString *status = @"ok";
                    if (!b) { status = @"missing"; missing++; }
                    else {
                        CGRect ra = ((CGRect(*)(id, SEL))objc_msgSend)(a, SEL_("alignmentRect")), rb = ((CGRect(*)(id, SEL))objc_msgSend)(b, SEL_("alignmentRect"));
                        double ba = ((double(*)(id, SEL))objc_msgSend)(a, SEL_("baselineOffset")), bb = ((double(*)(id, SEL))objc_msgSend)(b, SEL_("baselineOffset"));
                        row[@"refRect"] = NSStringFromRect(NSRectFromCGRect(ra));
                        row[@"candRect"] = NSStringFromRect(NSRectFromCGRect(rb));
                        row[@"refBaseline"] = @(ba);
                        row[@"candBaseline"] = @(bb);
                        Pixels pa = pixelsOf((CGImageRef)msgP(a, "image")), pb = pixelsOf((CGImageRef)msgP(b, "image"));
                        row[@"refPixels"] = [NSString stringWithFormat:@"%dx%d", pa.w, pa.h];
                        row[@"candPixels"] = [NSString stringWithFormat:@"%dx%d", pb.w, pb.h];
                        if (pa.w != pb.w || pa.h != pb.h) { status = @"size"; sizeDiff++; }
                        else if (pa.rgba) {
                            const uint8_t *x = pa.rgba.bytes, *y = pb.rgba.bytes;
                            long total = (long)pa.w * pa.h * 4, sum = 0;
                            for (long i = 0; i < total; i++) sum += abs((int)x[i] - (int)y[i]);
                            double mean = total ? (double)sum / total : 0;
                            row[@"meanDiff"] = @(round(mean * 1000) / 1000);
                            if (mean > 3.0) { status = @"pixels"; pixelDiff++; }
                        }
                        if (fabs(ba - bb) > 0.05 || fabs(ra.size.width - rb.size.width) > 0.1 || fabs(ra.size.height - rb.size.height) > 0.1) status = [status isEqual:@"ok"] ? @"metrics" : [status stringByAppendingString:@",metrics"];
                    }
                    if ([status isEqual:@"ok"]) ok++;
                    row[@"status"] = status;
                    printf("%s\n", json(row).UTF8String);
                }
            }
        }
        for (NSString *name in [[names[@"CUINamedColor"] allObjects] sortedArrayUsingSelector:@selector(compare:)]) {
            for (NSNumber *idiom in @[ @1, @2 ]) {
                for (id app in @[ [NSNull null], @"UIAppearanceDark", @"UIAppearanceLight", @"UIAppearanceHighContrastAny", @"UIAppearanceHighContrastDark" ]) {
                    NSString *appName = app == [NSNull null] ? nil : app;
                    id a = colorQuery(ref, name, idiom.longLongValue, appName);
                    if (!a) continue;
                    queries++;
                    id b = colorQuery(cand, name, idiom.longLongValue, appName);
                    NSArray *ca = colorComponents((CGColorRef)msgP(a, "cgColor"));
                    NSArray *cb = b ? colorComponents((CGColorRef)msgP(b, "cgColor")) : @[];
                    BOOL same = b && ca.count == cb.count;
                    for (NSUInteger i = 0; same && i < ca.count; i++) same = fabs([ca[i] doubleValue] - [cb[i] doubleValue]) < 0.002;
                    if (!b) missing++; else if (!same) colorDiff++; else ok++;
                    printf("%s\n", json(@{@"kind": @"color", @"name": name, @"idiom": idiom, @"appearance": appName ?: @"any", @"ref": ca, @"cand": cb, @"status": !b ? @"missing" : same ? @"ok" : @"color"}).UTF8String);
                }
            }
        }
        for (NSString *name in [[names[@"CUINamedData"] allObjects] sortedArrayUsingSelector:@selector(compare:)]) {
            id a = ((id(*)(id, SEL, id))objc_msgSend)(ref, SEL_("dataWithName:"), name);
            if (!a) continue;
            queries++;
            id b = ((id(*)(id, SEL, id))objc_msgSend)(cand, SEL_("dataWithName:"), name);
            NSData *da = msgO(a, "data"), *db = b ? msgO(b, "data") : nil;
            BOOL same = db && [da isEqualToData:db];
            if (!b) missing++; else if (!same) dataDiff++; else ok++;
            printf("%s\n", json(@{@"kind": @"data", @"name": name, @"refLength": @(da.length), @"candLength": @(db.length), @"status": !b ? @"missing" : same ? @"ok" : @"data"}).UTF8String);
        }
        printf("%s\n", json(@{@"summary": @{@"queries": @(queries), @"ok": @(ok), @"missing": @(missing), @"sizeDiffs": @(sizeDiff), @"pixelDiffs": @(pixelDiff), @"scaleDiffs": @(scaleDiff),
                                            @"templateDiffs": @(templateDiff), @"colorDiffs": @(colorDiff), @"dataDiffs": @(dataDiff), @"classes": [names allKeys]}}).UTF8String);
    }
    return 0;
}
