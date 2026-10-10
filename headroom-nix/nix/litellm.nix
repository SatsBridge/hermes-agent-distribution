# litellm 1.86.2: Headroom's floor is >=1.86.2, but nixpkgs 26.05 ships 1.83.14.
# Built as its own package (by analogy with rtk) by adapting the nixpkgs recipe
# to the newer version: bump version + src, and retarget the recipe's
# build-system pin patch (litellm moved its pinned `uv_build` from 0.10.7 to
# 0.11.8 between these releases). Same build steps, newer version — no pin
# relaxation.
#
# Tests: the upstream nixpkgs recipe sets `doCheck = false` with the comment
# "access network". That is true for the full suite: it mixes live provider,
# proxy, vector-store, and dev-extra tests. This package still runs a tiny
# hermetic subset of pure type/helper tests so the version-bumped recipe has
# more coverage than an import check without trying to package the whole dev
# environment or hit provider APIs.
{ python3Packages, fetchFromGitHub }:
python3Packages.litellm.overridePythonAttrs (_old: rec {
  version = "1.86.2";
  src = fetchFromGitHub {
    owner = "BerriAI";
    repo = "litellm";
    tag = "v${version}";
    hash = "sha256-ykF2mueHLfaMmT0iGCLxGcHR5QASh6itcihbrbU+pTk=";
  };
  postPatch = ''
    substituteInPlace pyproject.toml \
      --replace-fail "uv_build==0.11.8" "uv_build"
  '';

  # The nixpkgs recipe disables checks because the full upstream suite needs
  # network/provider services. Re-enable checks for the narrow hermetic subset
  # below.
  doCheck = true;

  nativeCheckInputs = [ python3Packages.pytest ];

  checkPhase = ''
    runHook preCheck

    pytest -q \
      tests/test_litellm/types/test_prometheus_label_value_sanitize.py \
      tests/test_litellm/types/test_prometheus_latency_buckets.py

    runHook postCheck
  '';
})
