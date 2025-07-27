# camera_avfoundation_frame

The iOS implementation of the [`camera`](https://pub.dev/packages/camera) plugin.

This package provides low-level camera access for the iOS platform using AVFoundation, and is used internally by the `camera` plugin.

---

## 🚀 New Feature: Capture Preview Frame (JPEG)

This version introduces a new platform method: `capturePreviewFrameJpeg(outputPath)` for retrieving a single JPEG-compressed frame directly from the preview stream, without interrupting camera operation.

### ✅ Use Cases

- Fast preview snapshot capture
- Save current frame to file instantly
- Frame grab for machine learning or inference
- Lightweight visual logging or scanning

---

## 📸 One-time Preview Frame (YUV)

To capture a single frame (non-streaming) in YUV format:

```dart
final CameraImageData frame = await cameraController.capturePreviewFrame();
// Access .planes, .width, .height, .format, etc.
```

---

## 🖼 One-time Preview Frame (JPEG)

To capture and save a JPEG-compressed preview frame to file:

```dart
final String savedPath = await cameraController.capturePreviewFrameJpeg('/path/to/file.jpg');
```

---

## 🛠 How It Works

- Captures pixel buffer using `AVCaptureVideoDataOutput`
- Converts CVPixelBuffer (YUV or BGRA) to `CIImage`
- Applies optional rotation
- Encodes as JPEG with 90% quality using `UIImageJPEGRepresentation`
- Frame capture does **not** interrupt preview or video recording

---

## ❗️Notes

- `capturePreviewFrameJpeg` does not trigger autofocus or shutter
- JPEG quality defaults to 90
- Supported formats: `kCVPixelFormatType_420YpCbCr8BiPlanarFullRange`, `kCVPixelFormatType_32BGRA`
- Supported on iOS 11+
