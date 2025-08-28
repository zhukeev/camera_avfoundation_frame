#!/usr/bin/env bash
set -euo pipefail

# === Настройки по умолчанию ===
UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/flutter/packages.git}"
UPSTREAM_BRANCH="${UPSTREAM_BRANCH:-main}"
UPSTREAM_SUBPATH="${UPSTREAM_SUBPATH:-packages/camera/camera_avfoundation}"

# Куда писать временные файлы: строго ВНЕ репо
TMP_DIR="$(mktemp -d -t upstream_camera_sync_XXXXXX)"

EXCLUDE_FILE="${EXCLUDE_FILE:-.upstream-sync-exclude}"
PROTECT_FILE="${PROTECT_FILE:-.upstream-sync-protect}"

AUTO_COMMIT="${AUTO_COMMIT:-1}"
COMMIT_MSG="${COMMIT_MSG:-sync: upstream camera_avfoundation → local tree}"

RENAME_PKG="${RENAME_PKG:-0}"
NEW_PUB_NAME="${NEW_PUB_NAME:-camera_avfoundation_frame}"

ASSUME_YES="${ASSUME_YES:-0}"        # 1 = не спрашивать подтверждение
TARGET_BRANCH="${TARGET_BRANCH:-upstream-sync}"  # куда коммитим

# --- проверки и подготовка ---
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Ошибка: это не git-репозиторий. Запусти из корня репо." >&2
  exit 1
fi

CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [ "$CURRENT_BRANCH" != "$TARGET_BRANCH" ]; then
  if git show-ref --verify --quiet "refs/heads/$TARGET_BRANCH"; then
    git checkout "$TARGET_BRANCH"
  else
    git checkout -b "$TARGET_BRANCH"
  fi
  CURRENT_BRANCH="$TARGET_BRANCH"
fi

# Встроенная защита: файлы/папки, которые НЕЛЬЗЯ трогать/удалять
_INTERNAL_PROTECT="$(mktemp -t upstream_protect_XXXXXX)"
cat >"$_INTERNAL_PROTECT" <<EOF
.git
.github
.gitignore
.DS_Store
sync_upstream.sh
.upstream-sync-exclude
.upstream-sync-protect
.upstream_tmp
EOF

# Уберём следы старых локальных попыток
rm -rf .upstream_tmp 2>/dev/null || true

cleanup() { rm -rf "$TMP_DIR" 2>/dev/null || true; rm -f "$_INTERNAL_PROTECT" 2>/dev/null || true; }
trap cleanup EXIT

echo "==> Upstream: $UPSTREAM_URL [$UPSTREAM_BRANCH] :: $UPSTREAM_SUBPATH"
echo "==> Temp dir: $TMP_DIR"
echo "==> Target branch: $TARGET_BRANCH"

# --- забираем апстрим (sparse checkout) ---
git clone --no-checkout "$UPSTREAM_URL" "$TMP_DIR" >/dev/null
pushd "$TMP_DIR" >/dev/null
git sparse-checkout init --cone >/dev/null
git sparse-checkout set "$UPSTREAM_SUBPATH" >/dev/null
git checkout "$UPSTREAM_BRANCH" >/dev/null
popd >/dev/null

# --- собираем аргументы rsync ---
RSYNC_ARGS=(-a --delete)

# исключения: не тащить из апстрима
if [[ -f "$EXCLUDE_FILE" ]]; then
  while IFS= read -r line; do
    [[ -z "$line" || "$line" =~ ^# ]] && continue
    RSYNC_ARGS+=(--exclude="$line")
  done < "$EXCLUDE_FILE"
fi

# защита: не трогать локально (встроенные)
while IFS= read -r line; do
  [[ -z "$line" || "$line" =~ ^# ]] && continue
  RSYNC_ARGS+=(--filter="P $line")
done < "$_INTERNAL_PROTECT"

# защита: пользовательская
if [[ -f "$PROTECT_FILE" ]]; then
  while IFS= read -r line; do
    [[ -z "$line" || "$line" =~ ^# ]] && continue
    RSYNC_ARGS+=(--filter="P $line")
  done < "$PROTECT_FILE"
fi

echo "==> DRY RUN (никаких изменений):"
rsync -n "${RSYNC_ARGS[@]}" "$TMP_DIR/$UPSTREAM_SUBPATH/" "./" || true

if [[ "$ASSUME_YES" != "1" ]]; then
  printf "Применить изменения? [y/N] "
  read ans
  case "$ans" in
    y|Y) ;;
    *) echo "Отменено."; exit 0 ;;
  esac
fi

echo "==> Применяем rsync"
rsync "${RSYNC_ARGS[@]}" "$TMP_DIR/$UPSTREAM_SUBPATH/" "./"

# Одноразово переименовать пакет
if [[ "$RENAME_PKG" == "1" && -f pubspec.yaml ]]; then
  perl -0777 -pe "s/^name:\s*.*$/name: ${NEW_PUB_NAME}/m" -i pubspec.yaml
  echo "==> pubspec.yaml: name → ${NEW_PUB_NAME}"
fi

# Коммитим в TARGET_BRANCH
if [[ "$AUTO_COMMIT" == "1" ]]; then
  git add -A
  if ! git diff --cached --quiet; then
    git commit -m "$COMMIT_MSG"
    echo "==> Commit created on branch: $TARGET_BRANCH"
  else
    echo "==> Nothing to commit."
  fi
fi

echo "==> Done. Push this branch to open/update PR:"
echo "    git push -u origin $TARGET_BRANCH"
