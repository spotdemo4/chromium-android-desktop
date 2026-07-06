Production builds of Chromium for Android "Desktop" that support:
- Mobile
- Extensions
- Proprietary codecs (H.264, AAC, HEVC)
- Installing Progressive Web Apps (PWAs)

This differs from the [official builds](https://commondatastorage.googleapis.com/chromium-browser-snapshots/index.html?prefix=AndroidDesktop_arm64%2F), which do not support proprietary codecs

Download the APK from [Releases](https://github.com/spotdemo4/chromium-android-desktop/releases/latest)

[Learn more](https://www.androidauthority.com/chrome-for-android-with-extensions-demo-3540132/)

## Extensions

To install extensions:
- Download the `.crx` file
- Open chrome://extensions
- Enable "Developer mode" (top right corner)
- Drag and drop the `.crx` file into the page

On mobile, this works best using the "split screen" feature with the Files app

### Extension Downloads

The `.crx` file can be downloaded from:
```
https://clients2.google.com/service/update2/crx?response=redirect&os=android&arch=arm64&acceptformat=crx2,crx3&prodversion=[VERSION]&x=id%3D[EXTENSION]%26uc
```
`[VERSION]` is the version of Chromium, and `[EXTENSION]` is the ID of the extension

- [uBlock Origin Lite](https://clients2.google.com/service/update2/crx?response=redirect&os=android&arch=arm64&prodversion=152.0.7925.0&acceptformat=crx2,crx3&x=id%3Dddkjiahejlhfcafbddmgiahcphecmpfh%26uc)
- [Pangram AI Detection](https://clients2.google.com/service/update2/crx?response=redirect&os=android&arch=arm64&prodversion=152.0.7925.0&acceptformat=crx2,crx3&x=id%3Deakpippijmmohmdlpgcjnipolcgciaga%26uc)
