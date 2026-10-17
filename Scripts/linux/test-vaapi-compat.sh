#!/usr/bin/env bash
set -euo pipefail
cd /workspace
mkdir -p Build/Linux/vaapi-compat-test
for variant in old new; do
  flags=()
  if [[ "$variant" == new ]]; then flags=(-DNEW_API); fi
  cc -std=c11 -O2 -Wall -Wextra -Werror -rdynamic "${flags[@]}" \
    Linux/tests/vaapi_compat_test.c Linux/tests/vaapi_compat_stubs.c Linux/src/vaapi_compat.c \
    -Wl,--wrap=vaMapBuffer2,--wrap=dlsym -ldl -pthread -o "Build/Linux/vaapi-compat-test/$variant"
  "Build/Linux/vaapi-compat-test/$variant"
done
