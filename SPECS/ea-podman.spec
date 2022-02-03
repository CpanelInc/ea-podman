Name:           ea-podman
Version:        1.0
# Doing release_prefix this way for Release allows for OBS-proof versioning, See EA-4552 for more details
%define release_prefix 1
Release:        %{release_prefix}%{?dist}.cpanel
Summary:        Bring in podman and helpers for container based EA4 packages
License:        GPL
Group:          System Environment/Libraries
URL:            http://www.cpanel.net
Vendor:         cPanel, Inc.
BuildRoot:      %{_tmppath}/%{name}-%{version}-%{release}-buildroot
Requires:       podman-docker >= 3
%if 0%{?rhel} == 7
Requires: ea-podman-repo
%endif

AutoReqProv:    no

Source0:        ea-podman.pl
Source1:        subids.pm
Source2:        util.pm

Source24:       ea-podman-adminbin
Source25:       ea-podman-adminbin.conf

Requires:       gcc-toolset-11
Requires:       libnsl2
Requires:       libnsl2-devel

%description
Ensures container based EA4 packages have podman available as well as any common helpers.

%build
echo "Nothing to build"

%install
mkdir -p %{buildroot}/usr/local/cpanel/scripts
ln -s /opt/cpanel/ea-podman/bin/ea-podman %{buildroot}/usr/local/cpanel/scripts/ea-podman

mkdir -p %{buildroot}/opt/cpanel/ea-podman/bin
install %{SOURCE0} %{buildroot}/opt/cpanel/ea-podman/bin/ea-podman.pl

mkdir -p %{buildroot}/opt/cpanel/ea-podman/lib/ea_podman
install %{SOURCE1} %{buildroot}/opt/cpanel/ea-podman/lib/ea_podman/subids.pm
install %{SOURCE2} %{buildroot}/opt/cpanel/ea-podman/lib/ea_podman/util.pm

cp -f %{SOURCE24} .
cp -f %{SOURCE25} .

mkdir -p %{buildroot}/usr/local/cpanel/bin/admin/Cpanel
install -p %{SOURCE24} %{buildroot}/usr/local/cpanel/bin/admin/Cpanel/ea_podman
install -p %{SOURCE25} %{buildroot}/usr/local/cpanel/bin/admin/Cpanel/ea_podman.conf

%post

cd /opt/cpanel/ea-podman/bin
# Prep for calling perlcc
CPANEL_PERLCC=/usr/local/cpanel/3rdparty/perl/532/bin/perlcc
CC_OPTIMIZATIONS=--Wc='-Os -s'
PERLCC_OPTS="-v4 -UO -UB::Stash -UTie::Hash::NamedCapture -L /usr/lib64"
PERLCC_DORMANT_OPTS="${PERLCC_OPTS} -UB -Uwarnings"
$CPANEL_PERLCC $CC_OPTIMIZATIONS $PERLCC_DORMANT_OPTS ea-podman.pl -o ea-podman
cd -

#chmod a+x /opt/cpanel/ea-podman/bin/ea-podman

%clean
rm -rf %{buildroot}

%files
/opt/cpanel/ea-podman/
/usr/local/cpanel/scripts/ea-podman
/usr/local/cpanel/bin/admin/Cpanel/ea_podman
/usr/local/cpanel/bin/admin/Cpanel/ea_podman.conf

%changelog
* Wed Jan 19 2022 Dan Muey <dan@cpanel.net> - 1.0-2
- ZC-9651: Require podman be minimum v3

* Wed Jan 12 2022 Daniel Muey <dan@cpanel.net> - 1.0-1
- ZC-9618: Initial version
