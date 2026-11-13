# Settings for dmgbuild, used by scripts/make-dmg.sh:
#
#   dmgbuild -s scripts/dmg-settings.py -D app=… -D background=… -D icon=… \
#     "Claude Ring" build/dist/ClaudeRing-<version>.dmg
#
# dmgbuild runs this file with `defines` holding the -D values. It writes the
# window layout (.DS_Store) itself, without Finder or AppleScript.
#
# The update function attaches the DMG read-only and expects "Claude Ring.app"
# at the top level (ClaudeRing/Update/UpdateInstaller.swift); make-dmg.sh
# checks that after the build. Positions are in points from the top left of the
# window content and must match scripts/render-dmg-background.swift.

app = defines["app"]  # noqa: F821
background = defines["background"]  # noqa: F821
icon = defines["icon"]  # noqa: F821  (becomes .VolumeIcon.icns)

# HFS+ is what Finder's background picture was made for; zlib at level 9 as
# before.
filesystem = "HFS+"
format = "UDZO"
compression_level = 9

files = [(app, "Claude Ring.app")]
symlinks = {"Programme": "/Applications"}

# Finder counts the title bar (32 pt since macOS 11) in the stored window size,
# so 512 pt make 640 × 480 pt of window content. The position is measured from
# the bottom left of the screen; Finder moves the window onto the screen.
window_rect = ((200, 640), (640, 512))
default_view = "icon-view"
include_icon_view_settings = True
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False

icon_size = 128
text_size = 13
label_pos = "bottom"
icon_locations = {
    "Claude Ring.app": (160, 148),
    "Programme": (480, 148),
}
