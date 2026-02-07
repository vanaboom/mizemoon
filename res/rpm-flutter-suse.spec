Name:       mizemoon
Version:    1.4.5
Release:    0
Summary:    RPM package
License:    GPL-3.0
URL:        https://mizemoon.ir
Vendor:     mizemoon <info@mizemoon.ir>
Requires:   gtk3 libxcb1 libXfixes3 alsa-utils libXtst6 libva2 pam gstreamer-plugins-base gstreamer-plugin-pipewire
Recommends: libayatana-appindicator3-1 xdotool
Provides:   libdesktop_drop_plugin.so()(64bit), libdesktop_multi_window_plugin.so()(64bit), libfile_selector_linux_plugin.so()(64bit), libflutter_custom_cursor_plugin.so()(64bit), libflutter_linux_gtk.so()(64bit), libscreen_retriever_plugin.so()(64bit), libtray_manager_plugin.so()(64bit), liburl_launcher_linux_plugin.so()(64bit), libwindow_manager_plugin.so()(64bit), libwindow_size_plugin.so()(64bit), libtexture_rgba_renderer_plugin.so()(64bit)

# https://docs.fedoraproject.org/en-US/packaging-guidelines/Scriptlets/

%description
The best open-source remote desktop client software, written in Rust.

%prep
# we have no source, so nothing here

%build
# we have no source, so nothing here

# %global __python %{__python3}

%install

mkdir -p "%{buildroot}/usr/share/mizemoon" && cp -r ${HBB}/flutter/build/linux/x64/release/bundle/* -t "%{buildroot}/usr/share/mizemoon"
mkdir -p "%{buildroot}/usr/bin"
install -Dm 644 $HBB/res/mizemoon.service -t "%{buildroot}/usr/share/mizemoon/files"
install -Dm 644 $HBB/res/mizemoon.desktop -t "%{buildroot}/usr/share/mizemoon/files"
install -Dm 644 $HBB/res/mizemoon-link.desktop -t "%{buildroot}/usr/share/mizemoon/files"
install -Dm 644 $HBB/res/128x128@2x.png "%{buildroot}/usr/share/icons/hicolor/256x256/apps/mizemoon.png"
install -Dm 644 $HBB/res/scalable.svg "%{buildroot}/usr/share/icons/hicolor/scalable/apps/mizemoon.svg"

%files
/usr/share/mizemoon/*
/usr/share/mizemoon/files/mizemoon.service
/usr/share/icons/hicolor/256x256/apps/mizemoon.png
/usr/share/icons/hicolor/scalable/apps/mizemoon.svg
/usr/share/mizemoon/files/mizemoon.desktop
/usr/share/mizemoon/files/mizemoon-link.desktop

%changelog
# let's skip this for now

%pre
# can do something for centos7
case "$1" in
  1)
    # for install
  ;;
  2)
    # for upgrade
    systemctl stop mizemoon || true
  ;;
esac

%post
cp /usr/share/mizemoon/files/mizemoon.service /etc/systemd/system/mizemoon.service
cp /usr/share/mizemoon/files/mizemoon.desktop /usr/share/applications/
cp /usr/share/mizemoon/files/mizemoon-link.desktop /usr/share/applications/
ln -sf /usr/share/mizemoon/mizemoon /usr/bin/mizemoon
systemctl daemon-reload
systemctl enable mizemoon
systemctl start mizemoon
update-desktop-database

%preun
case "$1" in
  0)
    # for uninstall
    systemctl stop mizemoon || true
    systemctl disable mizemoon || true
    rm /etc/systemd/system/mizemoon.service || true
  ;;
  1)
    # for upgrade
  ;;
esac

%postun
case "$1" in
  0)
    # for uninstall
    rm /usr/bin/mizemoon || true
    rmdir /usr/lib/mizemoon || true
    rmdir /usr/local/mizemoon || true
    rmdir /usr/share/mizemoon || true
    rm /usr/share/applications/mizemoon.desktop || true
    rm /usr/share/applications/mizemoon-link.desktop || true
    update-desktop-database
  ;;
  1)
    # for upgrade
    rmdir /usr/lib/mizemoon || true
    rmdir /usr/local/mizemoon || true
  ;;
esac
