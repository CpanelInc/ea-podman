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
Requires:       podman-docker

Source0:        ea-podman

%description
Ensures container based EA4 packages have podman available as well as any common helpers.

%build
echo "Nothing to build"

%install
%{__mkdir_p} %{buildroot}/usr/local/cpanel/scripts
install %{SOURCE0} %{buildroot}/usr/local/cpanel/scripts/ea-podman

%clean
rm -rf %{buildroot}

%files
%attr(0755,root,root) /usr/local/cpanel/scripts/ea-podman

%changelog
* Wed Jan 12 2022 Daniel Muey <dan@cpanel.net> - 1.0-1
- ZC-9618: Initial version
