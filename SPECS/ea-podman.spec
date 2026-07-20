Name:           ea-podman
Version:        1.0
# Doing release_prefix this way for Release allows for OBS-proof versioning, See EA-4552 for more details
%define release_prefix 22
Release:        %{release_prefix}%{?dist}.cpanel
Summary:        Bring in podman and helpers for container based EA4 packages
License:        GPL
Group:          System Environment/Libraries
URL:            http://www.cpanel.net
Vendor:         cPanel, Inc.
BuildRoot:      %{_tmppath}/%{name}-%{version}-%{release}-buildroot
Requires:       podman-docker >= 3
Requires:       systemd-container
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
Source10:      _update-public-hub-to-internal-hub
Source11:      EAPodman.pm
Source12:      Cpanel-API-EAPodman.pm

# OpenAPI documents for the EAPodman UAPI verbs; shipped next to the module in
# /usr/local/cpanel/Cpanel/API/ as <Module>-<method>.openapi.yaml (CPANEL-54143).
Source13:      EAPodman-list.openapi.yaml
Source14:      EAPodman-install.openapi.yaml
Source15:      EAPodman-upgrade.openapi.yaml
Source16:      EAPodman-uninstall.openapi.yaml
Source17:      EAPodman-start.openapi.yaml
Source18:      EAPodman-stop.openapi.yaml
Source19:      EAPodman-restart.openapi.yaml
Source20:      EAPodman-status.openapi.yaml
Source21:      EAPodman-cmd.openapi.yaml

# Install-time hook for the cpanel-webapp-plugin: moves a staged web
# application into its new container's directory (--webapp-dir, CPANEL-54441).
Source22:      webapp-dir-setup
%if 0%{?rhel} == 8
Requires:       gcc-toolset-11
%endif

%if 0%{?rhel} == 9
Requires:       gcc >= 11
%endif

%if 0%{?rhel} >= 8
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

mkdir -p %{buildroot}/usr/local/cpanel/install
install %{SOURCE11} %{buildroot}/usr/local/cpanel/install/EAPodman.pm

mkdir -p %{buildroot}/usr/local/cpanel/Cpanel/API
install %{SOURCE12} %{buildroot}/usr/local/cpanel/Cpanel/API/EAPodman.pm

# OpenAPI documents for the EAPodman UAPI verbs, shipped alongside the module.
install -p -m 0644 %{SOURCE13} %{buildroot}/usr/local/cpanel/Cpanel/API/EAPodman-list.openapi.yaml
install -p -m 0644 %{SOURCE14} %{buildroot}/usr/local/cpanel/Cpanel/API/EAPodman-install.openapi.yaml
install -p -m 0644 %{SOURCE15} %{buildroot}/usr/local/cpanel/Cpanel/API/EAPodman-upgrade.openapi.yaml
install -p -m 0644 %{SOURCE16} %{buildroot}/usr/local/cpanel/Cpanel/API/EAPodman-uninstall.openapi.yaml
install -p -m 0644 %{SOURCE17} %{buildroot}/usr/local/cpanel/Cpanel/API/EAPodman-start.openapi.yaml
install -p -m 0644 %{SOURCE18} %{buildroot}/usr/local/cpanel/Cpanel/API/EAPodman-stop.openapi.yaml
install -p -m 0644 %{SOURCE19} %{buildroot}/usr/local/cpanel/Cpanel/API/EAPodman-restart.openapi.yaml
install -p -m 0644 %{SOURCE20} %{buildroot}/usr/local/cpanel/Cpanel/API/EAPodman-status.openapi.yaml
install -p -m 0644 %{SOURCE21} %{buildroot}/usr/local/cpanel/Cpanel/API/EAPodman-cmd.openapi.yaml

mkdir -p %{buildroot}/opt/cpanel/ea-podman/bin
install %{SOURCE0} %{buildroot}/opt/cpanel/ea-podman/bin/ea-podman.pl
install %{SOURCE10} %{buildroot}/opt/cpanel/ea-podman/bin/_update-public-hub-to-internal-hub

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

install %{SOURCE22} %{buildroot}/opt/cpanel/ea-podman/webapp-dir-setup

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
%attr(0700,root,root) /opt/cpanel/ea-podman/bin/_update-public-hub-to-internal-hub
%attr(0755,root,root) /opt/cpanel/ea-podman/webapp-dir-setup
%attr(0755, root, root) /var/cpanel/perl5/lib/PodmanHooks.pm
%attr(0644, root, root) /usr/local/cpanel/install/EAPodman.pm
%attr(0644, root, root) /usr/local/cpanel/Cpanel/API/EAPodman.pm
%attr(0644, root, root) /usr/local/cpanel/Cpanel/API/EAPodman-list.openapi.yaml
%attr(0644, root, root) /usr/local/cpanel/Cpanel/API/EAPodman-install.openapi.yaml
%attr(0644, root, root) /usr/local/cpanel/Cpanel/API/EAPodman-upgrade.openapi.yaml
%attr(0644, root, root) /usr/local/cpanel/Cpanel/API/EAPodman-uninstall.openapi.yaml
%attr(0644, root, root) /usr/local/cpanel/Cpanel/API/EAPodman-start.openapi.yaml
%attr(0644, root, root) /usr/local/cpanel/Cpanel/API/EAPodman-stop.openapi.yaml
%attr(0644, root, root) /usr/local/cpanel/Cpanel/API/EAPodman-restart.openapi.yaml
%attr(0644, root, root) /usr/local/cpanel/Cpanel/API/EAPodman-status.openapi.yaml
%attr(0644, root, root) /usr/local/cpanel/Cpanel/API/EAPodman-cmd.openapi.yaml

