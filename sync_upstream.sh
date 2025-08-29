#!/usr/bin/env bash
# v2.0 (macOS bash 3.2 compatible) — sync upstream + auto reapply features

set -euo pipefail

# ====== CONFIG ======
UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/flutter/packages.git}"
UPSTREAM_BRANCH="${UPSTREAM_BRANCH:-main}"
UPSTREAM_SUBPATH="${UPSTREAM_SUBPATH:-packages/camera/camera_avfoundation}"

TARGET_BRANCH="${TARGET_BRANCH:-upstream-sync}"          # куда кладём чистый апстрим
FEATURE_BASE="${FEATURE_BASE:-origin/main}"              # откуда брать "твои фичи"
ASSUME_YES="${ASSUME_YES:-0}"                            # 1 = не спрашивать подтверждение
AUTO_COMMIT="${AUTO_COMMIT:-1}"
AUTO_PUSH="${AUTO_PUSH:-0}"                               # 1 = сразу пушнуть ветки
REMOTE_NAME="${REMOTE_NAME:-origin}"
COMMIT_MSG="${COMMIT_MSG:-sync: upstream camera_avfoundation → local tree}"

RENAME_PKG="${RENAME_PKG:-0}"                             # 1 = одноразово переименовать пакет
NEW_PUB_NAME="${NEW_PUB_NAME:-camera_avfoundation_frame}"

EXCLUDE_FILE="${EXCLUDE_FILE:-.upstream-sync-exclude}"
PROTECT_FILE="${PROTECT_FILE:-.upstream-sync-protect}"

# EXTRA_PROTECT="ios/camera_avfoundation_frame.podspec,lib/camera_avfoundation_frame.dart"
EXTRA_PROTECT="${EXTRA_PROTECT:-}"

# ====== HELPERS ======
die() { echo "Error: $*" >&2; exit 1; }
need_clean() { if ! git diff --quiet || ! git diff --cached --quiet; then die "Незакоммиченные изменения. Сделай commit/stash."; fi; }
append_unique_line() { local f="$1"; shift; local line="$*"; grep -qxF "$line" "$f" 2>/dev/null || echo "$line" >> "$f"; }

# ====== PRECHECKS ======
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "Запусти из корня git-репо."
need_clean

# Переключаемся/создаём TARGET_BRANCH (ветку чистого апстрима)
if git show-ref --verify --quiet "refs/heads/$TARGET_BRANCH"; then
  git checkout "$TARGET_BRANCH"
else
  git checkout -b "$TARGET_BRANCH"
fi

# Подготовим exclude/protect (добавим типичные шаблоны)
touch "$EXCLUDE_FILE" "$PROTECT_FILE"

# EXCLUDE — не тянуть это из апстрима (и не шуметь в PR)
for p in \
  "CHANGELOG.md" "README.md" "pubspec.yaml" \
  "example/*" "test/*" \
  "ios/camera_avfoundation.podspec" \
  "ios/camera_avfoundation/Sources/camera_avfoundation_objc/messages.g.m" \
  "*.g.dart" "*.freezed.dart" "*.mocks.dart" "*.gen.dart" \
  "*.pb.dart" "*.pbjson.dart" "*.pbenum.dart" "*.pbserver.dart" \
  "*.gr.dart" "*.graphql.dart" "*.chopper.dart" \
  "*.g.h" "*.g.m" "*.g.mm" \
  ".dart_tool/" "build/"; do
  append_unique_line "$EXCLUDE_FILE" "$p"
done

# PROTECT — никогда не трогать локально (даже при --delete)
for p in \
  ".git" ".github" ".gitignore" ".DS_Store" \
  "$EXCLUDE_FILE" "$PROTECT_FILE" \
  "sync_upstream.sh" \
  ".upstream_tmp" ".upstream_tmp/**" \
  ".dart_tool/" "build/"; do
  append_unique_line "$PROTECT_FILE" "$p"
done

if [ -n "$EXTRA_PROTECT" ]; then
  IFS=',' read -r -a arr <<< "$EXTRA_PROTECT"
  for item in "${arr[@]}"; do
    item_trimmed="$(echo "$item" | sed 's/^ *//;s/ *$//')"
    [ -n "$item_trimmed" ] && append_unique_line "$PROTECT_FILE" "$item_trimmed"
  done
fi

# ====== FETCH UPSTREAM (sparse) ======
TMP_DIR="$(mktemp -d -t upstream_camera_sync_XXXXXX)"
cleanup() { rm -rf "$TMP_DIR" 2>/dev/null || true; }
trap cleanup EXIT

echo "==> Upstream: $UPSTREAM_URL [$UPSTREAM_BRANCH] :: $UPSTREAM_SUBPATH"
echo "==> Temp dir: $TMP_DIR"
echo "==> Target branch (upstream copy): $TARGET_BRANCH"
echo "==> Feature base (reapply from):  $FEATURE_BASE"

git clone --no-checkout "$UPSTREAM_URL" "$TMP_DIR" >/dev/null
pushd "$TMP_DIR" >/dev/null
git sparse-checkout init --cone >/dev/null
git sparse-checkout set "$UPSTREAM_SUBPATH" >/dev/null
git checkout "$UPSTREAM_BRANCH" >/dev/null
popd >/dev/null

