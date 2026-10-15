#!/bin/bash
# Builds the Linux bundle, packages it as a signed RPM and publishes it to the dnf repository
# served from GitHub Pages (gavinsan33/openbubbles-rpm). The version comes from pubspec.yaml:
# bump its build number (the part after +) for every release, or dnf won't see an update.
#
#   linux/rpm/release.sh             build, package, publish
#   SKIP_BUILD=1 linux/rpm/release.sh    reuse bluebubbles-linux-<arch>.tar from linux/build.sh
#   NO_PUBLISH=1 linux/rpm/release.sh    stop after building and signing the RPM
#
# Needs rpm-build, rpm-sign, createrepo_c and the signing key in your GPG keyring.
set -euo pipefail

cd "$(dirname "$0")/../.."
root=$(pwd)

KEY=${OPENBUBBLES_RPM_KEY:-263DA61CD7D9F531226ACABFB081349D8D5305BF}
REPO_URL=${OPENBUBBLES_RPM_REPO_URL:-https://github.com/gavinsan33/openbubbles-rpm.git}
REPO_DIR=${OPENBUBBLES_RPM_REPO_DIR:-$root/build/openbubbles-rpm}
# releases kept in the repository: enough to roll back, few enough to stay small
KEEP=3

for tool in rpmbuild rpmsign createrepo_c gpg; do
    command -v $tool >/dev/null || { echo "missing $tool (dnf install rpm-build rpm-sign createrepo_c)"; exit 1; }
done
gpg --list-secret-keys "$KEY" >/dev/null 2>&1 || { echo "signing key $KEY isn't in your keyring"; exit 1; }

version_line=$(grep -m1 '^version:' pubspec.yaml | awk '{print $2}')
version=${version_line%%+*}
release=${version_line#*+}
arch=$(uname -m)
rpm_name=openbubbles-$version-$release.$arch.rpm

# a published version must never be rebuilt: dnf would keep the old package
if [ -z "${NO_PUBLISH:-}" ]; then
    rm -rf "$REPO_DIR"
    git clone -q --depth 1 "$REPO_URL" "$REPO_DIR"
    if [ -e "$REPO_DIR/$arch/$rpm_name" ]; then
        echo "$rpm_name is already published; bump the build number in pubspec.yaml"
        exit 1
    fi
fi

if [ -z "${SKIP_BUILD:-}" ]; then
    linux/build.sh
fi
tarball=$root/bluebubbles-linux-$arch.tar
[ -f "$tarball" ] || { echo "no $tarball; run linux/build.sh"; exit 1; }

top=$root/build/rpm
rm -rf "$top"
mkdir -p "$top/SOURCES"
cp "$tarball" flatpak/app.openbubbles.OpenBubbles.desktop flatpak/app.openbubbles.OpenBubbles.metainfo.xml flatpak/128x128.png "$top/SOURCES/"
rpmbuild -bb linux/rpm/openbubbles.spec \
    --define "_topdir $top" \
    --define "app_version $version" \
    --define "app_release $release"
rpm_path=$top/RPMS/$arch/$rpm_name
rpmsign --addsign --define "_gpg_name $KEY" "$rpm_path"
echo "built $rpm_path"

if [ -n "${NO_PUBLISH:-}" ]; then
    exit 0
fi

mkdir -p "$REPO_DIR/$arch"
cp "$rpm_path" "$REPO_DIR/$arch/"
# keep the newest releases only
ls "$REPO_DIR/$arch"/openbubbles-*.rpm | sort -V | head -n -$KEEP | xargs -r rm -f
createrepo_c --quiet --update "$REPO_DIR/$arch"
gpg --batch --yes --local-user "$KEY" --armor --detach-sign "$REPO_DIR/$arch/repodata/repomd.xml"

# publish as a single fresh commit: old packages would otherwise pile up in git history
cd "$REPO_DIR"
git checkout -q --orphan publish
git add -A
git commit -q -m "openbubbles $version-$release"
git push -q --force origin publish:main
echo "published $rpm_name"
