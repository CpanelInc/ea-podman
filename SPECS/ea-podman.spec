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
AutoReqProv:    no

Source0:        ea-podman
Source1:        ea-podman.sh

%description
Ensures container based EA4 packages have podman available as well as any common helpers.

%build
echo "Nothing to build"

%install
mkdir -p %{buildroot}/usr/local/cpanel/scripts
install %{SOURCE0} %{buildroot}/usr/local/cpanel/scripts/ea-podman

mkdir -p %{buildroot}/opt/cpanel/ea-podman
install %{SOURCE1} %{buildroot}/opt/cpanel/ea-podman/ea-podman.sh

%clean
rm -rf %{buildroot}

%files
%attr(0755,root,root) /usr/local/cpanel/scripts/ea-podman
%attr(0755,root,root) /opt/cpanel/ea-podman/ea-podman.sh

%changelog
* Wed Jan 19 2022 Dan Muey <dan@cpanel.net> - 1.0-2
- ZC-9651: Require podman be minimum v3

* Wed Jan 12 2022 Daniel Muey <dan@cpanel.net> - 1.0-1
- ZC-9618: Initial version
