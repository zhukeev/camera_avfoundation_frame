#!/usr/bin/env bash
# v1.4 (macOS bash 3.2 compatible)
set -euo pipefail

# === Конфиг по умолчанию ===
UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/flutter/packages.git}"
UPSTREAM_BRANCH="${UPSTREAM_BRANCH:-main}"
UPSTREAM_SUBPATH="${UPSTREAM_SUBPATH:-packages/camera/camera_avfoundation}"

TARGET_BRANCH="${TARGET_BRANCH:-upstream-sync}"   # куда кладём синк
ASSUME_YES="${ASSUME_YES:-0}"                     # 1 = не спрашивать подтверждение
AUTO_COMMIT="${AUTO_COMMIT:-1}"
COMMIT_MSG="${COMMIT_MSG:-sync: upstream camera_avfoundation → local tree}"

RENAME_PKG="${RENAME_PKG:-0}"                     # 1 = одноразово переименовать пакет в pubspec.yaml
NEW_PUB_NAME="${NEW_PUB_NAME:-camera_avfoundation_frame}"

EXCLUDE_FILE="${EXCLUDE_FILE:-.upstream-sync-exclude}"
PROTECT_FILE="${PROTECT_FILE:-.upstream-sync-protect}"

# При необходимости можно указать доп. пути для защиты (через запятую)
EXTRA_PROTECT="${EXTRA_PROTECT:-}"                # пример: "ios/camera_avfoundation_frame.podspec,lib/camera_avfoundation_frame.dart"

# === Вспомогательные ===
need_clean_worktree() {
  if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "❗️ Есть незафиксированные изменения. Закоммить/stash перед запуском." >&2
    exit 1
  fi
}

append_unique_line() { # file, line
  local f="$1"; shift
  local line="$*"
  grep -qxF "$line" "$f" 2>/dev/null || echo "$line" >> "$f"
}

# --- проверки и подготовка ---
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Ошибка: это не git-репозиторий. Запусти из корня репо." >&2
  exit 1
fi

# Требуем чистую рабочую директорию (чтобы PR был чистым)
need_clean_worktree

# Переключаемся/создаём TARGET_BRANCH
if git show-ref --verify --quiet "refs/heads/$TARGET_BRANCH"; then
  git checkout "$TARGET_BRANCH"
else
  git checkout -b "$TARGET_BRANCH"
fi

# Создадим/дополним списки исключений и защиты (с дефолтными шаблонами)
touch "$EXCLUDE_FILE" "$PROTECT_FILE"

# 1) EXCLUDE — не копировать из апстрима (и не сравнивать в PR)
#    Добавим типичные сгенерённые файлы и то, что в твоём кейсе не нужно из апстрима.
for p in \
  "CHANGELOG.md" \
  "README.md" \
  "pubspec.yaml" \
  "example/*" \
  "test/*" \
  "ios/camera_avfoundation.podspec" \
  "ios/camera_avfoundation/Sources/camera_avfoundation_objc/messages.g.m" \
  "*.g.dart" \
  "*.freezed.dart" \
  "*.mocks.dart" \
  "*.gen.dart" \
  "*.pb.dart" "*.pbjson.dart" "*.pbenum.dart" "*.pbserver.dart" \
  "*.gr.dart" "*.graphql.dart" "*.chopper.dart" \
  "*.g.h" "*.g.m" "*.g.mm" \
  ".dart_tool/" "build/" \
; do append_unique_line "$EXCLUDE_FILE" "$p"; done

# 2) PROTECT — никогда не затирать/не удалять у тебя локально
for p in \
  ".git" ".github" ".gitignore" ".DS_Store" \
  "$EXCLUDE_FILE" "$PROTECT_FILE" \
  "sync_upstream.sh" \
  ".upstream_tmp" ".upstream_tmp/**" \
  ".dart_tool/" "build/" \
; do append_unique_line "$PROTECT_FILE" "$p"; done

# Пользовательские доп. защиты
if [ -n "$EXTRA_PROTECT" ]; then
  IFS=',' read -r -a arr <<< "$EXTRA_PROTECT"
  for item in "${arr[@]}"; do
    item_trimmed="$(echo "$item" | sed 's/^ *//;s/ *$//')"
    [ -n "$item_trimmed" ] && append_unique_line "$PROTECT_FILE" "$item_trimmed"
  done
fi

# Временная папка ВНЕ репо (важно!)
TMP_DIR="$(mktemp -d -t upstream_camera_sync_XXXXXX)"
cleanup() { rm -rf "$TMP_DIR" 2>/dev/null || true; }
trap cleanup EXIT

echo "==> Upstream: $UPSTREAM_URL [$UPSTREAM_BRANCH] :: $UPSTREAM_SUBPATH"
echo "==> Temp dir: $TMP_DIR"
echo "==> Target branch: $TARGET_BRANCH"

# Забираем апстрим (sparse)
git clone --no-checkout "$UPSTREAM_URL" "$TMP_DIR" >/dev/null
pushd "$TMP_DIR" >/dev/null
git sparse-checkout init --cone >/dev/null
git sparse-checkout set "$UPSTREAM_SUBPATH" >/dev/null
git checkout "$UPSTREAM_BRANCH" >/dev/null
popd >/dev/null

# Собираем аргументы rsync
RSYNC_ARGS=(-a --delete)

# exclude: не тянуть из апстрима
# (используем --exclude-from, чтобы работали все шаблоны)
RSYNC_ARGS+=(--exclude-from="$EXCLUDE_FILE")

# protect: не трогать локально (через фильтры P)
while IFS= read -r line; do
  [ -z "$line" ] && continue
  case "$line" in \#*) continue ;; esac
  RSYNC_ARGS+=(--filter="P $line")
done < "$PROTECT_FILE"

echo "==> DRY RUN (никаких изменений):"
rsync -n "${RSYNC_ARGS[@]}" "$TMP_DIR/$UPSTREAM_SUBPATH/" "./" || true

if [ "$ASSUME_YES" != "1" ]; then
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
if [ "$RENAME_PKG" = "1" ] && [ -f pubspec.yaml ]; then
  perl -0777 -pe "s/^name:\s*.*$/name: ${NEW_PUB_NAME}/m" -i pubspec.yaml
  echo "==> pubspec.yaml: name → ${NEW_PUB_NAME}"
fi

# Коммитим
if [ "$AUTO_COMMIT" = "1" ]; then
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
