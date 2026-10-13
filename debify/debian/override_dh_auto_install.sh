#!/bin/bash

source debian/vars.sh

set -x

# Stage every shipped file into debian/tmp ($DEB_INSTALL_ROOT) at its full
# installed path, mirroring the RPM spec's %install. settings.json sets
# dont_relativise_ontar. debian/ea-podman.install is a committed manifest (see
# the comment at its top), so a file added here must be added there too.

# CLI + libs under /opt/cpanel/ea-podman
mkdir -p $DEB_INSTALL_ROOT/opt/cpanel/ea-podman/bin
install $SOURCE0  $DEB_INSTALL_ROOT/opt/cpanel/ea-podman/bin/ea-podman.pl
install -m 0755 $SOURCE0 $DEB_INSTALL_ROOT/opt/cpanel/ea-podman/bin/ea-podman    # the CLI, uncompiled (EA4-315)
install $SOURCE10 $DEB_INSTALL_ROOT/opt/cpanel/ea-podman/bin/_update-public-hub-to-internal-hub
install $SOURCE22 $DEB_INSTALL_ROOT/opt/cpanel/ea-podman/webapp-dir-setup

mkdir -p $DEB_INSTALL_ROOT/opt/cpanel/ea-podman/lib/ea_podman
install $SOURCE1 $DEB_INSTALL_ROOT/opt/cpanel/ea-podman/lib/ea_podman/subids.pm
install $SOURCE2 $DEB_INSTALL_ROOT/opt/cpanel/ea-podman/lib/ea_podman/util.pm

echo "{}" > $DEB_INSTALL_ROOT/opt/cpanel/ea-podman/registered-containers.json

# Canonical CLI path: symlink into cPanel's scripts dir. Created here (and
# excluded from the manifest via remove_from_install) so it ships as a symlink,
# not a copy of the target.
mkdir -p $DEB_INSTALL_ROOT/usr/local/cpanel/scripts
ln -s /opt/cpanel/ea-podman/bin/ea-podman $DEB_INSTALL_ROOT/usr/local/cpanel/scripts/ea-podman

# Admin module (EA4-315) and the ea_podman addon feature. install renames each
# source to its required name.
mkdir -p $DEB_INSTALL_ROOT/usr/local/cpanel/Cpanel/Admin/Modules/Cpanel
install -p -m 0644 $SOURCE24 $DEB_INSTALL_ROOT/usr/local/cpanel/Cpanel/Admin/Modules/Cpanel/ea_podman.pm
mkdir -p $DEB_INSTALL_ROOT/usr/local/cpanel/whostmgr/addonfeatures
install -p -m 0644 $SOURCE25 $DEB_INSTALL_ROOT/usr/local/cpanel/whostmgr/addonfeatures/ea_podman

# UAPI module. install renames SOURCE12 (Cpanel-API-EAPodman.pm) to the
# required name.
mkdir -p $DEB_INSTALL_ROOT/usr/local/cpanel/Cpanel/API
install -p -m 0644 $SOURCE12 $DEB_INSTALL_ROOT/usr/local/cpanel/Cpanel/API/EAPodman.pm

# OpenAPI documents for the EAPodman UAPI verbs, shipped alongside the module.
install -p -m 0644 $SOURCE13 $DEB_INSTALL_ROOT/usr/local/cpanel/Cpanel/API/EAPodman-list.openapi.yaml
install -p -m 0644 $SOURCE14 $DEB_INSTALL_ROOT/usr/local/cpanel/Cpanel/API/EAPodman-install.openapi.yaml
install -p -m 0644 $SOURCE15 $DEB_INSTALL_ROOT/usr/local/cpanel/Cpanel/API/EAPodman-upgrade.openapi.yaml
install -p -m 0644 $SOURCE16 $DEB_INSTALL_ROOT/usr/local/cpanel/Cpanel/API/EAPodman-uninstall.openapi.yaml
install -p -m 0644 $SOURCE17 $DEB_INSTALL_ROOT/usr/local/cpanel/Cpanel/API/EAPodman-start.openapi.yaml
install -p -m 0644 $SOURCE18 $DEB_INSTALL_ROOT/usr/local/cpanel/Cpanel/API/EAPodman-stop.openapi.yaml
install -p -m 0644 $SOURCE19 $DEB_INSTALL_ROOT/usr/local/cpanel/Cpanel/API/EAPodman-restart.openapi.yaml
install -p -m 0644 $SOURCE20 $DEB_INSTALL_ROOT/usr/local/cpanel/Cpanel/API/EAPodman-status.openapi.yaml
install -p -m 0644 $SOURCE21 $DEB_INSTALL_ROOT/usr/local/cpanel/Cpanel/API/EAPodman-cmd.openapi.yaml

# cPanel hooks module
mkdir -p $DEB_INSTALL_ROOT/var/cpanel/perl5/lib
install -p $SOURCE8 $DEB_INSTALL_ROOT/var/cpanel/perl5/lib/PodmanHooks.pm

# Boot-time sweep that starts the per-user systemd managers rootless podman
# needs; see the unit itself and EA4-319.
mkdir -p $DEB_INSTALL_ROOT/usr/lib/systemd/system
install -p -m 0644 $SOURCE23 $DEB_INSTALL_ROOT/usr/lib/systemd/system/ea-podman-user-managers.service
