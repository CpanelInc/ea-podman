#!/bin/bash

source debian/vars.sh

set -x

mkdir -p $DEB_INSTALL_ROOT/usr/local/cpanel/scripts
ln -s /opt/cpanel/ea-podman/bin/ea-podman $DEB_INSTALL_ROOT/usr/local/cpanel/scripts/ea-podman
mkdir -p $DEB_INSTALL_ROOT/opt/cpanel/ea-podman/bin
install $SOURCE0 $DEB_INSTALL_ROOT/opt/cpanel/ea-podman/bin/ea-podman.pl
mkdir -p $DEB_INSTALL_ROOT/opt/cpanel/ea-podman/lib/ea_podman
install $SOURCE1 $DEB_INSTALL_ROOT/opt/cpanel/ea-podman/lib/ea_podman/subids.pm
install $SOURCE2 $DEB_INSTALL_ROOT/opt/cpanel/ea-podman/lib/ea_podman/util.pm
cp -f $SOURCE24 .
cp -f $SOURCE25 .
mkdir -p $DEB_INSTALL_ROOT/usr/local/cpanel/bin/admin/Cpanel
install -p $SOURCE24 $DEB_INSTALL_ROOT/usr/local/cpanel/bin/admin/Cpanel/ea_podman
install -p $SOURCE25 $DEB_INSTALL_ROOT/usr/local/cpanel/bin/admin/Cpanel/ea_podman.conf

# so that our install file works
echo "BEFORE"
ls -ld ./*

cp $SOURCE0  .
cp $SOURCE1  .
cp $SOURCE2  .
cp $SOURCE24 ./ea_podman
cp $SOURCE25 ./ea_podman.conf

echo "HERE"
ls -ld ./*
cat -n debian/ea-podman.install

