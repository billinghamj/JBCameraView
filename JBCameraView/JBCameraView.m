//
// 	JBCameraView.m
//  JBCameraView
//
//  Created by Markos Charatzas on 25/06/2013.
//  Copyright (c) 2015 Cuvva Limited
//  Copyright (c) 2013 www.verylargebox.com
//

#import "JBCameraView.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <AssetsLibrary/AssetsLibrary.h>
#import "VLBMacros.h"
#import "DDLog.h"

typedef void(^JBCaptureStillImageBlock)(CMSampleBufferRef imageDataSampleBuffer, NSError *error);
typedef void(^JBCameraViewInit)(JBCameraView *cameraView);

JBCameraViewMeta const JBCameraViewMetaCrop = @"JBCameraViewMetaCrop";
JBCameraViewMeta const JBCameraViewMetaOriginalImage = @"JBCameraViewMetaOriginalImage";

@interface JBCameraView ()
@property(nonatomic, strong) AVCaptureSession *session;
@property(nonatomic, strong) AVCaptureStillImageOutput *stillImageOutput;
@property(nonatomic, strong) AVCaptureVideoPreviewLayer *videoPreviewLayer;
@property(nonatomic, strong) AVCaptureConnection *stillImageConnection;
@property(nonatomic, weak) IBOutlet UIImageView* preview;

- (void)retakePicture:(UITapGestureRecognizer*) tapToRetakeGesture;
@end

JBCameraViewInit const JBCameraViewInitBlock = ^(JBCameraView *cameraView){
    cameraView.session = [AVCaptureSession new];
    [cameraView.session setSessionPreset:AVCaptureSessionPresetPhoto];

    cameraView.videoPreviewLayer = [[AVCaptureVideoPreviewLayer alloc] initWithSession:cameraView.session];
	cameraView.videoPreviewLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
	cameraView.videoPreviewLayer.frame = cameraView.layer.bounds;

    cameraView.flashView = [[UIView alloc] initWithFrame:cameraView.preview.bounds];
    cameraView.flashView.backgroundColor = [UIColor whiteColor];
    cameraView.flashView.alpha = 0.0f;
    [cameraView.videoPreviewLayer addSublayer:cameraView.flashView.layer];
};

@implementation JBCameraView

- (id)initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];

    VLB_IF_NOT_SELF_RETURN_NIL();
    VLB_LOAD_VIEW()

    JBCameraViewInitBlock(self);

return self;
}

-(id)initWithCoder:(NSCoder *)aDecoder
{
    self = [super initWithCoder:aDecoder];

    VLB_IF_NOT_SELF_RETURN_NIL();
    VLB_LOAD_VIEW()

    JBCameraViewInitBlock(self);

return self;
}

-(JBCaptureStillImageBlock) didFinishTakingPicture:(AVCaptureSession*) session preview:(UIImageView*) preview
{
    __weak JBCameraView *wself = self;

return ^(CMSampleBufferRef imageDataSampleBuffer, NSError *error)
    {
        [session stopRunning];

        if (error) {
            dispatch_async(dispatch_get_main_queue(), ^(void) {
                [wself cameraView:wself didErrorOnTakePicture:error];
            });

        return;
        }

        NSData* imageData = [AVCaptureStillImageOutput jpegStillImageNSDataRepresentation:imageDataSampleBuffer];
        UIImage *image = [UIImage imageWithData:imageData];
        CFDictionaryRef attachments = CMCopyDictionaryOfAttachments(kCFAllocatorDefault,
                                                                    imageDataSampleBuffer,
                                                                    kCMAttachmentMode_ShouldPropagate);
        NSDictionary *info = (__bridge NSDictionary*)attachments;

        if(wself.writeToCameraRoll)
        {
            [wself.delegate cameraView:wself willRriteToCameraRollWithMetadata:info];

            ALAssetsLibrary *library = [ALAssetsLibrary new];
            [library writeImageDataToSavedPhotosAlbum:imageData
                                             metadata:info
                                      completionBlock:^(NSURL *assetURL, NSError *error) {
                                          DDLogError(@"%@", error);
                                      }];
        }

        dispatch_async(dispatch_get_main_queue(), ^(void)
        {
            preview.image = image;

            [wself cameraView:wself didFinishTakingPicture:image withInfo:info meta:nil];

            CFRelease(attachments);
        });
    };
}

