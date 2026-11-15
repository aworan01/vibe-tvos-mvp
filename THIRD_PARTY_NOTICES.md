# Third-party components

## VLCKit

The app links VLCKit from VideoLAN at the revision pinned in project.yml.
VLCKit and its bundled libVLC components are distributed under their respective
VideoLAN licences. See <https://github.com/videolan/vlckit>.

## FFmpeg

The ClearKey DASH relay links a minimal FFmpeg build from the revision pinned
in scripts/build-ffmpeg.sh. The build disables GPL and nonfree components and
uses FFmpeg under LGPL 2.1 or later. The build downloads the corresponding
licence and embeds it with a source reference in the application bundle.

See <https://ffmpeg.org/legal.html> and the exact source revision written by
the build into build/notices/FFmpeg-source.txt.
