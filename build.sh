#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
app="$TMPDIR/DirectSitesBuild/Direct Sites.app"
rtk mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
rtk xcrun swiftc -swift-version 6 -warnings-as-errors -module-cache-path "$TMPDIR/DirectSitesModuleCache" -target arm64-apple-macosx14.0 -Onone Source/Core.swift Source/ProxyRouting.swift Source/Favicon.swift Source/Migration.swift Source/ChromeSetup.swift Source/Tests.swift -o "$TMPDIR/DirectSitesTests"
rtk "$TMPDIR/DirectSitesTests"
rtk xcrun swiftc -swift-version 6 -warnings-as-errors -module-cache-path "$TMPDIR/DirectSitesModuleCache" -target arm64-apple-macosx14.0 -O Source/Core.swift Source/ProxyRouting.swift Source/Migration.swift Source/BrowserProxy.swift Source/Helper.swift -o "$app/Contents/Resources/DirectSitesHelper"
rtk xcrun swiftc -swift-version 6 -warnings-as-errors -module-cache-path "$TMPDIR/DirectSitesModuleCache" -target arm64-apple-macosx14.0 -O Source/Core.swift Source/ProxyRouting.swift Source/Favicon.swift Source/Migration.swift Source/ChromeSetup.swift Source/App.swift -o "$app/Contents/MacOS/DirectSites" -framework AppKit
rtk cp Source/Info.plist "$app/Contents/Info.plist"
rtk cp -R Source/ru.lproj Source/en.lproj "$app/Contents/Resources/"
rtk ditto ChromeExtension "$app/Contents/Resources/ChromeExtension"
rtk xcrun swiftc -swift-version 6 -warnings-as-errors -parse-as-library -module-cache-path "$TMPDIR/DirectSitesModuleCache" Source/Icon.swift -o "$TMPDIR/DirectSitesIcon" -framework AppKit
rtk "$TMPDIR/DirectSitesIcon" "$TMPDIR/DirectSites.iconset"
rtk iconutil -c icns "$TMPDIR/DirectSites.iconset" -o "$app/Contents/Resources/AppIcon.icns"
rtk cp "$TMPDIR/DirectSites.iconset/icon_512x512@2x.png" "$PWD/AppIcon.png"
rtk codesign --force --sign - "$app/Contents/Resources/DirectSitesHelper"
rtk codesign --force --sign - "$app"
rtk codesign --verify --deep --strict "$app"
rtk plutil -lint "$app/Contents/Info.plist"
# Refresh the bundle date so macOS invalidates icon metadata after an update.
rtk touch "$app"
rtk ditto --norsrc "$app" "$PWD/Direct Sites.app"
rtk ditto -c -k --norsrc --keepParent "$app" "$PWD/Direct Sites.zip"
