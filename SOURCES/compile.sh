#!/bin/bash

set -x

if [ "$EUID" -ne 0 ]; then
    echo "Execute as root"
    exit 1
fi

echo "Compiling ea-podman"

cd /opt/cpanel/ea-podman/bin
# Prep for calling perlcc
CPANEL_PERLCC=/usr/local/cpanel/3rdparty/bin/perlcc
CC_OPTIMIZATIONS=--Wc='-Os'
PERLCC_OPTS="-v4 -UO -UB::Stash -UTie::Hash::NamedCapture -L /usr/lib64"
PERLCC_DORMANT_OPTS="${PERLCC_OPTS} -UB"
$CPANEL_PERLCC $CC_OPTIMIZATIONS $PERLCC_DORMANT_OPTS ea-podman.pl -o ea-podman
cd -

