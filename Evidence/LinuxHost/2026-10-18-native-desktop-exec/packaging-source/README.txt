FarPane 20261018.5 desktop launch packaging recipe

This archive supplements the frozen .3 application source archive named in source-recipe.json. It is not a standalone full application source archive.

Overlay these files onto that extracted source tree. Place the verified parent bundle at Build/Linux/artifacts/farpane-native-dev-d393fd0cff634416807feae5, then run:
  python3 -B Scripts/linux/repackage-native-desktop.py Build/Linux/artifacts/farpane-native-dev-d393fd0cff634416807feae5
  python3 -B Scripts/linux/package-native-deb.py Build/Linux/artifacts/farpane-native-dev-ec305482eaacd98258e28587 --version 0.1.0~dev.20261018.5
  python3 -B Scripts/linux/package-native-rpm.py Build/Linux/artifacts/farpane-native-dev-ec305482eaacd98258e28587 --version 0.1.0~dev.20261018.5

The parent binaries and compiled sources stay unchanged. The exact parent manifest, template and recipe are recorded in the derived build.json. No current experimental core patches are imported or compiled. RPM packaging requires the pinned Fedora builder image already present. Installer/document snapshots here are the versions used for these packages; later worktree documentation must not silently replace them when reproducing .5.

No install, service activation or public release is performed by this recipe. Existing media, licensing and release gates remain open.
