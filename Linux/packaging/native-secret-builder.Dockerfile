FROM sha256:c84f2a454d08709fbd1734860296a1c85fc3a9a7e2c8f86be79c1b1bf321a2c1
# Extend the cached native builder. Runtime loading of libsecret is optional;
# these headers check the narrow C bridge against the actual public ABI.
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends libsecret-1-dev \
    && dpkg-query -W > /farpane-native-secret-builder-packages.txt \
    && rm -rf /var/lib/apt/lists/*
