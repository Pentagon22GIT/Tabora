#!/bin/zsh
set -euo pipefail

readonly SCRIPT_DIR="${0:A:h}"
readonly ROOT="${SCRIPT_DIR:h}"
readonly INSTALL_DIR="$HOME/Applications"
readonly TARGET="$INSTALL_DIR/Tabora Community.app"

fail() {
  echo "エラー: $1" >&2
  exit 1
}

[[ "$(/usr/bin/uname -s)" == "Darwin" ]] || fail "インストールはmacOS上で実行してください。"
if /usr/bin/pgrep -x Tabora >/dev/null; then
  fail "起動中のTaboraを終了してから再実行してください。"
fi

# Replacement is explicit and the previous app is retained outside staging.
if [[ -e "$TARGET" || -L "$TARGET" ]]; then
  [[ -t 0 ]] || fail "既存のアプリがあります。対話端末で確認してから実行してください。"
  read -r "TABORA_INSTALL_REPLY?既存のCommunity版をバックアップして置き換えますか？ [yes/no] "
  [[ "$TABORA_INSTALL_REPLY" == yes ]] || fail "インストールを中止しました。"
  [[ ! -L "$TARGET" ]] || fail "シンボリックリンクのインストール先は変更しません。"
fi
/bin/mkdir -p "$INSTALL_DIR"
readonly TEMP_DIR="$(/usr/bin/mktemp -d "$INSTALL_DIR/.tabora-community.XXXXXX")"
trap '/bin/rm -rf "$TEMP_DIR"' EXIT INT TERM
TABORA_BUILD_OUTPUT_DIR="$TEMP_DIR/build" "$SCRIPT_DIR/build-community.sh"
readonly STAGED="$TEMP_DIR/build/Tabora Community.app"
readonly TEMP_APP="$TEMP_DIR/Tabora Community.app"
/usr/bin/ditto "$STAGED" "$TEMP_APP"
/usr/bin/codesign --verify --strict --verbose=2 "$TEMP_APP"

BACKUP=""
if [[ -e "$TARGET" ]]; then
  BACKUP="$(/usr/bin/mktemp -d "$INSTALL_DIR/.tabora-previous.XXXXXX")/Tabora Community.app"
fi
if [[ -e "$TARGET" ]]; then
  /bin/mv "$TARGET" "$BACKUP"
fi
if /bin/mv "$TEMP_APP" "$TARGET"; then
  [[ -z "$BACKUP" ]] || echo "以前のアプリを保存しました: $BACKUP"
else
  [[ -e "$BACKUP" ]] && /bin/mv "$BACKUP" "$TARGET"
  fail "インストールに失敗したため以前のアプリを復元しました。"
fi

/usr/bin/open "$TARGET"
echo "Community版をインストールしました: $TARGET"
