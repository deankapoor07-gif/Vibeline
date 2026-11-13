# dmgbuild settings for the D-Jay Noodles download window (see tool/make_dmg.sh).
# Values passed in with -D: app (path to the .app), bg (background .tiff).
import os
app = defines["app"]
files = [app]
symlinks = {"Applications": "/Applications"}
hide_extensions = [os.path.basename(app)]
format = "ULMO"
filesystem = "HFS+"
background = defines["bg"]
window_rect = ((200, 160), (660, 400))
default_view = "icon-view"
show_status_bar = show_tab_view = show_toolbar = show_pathbar = show_sidebar = False
icon_size = 128
text_size = 13
icon_locations = {os.path.basename(app): (170, 200), "Applications": (490, 200)}
