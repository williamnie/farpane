FarPane native RPM development candidate @VERSION@-@RELEASE@
Artifact: @ARTIFACT@

This package includes the GTK4 GUI, native core, bundled media, icons and
maintenance tools. It does not require the original RustDesk or host FFmpeg.
It is a third-party development candidate, not an official Fedora repository
package or a completed public-release/license review.

RPM owns only /usr/lib64/farpane-native-candidate, two maintenance entrypoints
and this documentation. It has no install/upgrade/removal scriptlets. Installing
or upgrading the RPM does not stage /opt releases, restart a service, register
an online identity, open a window, or change user desktop integration.

Linux 6.5+, a supported graphical desktop and distribution graphics drivers are
required. Minimum GUI API: GTK 4.14, libadwaita 1.5, GLib 2.80, glibc 2.39.
Container checks do not validate Fedora's own kernel, SELinux, systemd login,
GNOME/KDE/Wayland, hardware audio, GPU capability or remote Mac input.

Once an explicit maintenance window is available:

1. Stage the verified candidate with the root maintenance tool:
   sudo farpane-maintenance stage /usr/lib64/farpane-native-candidate/payload
   Staging verifies and copies the release; it does not activate it.

2. Follow the exact-version plan/activate commands in the included
   native-install.md. Use farpane-maintenance in place of its source-tree
   python3 -B Scripts/linux/install-native.py command. Inspect the plan first.
   Activation may interrupt existing FarPane sessions. Keep the previous release
   for rollback. Do not replace a running executable or only change a symlink.

3. As the ordinary desktop user, follow the user-integration section of
   native-install.md, using farpane-user-integration in place of its source-tree
   python3 -B Scripts/linux/install-native-user.py command. Preserve unknown files and the
   existing RustDesk application and configuration.

Removing this RPM removes the candidate/tools it owns; independently staged or
activated /opt/farpane releases, active service, identity, credentials and user
integration are retained. Use the existing maintenance workflow for any explicit
rollback or removal of an activated release. No service is stopped automatically.

The RPM License field follows FarPane's declared AGPL-3.0-only project license.
Original third-party notices and declarations are retained under payload/licenses.
The candidate metadata still records complete_license_source_audit=false; this
package does not resolve missing third-party declarations or source obligations.
The matching complete application source snapshot and this packaging recipe must
accompany a future published candidate. No publishing action is performed here.
