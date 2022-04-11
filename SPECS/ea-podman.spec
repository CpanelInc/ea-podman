Name:           ea-podman
Version:        1.0
# Doing release_prefix this way for Release allows for OBS-proof versioning, See EA-4552 for more details
%define release_prefix 5
Release:        %{release_prefix}%{?dist}.cpanel
Summary:        Bring in podman and helpers for container based EA4 packages
License:        GPL
Group:          System Environment/Libraries
URL:            http://www.cpanel.net
Vendor:         cPanel, Inc.
BuildRoot:      %{_tmppath}/%{name}-%{version}-%{release}-buildroot
Requires:       podman-docker >= 3
%if 0%{?rhel} >= 7
Requires: ea-podman-repo
%endif

AutoReqProv:    no

Source0:        ea-podman.pl
Source1:        subids.pm
Source2:        util.pm

Source3:       ea-podman-adminbin
Source4:       ea-podman-adminbin.conf

Source5:       pkg.postinst
Source6:       pkg.prerm
Source7:       compile.sh
Source8:       PodmanHooks.pm
Source9:       pkg.preinst

%if 0%{?rhel} >= 8
Requires:       gcc-toolset-11
Requires:       libnsl2
Requires:       libnsl2-devel
%endif

%description
Ensures container based EA4 packages have podman available as well as any common helpers.

%build
echo "Nothing to build"

%pre

%include %{SOURCE9}

%preun

%include %{SOURCE6}

%install
mkdir -p %{buildroot}/usr/local/cpanel/scripts
ln -s /opt/cpanel/ea-podman/bin/ea-podman %{buildroot}/usr/local/cpanel/scripts/ea-podman

mkdir -p %{buildroot}/opt/cpanel/ea-podman/bin
install %{SOURCE0} %{buildroot}/opt/cpanel/ea-podman/bin/ea-podman.pl

mkdir -p %{buildroot}/opt/cpanel/ea-podman/lib/ea_podman
install %{SOURCE1} %{buildroot}/opt/cpanel/ea-podman/lib/ea_podman/subids.pm
install %{SOURCE2} %{buildroot}/opt/cpanel/ea-podman/lib/ea_podman/util.pm

cp -f %{SOURCE3} .
cp -f %{SOURCE4} .
cp -f %{SOURCE8} .

mkdir -p %{buildroot}/usr/local/cpanel/bin/admin/Cpanel
install -p %{SOURCE3} %{buildroot}/usr/local/cpanel/bin/admin/Cpanel/ea_podman
install -p %{SOURCE4} %{buildroot}/usr/local/cpanel/bin/admin/Cpanel/ea_podman.conf

install %{SOURCE7} %{buildroot}/opt/cpanel/ea-podman/bin

mkdir -p %{buildroot}/var/cpanel/perl5/lib
install -p %{SOURCE8} %{buildroot}/var/cpanel/perl5/lib/PodmanHooks.pm

echo "{}" > %{buildroot}/opt/cpanel/ea-podman/registered-containers.json

%post

%include %{SOURCE5}

%clean
rm -rf %{buildroot}

%files
/opt/cpanel/ea-podman/
/usr/local/cpanel/scripts/ea-podman
%attr(0755,root,root) /usr/local/cpanel/bin/admin/Cpanel/ea_podman
%attr(0744,root,root) /usr/local/cpanel/bin/admin/Cpanel/ea_podman.conf
%attr(0600,root,root) /opt/cpanel/ea-podman/registered-containers.json
%attr(0700,root,root) /opt/cpanel/ea-podman/bin/compile.sh
%attr(0755, root, root) /var/cpanel/perl5/lib/PodmanHooks.pm

%changelog
* Mon Apr 11 2022 Dan Muey <dan@cpanel.net> - 1.0-5
- ZC-9916: Do not rely on perlcc symlink since it can be missing

* Mon Apr 04 2022 Julian Brown <julian.brown@cpanel.net> - 1.0-4
- ZC-9887: Fix error message for command list
           Fixed a bug in hooks on remove user

* Fri Mar 25 2022 Julian Brown <julian.brown@cpanel.net> - 1.0-3
- ZC-9873: Implement upgrade_containers command.

* Wed Jan 19 2022 Dan Muey <dan@cpanel.net> - 1.0-2
- ZC-9651: Require podman be minimum v3

* Wed Jan 12 2022 Daniel Muey <dan@cpanel.net> - 1.0-1
- ZC-9618: Initial version
