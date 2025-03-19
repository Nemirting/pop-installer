#!/bin/bash
# Скрипт быстрой установки Pop
# Автор: nemirting
# Версия: 1.0.0

echo "=== Pop Node Installer ==="
echo "Этот скрипт автоматически установит и настроит ноду Pop"
echo "Автор: nemirting"
echo "=================================================="

# Проверка и установка curl
if ! command -v curl &> /dev/null; then
    echo "Установка curl..."
    sudo apt-get update
    sudo apt-get install -y curl
fi

# Создание директории для установки
INSTALL_DIR=~/pop-node
echo "Создание директории для установки: $INSTALL_DIR"
mkdir -p $INSTALL_DIR
cd $INSTALL_DIR

# Вывод информации о системе
echo "Информация о системе:"
echo "Операционная система: $(uname -s)"
echo "Версия ядра: $(uname -r)"
echo "Архитектура: $(uname -m)"
echo "=================================================="

# Загрузка основного скрипта установки
echo "Загрузка основного скрипта установки..."
curl -s -O https://raw.githubusercontent.com/nemirting/pop-installer/main/install_pop.sh
chmod +x install_pop.sh

# Проверка успешности загрузки
if [ ! -f "install_pop.sh" ]; then
    echo "ОШИБКА: Не удалось загрузить скрипт установки."
    echo "Проверьте подключение к интернету и доступность репозитория."
    exit 1
fi

echo "Скрипт установки успешно загружен."
echo "=================================================="

# Запрос на запуск скрипта установки
read -p "Запустить установку ноды Pop? (y/n): " start_install
if [[ "$start_install" =~ ^[Yy]$ ]]; then
    echo "Запуск установки..."
    sudo ./install_pop.sh
else
    echo "Установка отменена."
    echo "Для запуска установки вручную выполните команду:"
    echo "cd $INSTALL_DIR && sudo ./install_pop.sh"
fi

# Вывод информации о репозитории
echo "=================================================="
echo "Репозиторий: https://github.com/nemirting/pop-installer"
echo "По вопросам и предложениям обращайтесь в Issues на GitHub"
echo "=================================================="

