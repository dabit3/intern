on run arguments
  set mountPath to item 1 of arguments
  set installerFolder to POSIX file mountPath as alias
  tell application "Finder"
    set installerWindow to make new Finder window
    set target of installerWindow to installerFolder
    tell installerWindow
      set current view to icon view
      set toolbar visible to false
      set statusbar visible to false
      set bounds to {200, 140, 860, 588}
    end tell
    set viewOptions to icon view options of installerWindow
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 104
    set text size of viewOptions to 14
    set installerDisk to target of installerWindow
    set background picture of viewOptions to file ".background:background.tiff" of installerDisk
    set position of item "Intern.app" of installerDisk to {180, 210}
    set position of item "Applications" of installerDisk to {480, 210}
    update installerDisk without registering applications
    delay 2
    close installerWindow
  end tell
end run
