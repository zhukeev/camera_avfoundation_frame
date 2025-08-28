#!/usr/bin/env bash
set -euo pipefail

# === Настройки ===
UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/flutter/packages.git}"
UPSTREAM_BRANCH="${UPSTREAM_BRANCH:-main}"
UPSTREAM_SUBPATH="${UPSTREAM_SUBPATH:-packages/camera/camera_avfoundation}"

TMP_DIR="${TMP_DIR:-.upstream_tmp}"

EXCLUDE_FILE="${EXCLUDE_FILE:-.upstream-sync-exclude}"
PROTECT_FILE="${PROTECT_FILE:-.upstream-sync-protect}"

AUTO_COMMIT="${AUTO_COMMIT:-1}"
COMMIT_MSG="${COMMIT_MSG:-sync: upstream camera_avfoundation → local tree}"

RENAME_PKG="${RENAME_PKG:-0}"
NEW_PUB_NAME="${NEW_PUB_NAME:-camera_avfoundation_frame}"

ASSUME_YES="${ASSUME_YES:-0}"  # 1 = применить без вопроса

echo "==> Upstream: $UPSTREAM_URL [$UPSTREAM_BRANCH] :: $UPSTREAM_SUBPATH"
echo "==> Temp dir: $TMP_DIR"

# внутренняя защита — никогда не трогаем эти пути
_INTERNAL_PROTECT="$(mktemp)"
cat >"$_INTERNAL_PROTECT" <<EOF
.git
.github
.gitignore
EOF

# чтобы TMP_DIR не попал в коммит
grep -qxF "$TMP_DIR" .gitignore 2>/dev/null || echo "$TMP_DIR" >> .gitignore

# получаем апстрим (sparse)
rm -rf "$TMP_DIR"
git clone --no-checkout "$UPSTREAM_URL" "$TMP_DIR" >/dev/null
pushd "$TMP_DIR" >/dev/null
git sparse-checkout init --cone >/dev/null
git sparse-checkout set "$UPSTREAM_SUBPATH" >/dev/null
git checkout "$UPSTREAM_BRANCH" >/dev/null
popd >/dev/null

# собираем аргументы rsync (без nameref, просто массив)
RSYNC_ARGS=(-a --delete)

# exclude: не забирать из апстрима
if [[ -f "$EXCLUDE_FILE" ]]; then
  while IFS= read -r line; do
    [[ -z "$line" || "$line" =~ ^# ]] && continue
    RSYNC_ARGS+=(--exclude="$line")
  done < "$EXCLUDE_FILE"
fi

# protect: не трогать локально (внутренние правила)
while IFS= read -r line; do
  [[ -z "$line" || "$line" =~ ^# ]] && continue
  RSYNC_ARGS+=(--filter="P $line")
done < "$_INTERNAL_PROTECT"

# protect: пользовательские
if [[ -f "$PROTECT_FILE" ]]; then
  while IFS= read -r line; do
    [[ -z "$line" || "$line" =~ ^# ]] && continue
    RSYNC_ARGS+=(--filter="P $line")
  done < "$PROTECT_FILE"
fi

echo "==> DRY RUN (ничего не меняем):"
rsync -n "${RSYNC_ARGS[@]}" "$TMP_DIR/$UPSTREAM_SUBPATH/" "./" || true

if [[ "$ASSUME_YES" != "1" ]]; then
  read -rp "Применить изменения? [y/N] " ans
  if [[ "${ans,,}" != "y" ]]; then
    echo "Отменено."
    exit 0
  fi
fi

echo "==> Применяем rsync"
rsync "${RSYNC_ARGS[@]}" "$TMP_DIR/$UPSTREAM_SUBPATH/" "./"

# одноразово переименовать пакет
if [[ "$RENAME_PKG" == "1" && -f pubspec.yaml ]]; then
  perl -0777 -pe "s/^name:\s*.*$/name: ${NEW_PUB_NAME}/m" -i pubspec.yaml
  echo "==> pubspec.yaml: name → ${NEW_PUB_NAME}"
fi

if [[ "$AUTO_COMMIT" == "1" ]]; then
  git add -A
  if ! git diff --cached --quiet; then
    git commit -m "$COMMIT_MSG"
    echo "==> Commit created."
  else
    echo "==> Nothing to commit."
  fi
fi

echo "==> Done."
