FROM sha256:c84f2a454d08709fbd1734860296a1c85fc3a9a7e2c8f86be79c1b1bf321a2c1
# Test-only compositor. Never installed on the host or included in the product.
# The headless backend uses a render node without a DRM primary node or KMS.
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends weston \
    && dpkg-query -W > /farpane-native-display-test-packages.txt \
    && rm -rf /var/lib/apt/lists/*
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends xwayland \
    && dpkg-query -W > /farpane-native-display-test-packages.txt \
    && rm -rf /var/lib/apt/lists/*
