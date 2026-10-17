FarPane Linux native GUI test candidate @VERSION@
Candidate: @ARTIFACT@

This package includes the GTK4/libadwaita GUI, native core, static FFmpeg,
private libdrmtap, FarPane icons and the standalone maintenance tools.
Neither a RustDesk installation nor a host FFmpeg installation is required.
It is a development candidate, not an accepted public release.

Inspected third-party materials accompany the payload under
/usr/lib/farpane-native-candidate/payload/licenses/dependencies/README.txt.
The inventory preserves its unresolved records and is not a completed audit.

Requirements: x86_64, Linux 6.5+, Ubuntu 24.04/26.04-compatible runtime
libraries, a graphical user session and a systemd desktop for activation.
The package declares its direct runtime dependencies. Desktop notifications,
Secret Service, graphics drivers and Wayland portal/data-control support
depend on the desktop. Recommending gnome-keyring does not grant vault access.

Installation and upgrades ONLY copy this candidate to a private staging
directory. They do not stop/start/enable services, change current, open a
window, modify desktop entries, or migrate credentials. If staging detects
an unmanaged installation or unfinished transaction it refuses configuration;
inspect/recover the existing installation before retrying dpkg --configure.

After installation, review the exact previous release in /opt/farpane/current
(use the basename after releases/, or "none" on first installation):

  sudo farpane-maintenance plan @ARTIFACT@ --expect-current PREVIOUS

In an agreed maintenance window, after ending existing FarPane sessions:

  sudo farpane-maintenance activate @ARTIFACT@ --expect-current PREVIOUS --maintenance-window --start-service

Then, as the desktop user (not root), bind the menu, icons and D-Bus entry:

  farpane-user-integration bind @ARTIFACT@ --previous PREVIOUS

Open FarPane from the applications menu or /opt/farpane/farpane.
These tools preserve FarPane's existing identity/configuration; they never
import RustDesk credentials. The original RustDesk service is independent.
Host service enable-at-boot policy is not silently changed by this package.

Rollback: plan and activate PREVIOUS with --expect-current @ARTIFACT@ in a
maintenance window, then run farpane-user-integration rollback as that user.
First installation has no previous release to roll back to. Interrupted
transactions use farpane-maintenance recover --maintenance-window, followed
by farpane-user-integration recover if the user transaction was interrupted.
Keep the current P1 FarPane release until native user acceptance is complete.

Package removal/purge removes ONLY /usr/lib/farpane-native-candidate, its two
commands and package documentation. It deliberately retains /opt/farpane
releases/staging, the active service and all user configuration. Therefore
dpkg removal is NOT application deactivation. Activate the desired retained
release before removing the candidate tools. No user data is deleted.
Each retained release also carries its own source/Scripts/linux installer.

Known open gates: full real-desktop/media/interoperability and memory targets,
systemd/logind maintenance on the user's desktop, release CI, and complete
dependency licenses/corresponding-source delivery. The included source and
license files are not a claim that the publication audit is complete.
Detailed limitations are in payload/source/Linux/docs/gui-status.md.
