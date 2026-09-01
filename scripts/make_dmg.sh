#!/bin/zsh
# Собирает DMG-образ с приложением и ярлыком Applications:
# пользователь открывает образ и перетаскивает приложение в «Программы».
#
# Использование: ./scripts/make_dmg.sh [путь/к/выходному.dmg]

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

APP_PATH="$ROOT/build/Don't sleep.app"
STAGING="$ROOT/build/dmg-staging"
TMP_DMG="$ROOT/build/dont-sleep-rw.dmg"
OUT_DMG="${1:-$ROOT/build/Don't sleep.dmg}"
VOLNAME="Don't sleep"

if [ ! -d "$APP_PATH" ]; then
  echo "Приложение не найдено: $APP_PATH" >&2
  echo "Сначала соберите его: ./build_app.command" >&2
  exit 1
fi

# 1. Готовим содержимое образа: приложение + симлинк на /Applications.
rm -rf "$STAGING" "$TMP_DMG"
mkdir -p "$STAGING"
ditto "$APP_PATH" "$STAGING/$(basename "$APP_PATH")"
ln -s /Applications "$STAGING/Applications"

# 2. Создаём временный read/write образ (HFS+ — чтобы Finder видел
#    настоящее имя тома и чтобы раскладка иконок сохранялась).
hdiutil create -volname "$VOLNAME" -fs HFS+ -srcfolder "$STAGING" -ov -format UDRW "$TMP_DMG" > /dev/null

# 3. Монтируем (в стандартный /Volumes, иначе Finder увидит том
#    под именем точки монтирования, а не под именем тома).
MOUNT="$(hdiutil attach "$TMP_DMG" -nobrowse | grep -o '/Volumes/.*' | tail -1)"
DISK_NAME="$(basename "$MOUNT")"

# 4. Расставляем иконки (best effort: нужен GUI-сеанс и разрешение
#    на управление Finder; без этого раскладка останется стандартной).
if osascript <<APPLESCRIPT; then
tell application "Finder"
  tell disk "$DISK_NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {300, 100, 820, 440}
    set theViewOptions to the icon view options of container window
    set arrangement of theViewOptions to not arranged
    set icon size of theViewOptions to 96
    set position of item "Don't sleep.app" of container window to {150, 190}
    set position of item "Applications" of container window to {370, 190}
    close
    open
    update without registering applications
    delay 1
  end tell
end tell
APPLESCRIPT
  echo "✓ Иконки расставлены"
else
  echo "⚠️  Не удалось расставить иконки (нет GUI-сессии или отказано в доступе к Finder) — раскладка останется стандартной." >&2
fi

# 5. Отмонтируем и конвертируем в сжатый read-only DMG.
sleep 2
hdiutil detach "$MOUNT" > /dev/null || hdiutil detach "$MOUNT" -force > /dev/null
hdiutil convert "$TMP_DMG" -format UDZO -o "$OUT_DMG" -ov > /dev/null

# 6. Убираем временные файлы.
rm -rf "$STAGING" "$TMP_DMG"

echo "Готово: $OUT_DMG"