-(void)awakeFromNib
{
	NSError *error = nil;

    AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];

    if ([device isFocusModeSupported:AVCaptureFocusModeContinuousAutoFocus]) {
		NSError *error;
		if ([device lockForConfiguration:&error]) {
			device.focusMode = AVCaptureFocusModeContinuousAutoFocus;
			[device unlockForConfiguration];
        }
    }

    if([device isFlashModeSupported:AVCaptureFlashModeAuto]){
		if ([device lockForConfiguration:&error]) {
            device.flashMode = AVCaptureFlashModeAuto;
			[device unlockForConfiguration];
        }
    }

	AVCaptureDeviceInput *deviceInput = [AVCaptureDeviceInput deviceInputWithDevice:device error:&error];

    if(error){
        [NSException raise:[NSString stringWithFormat:@"Failed with error %d", (int)[error code]]
                    format:[error localizedDescription], nil];
    }

    [self.session addInput:deviceInput];

	self.stillImageOutput = [AVCaptureStillImageOutput new];
    [self.session addOutput:self.stillImageOutput];

	[self.layer addSublayer:self.videoPreviewLayer];

	[self.session startRunning];

    self.stillImageConnection = [self.stillImageOutput connectionWithMediaType:AVMediaTypeVideo];
    [self cameraView:self didCreateCaptureConnection:self.stillImageConnection];
}

-(void)cameraView:(JBCameraView*)cameraView didCreateCaptureConnection:(AVCaptureConnection*)captureConnection
{
    captureConnection.videoOrientation = AVCaptureVideoOrientationPortrait;

    if(self.callbackOnDidCreateCaptureConnection){
        [self.delegate cameraView:cameraView didCreateCaptureConnection:captureConnection];
    }
}

-(void)cameraView:(JBCameraView *)cameraView didFinishTakingPicture:(UIImage *)image withInfo:(NSDictionary *)info meta:(NSDictionary *)meta
{
    //point is in range 0..1
    CGPoint point = [self.videoPreviewLayer captureDevicePointOfInterestForPoint:CGPointZero];

    //point is calculated with camera in landscape but crop is in portrait
    CGRect crop = CGRectMake(image.size.height - (image.size.height * (1.0f - point.x)),
                             CGPointZero.y,
                             image.size.width,
                             image.size.height * (1.0f - point.x));

    CGImageRef imageRef = CGImageCreateWithImageInRect([image CGImage], crop);
    UIImage *newImage = [UIImage imageWithCGImage:imageRef scale:1.0f orientation:image.imageOrientation]; //preserve camera orientation
    CGImageRelease(imageRef);


    [self.delegate cameraView:cameraView
       didFinishTakingPicture:newImage
                     withInfo:info meta:@{JBCameraViewMetaCrop:[NSValue valueWithCGRect:crop],
                                          JBCameraViewMetaOriginalImage:image}];
}

-(void)cameraView:(JBCameraView *)cameraView didErrorOnTakePicture:(NSError *)error{
    DDLogError(@"%s %@", __PRETTY_FUNCTION__, error);
    [self.delegate cameraView:cameraView didErrorOnTakePicture:error];
}

- (void)takePicture
{
    [UIView animateWithDuration:0.4f
                     animations:^{ self.flashView.alpha = 1.0f; }
                     completion:^(BOOL finished){ self.flashView.alpha = 0.0f; }
     ];

    JBCaptureStillImageBlock didFinishTakingPicture = [self didFinishTakingPicture:self.session
                                                                            preview:self.preview];

    // set the appropriate pixel format / image type output setting depending on if we'll need an uncompressed image for
    // the possiblity of drawing the red square over top or if we're just writing a jpeg to the camera roll which is the trival case
    [self.stillImageOutput setOutputSettings:@{AVVideoCodecKey:AVVideoCodecJPEG}];
	[self.stillImageOutput captureStillImageAsynchronouslyFromConnection:self.stillImageConnection
                                                  completionHandler:didFinishTakingPicture];

    //test
    if(self.allowPictureRetake){
        UITapGestureRecognizer *tapToRetakeGesture =
        [[UITapGestureRecognizer alloc] initWithTarget:self
                                                action:@selector(retakePicture:)];
        [self.preview addGestureRecognizer:tapToRetakeGesture];
    }
}

- (void)retakePicture {
    [self.delegate cameraView:self willRetakePicture:self.preview.image];

    self.preview.image = nil;
    [self.session startRunning];
}

- (void)retakePicture:(UITapGestureRecognizer*) tapToRetakeGesture
{
    [self retakePicture];
}

@end
