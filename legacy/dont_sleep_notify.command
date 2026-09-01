#!/bin/bash
set -euo pipefail

# Проверка наличия terminal-notifier
if ! command -v terminal-notifier >/dev/null 2>&1; then
  echo "Внимание: terminal-notifier не найден — системное уведомление по окончании не будет отправлено."
  echo "Установить можно через Homebrew: brew install terminal-notifier"
  # Не выходим: скрипт продолжит работу без уведомления
fi

# Запрос длительности
read -p "Сколько минут не давать Mac спать? " minutes_raw

# Валидация ввода
if [[ ! "${minutes_raw}" =~ ^[0-9]+$ ]] || [[ "${minutes_raw}" -le 0 ]]; then
  echo "Введите положительное целое число минут."
  exit 1
fi

minutes="${minutes_raw}"
seconds=$(( minutes * 60 ))

# Локаль для русских дат (если доступна)
LC_TIME_RU="ru_RU.UTF-8"

# Метки времени
NOW="$(LC_TIME=${LC_TIME_RU} date '+%A, %d %B %Y г. %H:%M:%S (%Z)')"
END="$(LC_TIME=${LC_TIME_RU} date -v+"${minutes}"M '+%A, %d %B %Y г. %H:%M:%S (%Z)')"

# Запуск caffeinate: блокируем простой и сон дисплея на таймаут
caffeinate -di -t "${seconds}" &
pid=$!

# Корректное прерывание по Ctrl+C — уведомления не отправляются
cleanup() {
  echo
  if kill -0 "${pid}" 2>/dev/null; then
    kill "${pid}" 2>/dev/null || true
  fi
  echo "Отмена — Mac снова может спать."
  exit 130
}
trap cleanup INT TERM

# Информация в терминале
echo "Сейчас ${NOW}."
echo "Выбрано не спать ${minutes} мин."
echo "Mac перейдет к обычному режиму электропитания ${END}."

# Обратный отсчёт
remaining=${seconds}
while (( remaining >= 0 )); do
  hh=$(( remaining / 3600 ))
  mm=$(( (remaining % 3600) / 60 ))
  ss=$(( remaining % 60 ))
  printf "\rОсталось: %02d:%02d:%02d до перехода к обычному плану электропитания" "$hh" "$mm" "$ss"
  sleep 1
  remaining=$(( remaining - 1 ))
done
echo

# Дожидаемся завершения caffeinate
wait "${pid}" 2>/dev/null || true

# Единственное уведомление по завершении периода
if command -v terminal-notifier >/dev/null 2>&1; then
  terminal-notifier \
    -title "Активность завершена" \
    -subtitle "Система вернулась к обычному плану" \
    -message "Период бодрствования: ${minutes} мин. Окончание: ${END}" \
    -sound default \
    -sender com.apple.Terminal \
    -activate com.apple.Terminal || true
fi

echo "Время истекло — Mac снова может спать."
