FROM sha256:ce8a98a1236e36755827266880578164a31bf7ef528f157c2a46358e686d2757
# Packaging tools only. The application and all bundled media remain the
# already verified immutable artifact; no Rust/FFmpeg build is performed.
RUN dnf install -y --setopt=install_weak_deps=False rpm-build cpio \
    && rpm -qa --qf '%{NAME}\t%{VERSION}-%{RELEASE}.%{ARCH}\n' | sort > /farpane-native-rpm-builder-packages.txt \
    && dnf clean all