# Соберём аргументы rsync
RSYNC_ARGS=(-a --delete --exclude-from="$EXCLUDE_FILE")
while IFS= read -r line; do
  [ -z "$line" ] && continue
  case "$line" in \#*) continue ;; esac
  RSYNC_ARGS+=(--filter="P $line")
done < "$PROTECT_FILE"

echo "==> DRY RUN (upstream → $TARGET_BRANCH):"
rsync -n "${RSYNC_ARGS[@]}" "$TMP_DIR/$UPSTREAM_SUBPATH/" "./" || true

if [ "$ASSUME_YES" != "1" ]; then
  printf "Продолжить и применить изменения? [y/N] "
  read ans
  case "$ans" in y|Y) ;; *) echo "Отменено."; exit 0 ;; esac
fi

echo "==> Применяем rsync (upstream → $TARGET_BRANCH)"
rsync "${RSYNC_ARGS[@]}" "$TMP_DIR/$UPSTREAM_SUBPATH/" "./"

# Одноразово переименовать пакет (если нужно)
if [ "$RENAME_PKG" = "1" ] && [ -f pubspec.yaml ]; then
  perl -0777 -pe "s/^name:\s*.*$/name: ${NEW_PUB_NAME}/m" -i pubspec.yaml
  echo "==> pubspec.yaml: name → ${NEW_PUB_NAME}"
fi

# Коммитим чистый апстрим
if [ "$AUTO_COMMIT" = "1" ]; then
  git add -A
  if ! git diff --cached --quiet; then
    git commit -m "$COMMIT_MSG"
    echo "==> Commit created on $TARGET_BRANCH"
  else
    echo "==> Nothing to commit on $TARGET_BRANCH"
  fi
fi

# ====== AUTO REAPPLY: строим патч и переносим фичи ======
REAPPLY_BRANCH="feature/reapply-$(date +%Y%m%d-%H%M%S)"
echo "==> Creating reapply branch: $REAPPLY_BRANCH (base: $TARGET_BRANCH)"
git checkout -b "$REAPPLY_BRANCH" "$TARGET_BRANCH"

# Сформируем патч отличий (FEATURE_BASE vs TARGET_BRANCH), исключая генерат и пр.
PATCH_FILE="$(mktemp -t reapply_patch_XXXXXX.diff)"
# ВНИМАНИЕ: порядок diff — base..feature (т.е. upstream-sync..origin/main)
git diff "$TARGET_BRANCH".."$FEATURE_BASE" -- \
  'ios/camera_avfoundation/Sources/camera_avfoundation/**' \
  'ios/camera_avfoundation/Sources/camera_avfoundation_objc/**' \
  'include/camera_avfoundation/**' \
  'lib/**' \
  ':(exclude)**/*.g.dart' ':(exclude)**/*.freezed.dart' ':(exclude)**/*.mocks.dart' \
  ':(exclude)**/*.pb*.dart' ':(exclude)**/*.gr.dart' ':(exclude)**/*.gen.dart' \
  ':(exclude)**/*.graphql.dart' ':(exclude)**/*.chopper.dart' \
  ':(exclude)**/*.g.h' ':(exclude)**/*.g.m' ':(exclude)**/*.g.mm' \
  ':(exclude)example/**' ':(exclude)test/**' \
  ':(exclude)CHANGELOG.md' ':(exclude)README.md' ':(exclude)pubspec.yaml' \
  ':(exclude)ios/camera_avfoundation.podspec' \
  > "$PATCH_FILE" || true

if [ ! -s "$PATCH_FILE" ]; then
  echo "==> Патч пуст. Похоже, $FEATURE_BASE уже совпадает с $TARGET_BRANCH по релевантным файлам."
else
  echo "==> Применяем патч (3-way): $PATCH_FILE"
  set +e
  git apply --3way "$PATCH_FILE"
  APPLY_STATUS=$?
  set -e
  if [ $APPLY_STATUS -ne 0 ]; then
    echo "⚠️  Были конфликты при применении патча. Проверь файлы, реши конфликты и закоммить вручную."
  fi
  git add -A
  if ! git diff --cached --quiet; then
    git commit -m "feat: reapply custom features on top of upstream"
    echo "==> Reapply commit created on $REAPPLY_BRANCH"
  else
    echo "==> Нечего коммитить после reapply (возможно, всё уже совпадало)."
  fi
fi

# ====== PUSH (опционально) ======
if [ "$AUTO_PUSH" = "1" ]; then
  echo "==> Pushing branches to $REMOTE_NAME"
  git push -u "$REMOTE_NAME" "$TARGET_BRANCH"
  git push -u "$REMOTE_NAME" "$REAPPLY_BRANCH"
  echo "==> Open PRs:"
  echo "   1) $TARGET_BRANCH → main   (чистый апстрим)"
  echo "   2) $REAPPLY_BRANCH → $TARGET_BRANCH  (твои фичи поверх)"
else
  echo "==> Done."
  echo "   Push branches and open PRs:"
  echo "   git push -u $REMOTE_NAME $TARGET_BRANCH"
  echo "   git push -u $REMOTE_NAME $REAPPLY_BRANCH"
  echo "   PR #1: $TARGET_BRANCH → main   (upstream only)"
  echo "   PR #2: $REAPPLY_BRANCH → $TARGET_BRANCH  (reapply features)"
fi
