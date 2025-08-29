# camera_avfoundation_frame

The iOS implementation of the [`camera`](https://pub.dev/packages/camera) plugin.

This package provides low-level camera access for the iOS platform using AVFoundation, and is used internally by the `camera` plugin.

---

## 🚀 New Feature: Capture Preview Frame (JPEG)

This version adds `capturePreviewFrameJpeg(outputPath, { rotationDegrees, quality })` to grab a single JPEG-compressed frame from the preview stream **without** interrupting the camera.

- `rotationDegrees` *(optional, int)*: `0 | 90 | 180 | 270` (pixel rotation, **no EXIF**).
- `quality` *(optional, int)*: `0–100` (default `92`).

### ✅ Use Cases

- Fast preview snapshot capture
- Save current frame to file instantly
- Frame grab for ML/inference
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
// Default: rotation 0°, quality 92
final String savedPath = await cameraController.capturePreviewFrameJpeg('/path/to/file.jpg');

// With rotation and quality
final String savedPath2 = await cameraController.capturePreviewFrameJpeg(
  '/path/to/rotated.jpg',
  rotationDegrees: 90,
  quality: 85,
);
```

---

## 🛠 How It Works

- Captures the current `CVPixelBuffer` via `AVCaptureVideoDataOutput`
- Converts NV12/BGRA → `CIImage`, applies **pixel rotation** (no EXIF tags)
- Encodes JPEG via `CGImageDestination` (quality `0–1`, mapped from `0–100`)
- Capture does **not** interrupt preview or video recording

---

## ❗️Notes

- `capturePreviewFrameJpeg` does not trigger autofocus or use shutter animations
- JPEG **does not** contain EXIF metadata or EXIF orientation (pixels are rotated)
- Supported formats: `kCVPixelFormatType_420YpCbCr8BiPlanarFullRange` (NV12), `kCVPixelFormatType_32BGRA`
- iOS 11+
