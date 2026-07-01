#!/bin/sh
# repack-icon-themes.sh — repackage Ubuntu's adwaita-icon-theme + hicolor-icon-theme as
# rootless iOS (/var/jb) debs for the X11/GNOME-on-iOS repo. These are PURE DATA packages
# (SVG/PNG + index.theme; no compile), arch-neutral upstream, so we just relocate the prefix
# /usr -> /var/jb/usr, rewrite the control to the Procursus rootless convention, and add a
# postinst that rebuilds the GTK icon cache. Every GTK3/GTK4/libadwaita app hard-needs Adwaita
# for its symbolic (open-menu-symbolic etc.) + colour icons; without it GTK draws the
# broken-image placeholder. Adwaita Inherits=hicolor, so hicolor-icon-theme ships too.
#
# Run INSIDE the procursus-xbuild image (has dpkg-deb + wget/curl), writing to /out:
#   docker run --rm -v "$PWD/out:/out" -v "$PWD/repack-icon-themes.sh:/r.sh:ro" \
#     --entrypoint sh procursus-xbuild:bookworm-arm64 /r.sh
set -e
OUT=/out
WORK=/tmp/icons; rm -rf "$WORK"; mkdir -p "$WORK"; cd "$WORK"

# Ubuntu 24.04 (noble) versions — match our GNOME 46 stack; the payload is arch-neutral data.
ADW_URL=http://archive.ubuntu.com/ubuntu/pool/main/a/adwaita-icon-theme/adwaita-icon-theme_46.0-1_all.deb
HIC_URL=http://archive.ubuntu.com/ubuntu/pool/main/h/hicolor-icon-theme/hicolor-icon-theme_0.17-2_all.deb

fetch() { wget -q "$1" -O "$2" 2>/dev/null || curl -fsSL "$1" -o "$2"; }
echo "==> fetching upstream data debs"
fetch "$ADW_URL" adwaita.deb
fetch "$HIC_URL" hicolor.deb

MAINT="Max Leiter <maxwell.leiter@gmail.com>"

repack() {  # $1=srcdeb $2=pkg $3=version $4=depends $5=iconsubdir $6=description
  src="$1"; pkg="$2"; ver="$3"; deps="$4"; sub="$5"; desc="$6"
  echo "==> repack $pkg $ver"
  rm -rf t; dpkg-deb -R "$src" t
  mkdir -p t/var/jb; mv t/usr t/var/jb/usr           # /usr -> /var/jb/usr
  cat > t/DEBIAN/control <<EOF
Package: $pkg
Version: $ver
Architecture: iphoneos-arm64
Maintainer: $MAINT
Section: x11
Priority: optional
Depends: $deps
Description: $desc
EOF
  # trim the trailing "Depends:" line if there are no deps (empty value is invalid)
  [ -n "$deps" ] || sed -i '/^Depends: *$/d' t/DEBIAN/control
  cat > t/DEBIAN/postinst <<EOF
#!/bin/sh
set -e
export PATH=/var/jb/usr/bin:/var/jb/bin:/usr/bin:/bin:\$PATH
DIR=/var/jb/usr/share/icons/$sub
for u in gtk4-update-icon-cache gtk-update-icon-cache; do
  if command -v "\$u" >/dev/null 2>&1; then "\$u" -q -t -f "\$DIR" 2>/dev/null || true; break; fi
done
exit 0
EOF
  chmod 0755 t/DEBIAN/postinst
  rm -f t/DEBIAN/preinst t/DEBIAN/prerm t/DEBIAN/postrm t/DEBIAN/triggers t/DEBIAN/conffiles
  ( cd t && find var -type f -exec md5sum {} \; > DEBIAN/md5sums ) 2>/dev/null || true
  deb="$OUT/${pkg}_${ver}_iphoneos-arm64.deb"
  dpkg-deb -b t "$deb" >/dev/null
  echo "   -> $(basename "$deb")"; dpkg-deb -f "$deb" Package Version Architecture Depends | sed 's/^/      /'
}

repack hicolor.deb hicolor-icon-theme 0.17 "" hicolor \
  "Default fallback icon theme (hicolor base for all icon themes)"
repack adwaita.deb adwaita-icon-theme 46.0 "hicolor-icon-theme" Adwaita \
  "Adwaita icon theme - GNOME default symbolic + colour icons for GTK3/GTK4/libadwaita apps"

echo "==> verify Adwaita ships the symbolic icons the header bars need"
dpkg-deb -c "$OUT/adwaita-icon-theme_46.0_iphoneos-arm64.deb" \
  | grep -E "open-menu-symbolic|view-more-symbolic|index.theme" | head
echo "==> done"
