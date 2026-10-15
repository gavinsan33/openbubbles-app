# Repackages the prebuilt Flutter bundle from linux/build.sh; built by linux/rpm/release.sh,
# which passes app_version and app_release (pubspec version and build number).

%global appdir /opt/openbubbles
# nothing is compiled here, and stripping would damage the Dart AOT library (libapp.so)
%global debug_package %{nil}
%global __strip /bin/true
%global _build_id_links none
# no changelog section: versions come from pubspec
%global source_date_epoch_from_changelog 0
# the bundled libraries load through the binary's $ORIGIN/lib rpath: don't advertise them to
# the system, and don't require them from it
%global __provides_exclude_from ^%{appdir}/.*$
%global __requires_exclude ^lib(app|flutter_linux_gtk|objectbox|pdfium|rust_lib_bluebubbles|media_kit_native_event_loop|super_native_extensions|[a-z0-9_]+_plugin)\\.so.*$

Name:           openbubbles
Version:        %{app_version}
Release:        %{app_release}
Summary:        iMessage client
License:        Apache-2.0
URL:            https://github.com/gavinsan33/openbubbles-app
ExclusiveArch:  x86_64 aarch64

Source0:        bluebubbles-linux-%{_arch}.tar
Source1:        app.openbubbles.OpenBubbles.desktop
Source2:        app.openbubbles.OpenBubbles.metainfo.xml
Source3:        128x128.png

%description
OpenBubbles sends and receives iMessages, either by registering with Apple
itself or through a paired Android phone on the same network.

%prep
%setup -q -c -T
tar -xf %{SOURCE0}

%install
mkdir -p %{buildroot}%{appdir} %{buildroot}%{_bindir}
cp -a bluebubbles data lib %{buildroot}%{appdir}/
ln -s ../../opt/openbubbles/bluebubbles %{buildroot}%{_bindir}/openbubbles

install -Dm644 %{SOURCE1} %{buildroot}%{_datadir}/applications/app.openbubbles.OpenBubbles.desktop
# GTK names the window (Wayland app_id) after the command it was started as, so launching
# `openbubbles` keeps it matching the entry's StartupWMClass=openbubbles and the dock finds the icon
sed -i 's|^Exec=.*|Exec=openbubbles|' %{buildroot}%{_datadir}/applications/app.openbubbles.OpenBubbles.desktop
install -Dm644 %{SOURCE2} %{buildroot}%{_metainfodir}/app.openbubbles.OpenBubbles.metainfo.xml
install -Dm644 %{SOURCE3} %{buildroot}%{_datadir}/icons/hicolor/128x128/apps/app.openbubbles.OpenBubbles.png

%files
%{appdir}
%{_bindir}/openbubbles
%{_datadir}/applications/app.openbubbles.OpenBubbles.desktop
%{_metainfodir}/app.openbubbles.OpenBubbles.metainfo.xml
%{_datadir}/icons/hicolor/128x128/apps/app.openbubbles.OpenBubbles.png
