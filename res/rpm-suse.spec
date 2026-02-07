Name:       mizemoon
Version:    1.1.9
Release:    0
Summary:    RPM package
License:    GPL-3.0
Requires:   gtk3 libxcb1 libXfixes3 alsa-utils libXtst6 libva2 pam gstreamer-plugins-base gstreamer-plugin-pipewire
Recommends: libayatana-appindicator3-1 xdotool

# https://docs.fedoraproject.org/en-US/packaging-guidelines/Scriptlets/

%description
The best open-source remote desktop client software, written in Rust.

%prep
# we have no source, so nothing here

%build
# we have no source, so nothing here

%global __python %{__python3}

%install
mkdir -p %{buildroot}/usr/bin/
mkdir -p %{buildroot}/usr/share/mizemoon/
mkdir -p %{buildroot}/usr/share/mizemoon/files/
mkdir -p %{buildroot}/usr/share/icons/hicolor/256x256/apps/
mkdir -p %{buildroot}/usr/share/icons/hicolor/scalable/apps/
install -m 755 $HBB/target/release/mizemoon %{buildroot}/usr/bin/mizemoon
install $HBB/libsciter-gtk.so %{buildroot}/usr/share/mizemoon/libsciter-gtk.so
install $HBB/res/mizemoon.service %{buildroot}/usr/share/mizemoon/files/
install $HBB/res/128x128@2x.png %{buildroot}/usr/share/icons/hicolor/256x256/apps/mizemoon.png
install $HBB/res/scalable.svg %{buildroot}/usr/share/icons/hicolor/scalable/apps/mizemoon.svg
install $HBB/res/mizemoon.desktop %{buildroot}/usr/share/mizemoon/files/
install $HBB/res/mizemoon-link.desktop %{buildroot}/usr/share/mizemoon/files/

%files
/usr/bin/mizemoon
/usr/share/mizemoon/libsciter-gtk.so
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
    rm /usr/share/applications/mizemoon.desktop || true
    rm /usr/share/applications/mizemoon-link.desktop || true
    update-desktop-database
  ;;
  1)
    # for upgrade
  ;;
esac
