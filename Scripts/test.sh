#!/bin/zsh
set -eu
cd "${0:A:h}/.."
source Scripts/macos-link-settings.zsh
readonly windows='(NativeWindowIntegrationTests|PlacementWindowIntegrationTests)'
readonly safety='(WindowSafetyPolicyTests|SplitLayoutTests|SnapGroupTests|MissionControlGroupProxyTests|GroupSpaceMigrationTests|MonitoringLifecyclePolicyTests|WindowPreviewCaptureTests)'
case "${1:-all}" in
  ci) exec swift test "${MACOS_LINK_FLAGS[@]}" --skip "$windows|$safety" ;;
  safety) exec swift test "${MACOS_LINK_FLAGS[@]}" --filter "$safety" ;;
  windows) exec swift test "${MACOS_LINK_FLAGS[@]}" --filter "$windows" ;;
  all) exec swift test "${MACOS_LINK_FLAGS[@]}" ;;
  *) print -u2 'Usage: Scripts/test.sh [ci|safety|windows|all]'; exit 2 ;;
esac
