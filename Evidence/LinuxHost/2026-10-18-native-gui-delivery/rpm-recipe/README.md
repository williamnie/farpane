# FarPane RPM packaging inputs

Use the frozen bundle named by recipe.json and the fixed builder image in the included lock. Place the bundle at Build/Linux/artifacts/ARTIFACT inside this extracted recipe directory.

Run: python3 -B Scripts/linux/package-native-rpm.py Build/Linux/artifacts/ARTIFACT --version VERSION --release RELEASE

Substitute the artifact, version and release from recipe.json. The command packages the existing GUI/core/media without compiling them or touching host services. The complete application source archive is separately identified and hashed in recipe.json.
