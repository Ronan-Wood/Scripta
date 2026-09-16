# Vendored license texts

These packages ship in the bundled engine without a license file of their own, although their licenses
require the text to accompany a binary distribution. `tools/build-bundled-engine` copies each file
here into the matching package's `dist-info/licenses/` in the bundle, and it refuses to finish if any
bundled package is still without a license file.

Files are named `<normalized package name>-<version>.txt` and were fetched from each project's source
at that exact version on 2026-09-15. When a package is upgraded the old name no longer matches and
the build fails, so the text is refreshed on purpose rather than carried forward.

## OpenCV's third-party notice

`opencv-python-headless-<version>-third-party.txt` is a different case. OpenCV ships a notice, but it
describes the libraries in OpenCV's prebuilt wheels, FFmpeg and libvpx among them, and this engine
compiles OpenCV from source without them. The build copies this file over OpenCV's
`LICENSE-3RD-PARTY.txt`, in `cv2/` and in its `dist-info`, and fails when none matches the bundled
version.

It was assembled on 2026-09-15 from the license files in the 4.14.0.94 source distribution, for the
components that build compiles in: OpenCV, Carotene, zlib, libjpeg-turbo, libpng, libtiff, libwebp,
OpenJPEG, OpenEXR, Protocol Buffers, FlatBuffers and the Khronos OpenCL headers. On an upgrade, compare
the `3rdparty dependencies` line of `cv2.getBuildInformation()` with that list before regenerating it.