%changelog
* Mon Jul 20 2026 Dan Muey <daniel.muey@webpros.com> - 1.0-22
- CPANEL-54441: move staged dir to container dir && add webapp to podman registry

* Tue Jul 14 2026 Julian Brown <julian.brown@webpros.com> - 1.0-21
- CPANEL-54672: Fall back to the EAPodman UAPI bridge when a direct CLI call
  can't see its own rootless runtime directory (CageFS + unrestricted shell)

* Mon Jul 13 2026 Julian Brown <julian.brown@webpros.com> - 1.0-20
- CPANEL-54037: Support jailshell and CageFS accounts through an EAPodman UAPI extension
- CPANEL-54143: Ship EAPodman UAPI OpenAPI documents
- CPANEL-54360: Add the EAPodman `cmd` verb — run a one-shot command in a container

* Fri Sep 19 2025 Dan Muey <daniel.muey@webpros.com> - 1.0-19
- EA4-125: Add `testbin` subcommand and add re-compile check to UPCP install module

* Tue Feb 11 2025 Dan Muey <daniel.muey@webpros.com> - 1.0-18
- ZC-12610: Add compat layer for ULC function that was removed

* Wed Jun 19 2024 Brian Mendoza <brian.mendoza@cpanel.net> - 1.0-17
- ZC-11748: Require systemd-container to allow management via WHM terminal

* Fri Oct 20 2023 Julian Brown <julian.brown@cpanel.net> - 1.0-16
- ZC-11296: Silence warning about insufficient UID/GID's.

* Mon Sep 25 2023 Julian Brown <julian.brown@cpanel.net> - 1.0-15
- ZC-11180: Make changes to allow pkgacct to backup a users containers

* Fri Sep 01 2023 Julian Brown <julian.brown@cpanel.net> - 1.0-14
- ZC-10612: Add container name to output, and add better messaging when ea-podman package is not installed

* Mon Jun 12 2023 Brian Mendoza <brian.mendoza@cpanel.net> - 1.0-13
- ZC-10958: Fix issue when uninstalling container packages when user doesn't exist anymore

* Fri Jun 02 2023 Julian Brown <julian.brown@cpanel.net> - 1.0-12
- ZC-10956: Revert newuidmap changes

* Fri Feb 03 2023 Julian Brown <julian.brown@cpanel.net> - 1.0-11
- ZC-10667: Change perms for nuewuidmap for Rocky 9

* Tue Oct 04 2022 Dan Muey <dan@cpanel.net> - 1.0-10
- ZC-10348: Updates for Alma 9 support

* Fri Jul 22 2022 Brian Mendoza <brian.mendoza@cpanel.net> - 1.0-9
- ZC-10113: Persist image name to registered-containers.json

* Wed Jul 13 2022 Cory McIntire <cory@cpanel.net> - 1.0-8
- EA-10834: Rolling “ea-podman” back to “547d2ef67731ef65145dd384c32ade79018f8180”: accidental merge to production

* Thu Jun 02 2022 Dan Muey <dan@cpanel.net> - 1.0-7
- ZC-9993: Add script for dev/QA/smold4r to be able to test against internal docker hub

* Mon Apr 25 2022 Julian Brown <julian.brown@cpanel.net> - 1.0-6
- ZC-9877: Add backup/restore sub commands, and manage backup exclude file
- ZC-9909: Add /scripts/removeacct Hook

* Mon Apr 11 2022 Dan Muey <dan@cpanel.net> - 1.0-5
- ZC-9925: cleanup /opt/cpanel/ea-podman/bin/ea-podman on all systems, not just apt based ones
- ZC-9916: Do not rely on perlcc symlink since it can be missing
- ZC-9917: if users can see each others' processes give advice about how to address that
- ZC-9917: make ~/ea-podman.d and ~/ea-podman.d/<CONTAINER-DIR> inaccessible to other users

* Mon Apr 04 2022 Julian Brown <julian.brown@cpanel.net> - 1.0-4
- ZC-9887: Fix error message for command list
           Fixed a bug in hooks on remove user

* Fri Mar 25 2022 Julian Brown <julian.brown@cpanel.net> - 1.0-3
- ZC-9873: Implement upgrade_containers command.

* Wed Jan 19 2022 Dan Muey <dan@cpanel.net> - 1.0-2
- ZC-9651: Require podman be minimum v3

* Wed Jan 12 2022 Daniel Muey <dan@cpanel.net> - 1.0-1
- ZC-9618: Initial version
