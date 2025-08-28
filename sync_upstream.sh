#!/usr/bin/env bash
set -euo pipefail

# === Настройка ===
UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/flutter/packages.git}"
UPSTREAM_BRANCH="${UPSTREAM_BRANCH:-main}"
UPSTREAM_SUBPATH="${UPSTREAM_SUBPATH:-packages/camera/camera_avfoundation}"

# Временная папка для апстрима (не коммитим!)
TMP_DIR="${TMP_DIR:-.upstream_tmp}"

# Файлы с правилами (опционально):
#  - EXCLUDE: не копировать из апстрима (как будто их там нет)
#  - PROTECT: не затирать/не удалять в твоём репо даже при --delete
EXCLUDE_FILE="${EXCLUDE_FILE:-.upstream-sync-exclude}"
PROTECT_FILE="${PROTECT_FILE:-.upstream-sync-protect}"

# Авто-коммит после синка (1 = да, 0 = нет)
AUTO_COMMIT="${AUTO_COMMIT:-1}"
COMMIT_MSG="${COMMIT_MSG:-sync: upstream camera_avfoundation → local tree}"

# Одноразовое переименование пакета (выполняй только если нужно)
# example: RENAME_PKG=1 NEW_PUB_NAME=camera_avfoundation_frame ./sync_upstream.sh
RENAME_PKG="${RENAME_PKG:-0}"
NEW_PUB_NAME="${NEW_PUB_NAME:-camera_avfoundation_frame}"


echo "==> Upstream: $UPSTREAM_URL [$UPSTREAM_BRANCH] :: $UPSTREAM_SUBPATH"
echo "==> Temp dir: $TMP_DIR"

# Не даём случайно закоммитить TMP_DIR
if ! grep -q "^${TMP_DIR}\$" .gitignore 2>/dev/null; then
  echo "$TMP_DIR" >> .gitignore
fi

# Чистый старт
rm -rf "$TMP_DIR"
git clone --no-checkout "$UPSTREAM_URL" "$TMP_DIR" >/dev/null
pushd "$TMP_DIR" >/dev/null

git sparse-checkout init --cone >/dev/null
git sparse-checkout set "$UPSTREAM_SUBPATH" >/dev/null
git checkout "$UPSTREAM_BRANCH" >/dev/null

popd >/dev/null

# Сборка аргументов rsync
RSYNC_ARGS=(-a --delete)
if [[ -f "$EXCLUDE_FILE" ]]; then
  while IFS= read -r line; do
    [[ -z "$line" || "$line" =~ ^# ]] && continue
    RSYNC_ARGS+=(--exclude="$line")
  done < "$EXCLUDE_FILE"
fi

if [[ -f "$PROTECT_FILE" ]]; then
  while IFS= read -r line; do
    [[ -z "$line" || "$line" =~ ^# ]] && continue
    RSYNC_ARGS+=(--filter="P $line")
  done < "$PROTECT_FILE"
fi

echo "==> rsync ${RSYNC_ARGS[*]}"
rsync "${RSYNC_ARGS[@]}" "$TMP_DIR/$UPSTREAM_SUBPATH/" "./"

# Опционально: одноразово переименовать пакет в pubspec.yaml
if [[ "$RENAME_PKG" == "1" ]]; then
  if [[ -f pubspec.yaml ]]; then
    # Меняем только строку name: <...> в начале файла
    perl -0777 -pe "s/^name:\s*.*$/name: ${NEW_PUB_NAME}/m" -i pubspec.yaml
    echo "==> pubspec.yaml: name → ${NEW_PUB_NAME}"
  else
    echo "!! pubspec.yaml not found, skip rename"
  fi
fi

# Коммит
if [[ "$AUTO_COMMIT" == "1" ]]; then
  git add -A
  if ! git diff --cached --quiet; then
    git commit -m "$COMMIT_MSG"
    echo "==> Commit created."
  else
    echo "==> Nothing to commit."
  fi
else
  echo "==> AUTO_COMMIT=0: changes staged? $(git diff --name-only)"
fi

echo "==> Done. You can now push and open a PR."
