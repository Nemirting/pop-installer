#!/bin/bash

# Улучшенный скрипт установки Pop с дополнительными функциями безопасности, надежности,
# просмотром логов и автозапуском при перезагрузке
# Исправлена ошибка с регистрацией ноды, правами доступа и проверкой формата ключа

# Переменные
POP_VERSION="v0.2.8"
LOG_FILE="pop_install.log"
TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S")
BACKUP_DIR="pop_backups"
MIN_RAM_MB=4096  # Минимум 4 ГБ ОЗУ
MIN_DISK_GB=50   # Минимум 50 ГБ диска
CHECKSUM_URL="https://dl.pipecdn.app/${POP_VERSION}/pop.sha256"
DEFAULT_REFERRAL="default"  # Замените на официальный реферальный код, если он известен

# Функция логирования
log() {
    local current_time=$(date +"%Y-%m-%d %H:%M:%S")
    echo "$current_time: $1" >> "$LOG_FILE"
    echo "$current_time: $1"
}

# Функция обработки ошибок
handle_error() {
    local error_message="$1"
    local error_code="${2:-1}"
    log "ОШИБКА: $error_message (код: $error_code)"
    echo "ОШИБКА: $error_message"
    exit "$error_code"
}

# Функция проверки системных требований
check_system_requirements() {
    log "Проверка системных требований..."
    
    # Проверка ОЗУ
    local total_ram_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    local total_ram_mb=$((total_ram_kb / 1024))
    local total_ram_gb=$((total_ram_mb / 1024))
    
    log "Обнаружено ОЗУ: ${total_ram_mb}MB (${total_ram_gb}GB)"
    
    if [ "$total_ram_mb" -lt "$MIN_RAM_MB" ]; then
        handle_error "Недостаточно оперативной памяти. Требуется минимум ${MIN_RAM_MB}MB (4GB), доступно ${total_ram_mb}MB" 2
    fi
    
    # Проверка свободного места на диске
    local free_disk_kb=$(df -k . | tail -1 | awk '{print $4}')
    local free_disk_mb=$((free_disk_kb / 1024))
    local free_disk_gb=$((free_disk_mb / 1024))
    
    log "Обнаружено свободное место на диске: ${free_disk_mb}MB (${free_disk_gb}GB)"
    
    if [ "$free_disk_gb" -lt "$MIN_DISK_GB" ]; then
        handle_error "Недостаточно места на диске. Требуется минимум ${MIN_DISK_GB}GB, доступно ${free_disk_gb}GB" 3
    fi
    
    # Проверка прав суперпользователя
    if [ "$(id -u)" -ne 0 ] && ! sudo -n true 2>/dev/null; then
        log "Предупреждение: Для некоторых операций потребуются права суперпользователя"
    fi
    
    log "Системные требования удовлетворены"
}

# Функция создания резервной копии
backup_configuration() {
    log "Создание резервной копии конфигурации..."
    
    # Создание директории для резервных копий, если она не существует
    mkdir -p "$BACKUP_DIR" || handle_error "Не удалось создать директорию для резервных копий" 4
    
    # Создание резервной копии с временной меткой
    local backup_file="${BACKUP_DIR}/pop_config_$(date +%Y%m%d_%H%M%S).tar.gz"
    
    # Архивирование всех важных файлов
    tar -czf "$backup_file" .env pop_install.log download_cache 2>/dev/null || true
    
    log "Резервная копия создана: $backup_file"
}

# Функция проверки контрольной суммы
verify_checksum() {
    local file="$1"
    local expected_checksum="$2"
    
    log "Проверка контрольной суммы для $file..."
    
    # Проверка наличия утилиты sha256sum
    if ! command -v sha256sum &> /dev/null; then
        log "Установка sha256sum..."
        sudo apt-get update
        sudo apt-get install -y coreutils || handle_error "Не удалось установить coreutils (sha256sum)" 5
    fi
    
    # Вычисление контрольной суммы
    local actual_checksum=$(sha256sum "$file" | awk '{print $1}')
    
    # Сравнение контрольных сумм
    if [ "$actual_checksum" != "$expected_checksum" ]; then
        handle_error "Проверка контрольной суммы не удалась. Ожидалось: $expected_checksum, Получено: $actual_checksum" 6
    fi
    
    log "Контрольная сумма проверена успешно"
}

# Функция проверки статуса ноды
check_node_status() {
    log "Проверка статуса ноды..."
    
    # Проверка, запущен ли процесс pop
    if pgrep -f "pop --ram" > /dev/null || systemctl is-active --quiet pop; then
        log "Нода Pop успешно запущена и работает"
        echo "Нода Pop успешно запущена и работает"
        
        # Дополнительная информация о ноде (если доступна)
        if [ -x "./pop" ]; then
            echo "Информация о ноде:"
            ./pop --status 2>/dev/null || echo "Команда статуса недоступна"
        fi
    else
        log "Предупреждение: Нода Pop не обнаружена в списке процессов"
        echo "Предупреждение: Нода Pop не обнаружена в списке процессов"
    fi
}

# Функция автоматического обновления
auto_update() {
    log "Проверка наличия обновлений..."
    
    # Проверка наличия jq
    if ! command -v jq &> /dev/null; then
        log "Установка jq..."
        sudo apt-get update
        sudo apt-get install -y jq || handle_error "Не удалось установить jq" 7
    fi
    
    # Получение последней версии
    local latest_version
    latest_version=$(curl -s "https://api.github.com/repos/PipeNetwork/pop/releases/latest" | jq -r '.tag_name' 2>/dev/null)
    
    # Проверка успешности получения версии
    if [ -z "$latest_version" ] || [ "$latest_version" == "null" ]; then
        log "Не удалось получить информацию о последней версии. Продолжаем с текущей версией."
        return
    fi
    
    log "Текущая версия: $POP_VERSION, Последняя версия: $latest_version"
    
    # Сравнение версий
    if [ "$latest_version" != "$POP_VERSION" ]; then
        log "Доступна новая версия: $latest_version. Выполняем обновление..."
        
        # Создание резервной копии перед обновлением
        backup_configuration
        
        # Остановка текущей ноды
        if pgrep -f "pop --ram" > /dev/null; then
            log "Остановка текущей ноды..."
            sudo pkill -f "pop --ram" || log "Предупреждение: Не удалось остановить ноду"
            sleep 2
        elif systemctl is-active --quiet pop; then
            log "Остановка сервиса ноды..."
            sudo systemctl stop pop || log "Предупреждение: Не удалось остановить сервис ноды"
            sleep 2
        fi
        
        # Сохранение текущего бинарного файла
        if [ -f "pop" ]; then
            mv pop pop.old || log "Предупреждение: Не удалось переименовать старый бинарный файл"
        fi
        
        # Загрузка новой версии
        local new_pop_url="https://dl.pipecdn.app/${latest_version}/pop"
        log "Загрузка новой версии с $new_pop_url..."
        curl -L -o pop "$new_pop_url" || handle_error "Не удалось загрузить новую версию" 8
        
        # Загрузка контрольной суммы для новой версии
        local new_checksum_url="https://dl.pipecdn.app/${latest_version}/pop.sha256"
        local expected_checksum
        expected_checksum=$(curl -s "$new_checksum_url") || handle_error "Не удалось загрузить контрольную сумму" 9
        
        # Проверка контрольной суммы
        verify_checksum "pop" "$expected_checksum"
        
        # Установка прав на выполнение
        chmod +x pop || handle_error "Не удалось установить права на выполнение" 10
        
        # Обновление переменной версии
        POP_VERSION="$latest_version"
        log "Обновление успешно завершено до версии $POP_VERSION"
        
        # Перезапуск сервиса, если он был настроен
        if systemctl list-unit-files | grep -q pop.service; then
            log "Перезапуск сервиса ноды..."
            sudo systemctl restart pop || log "Предупреждение: Не удалось перезапустить сервис ноды"
        fi
    else
        log "Установлена последняя версия. Обновление не требуется."
    fi
}

# Функция для создания systemd сервиса (автозапуск при перезагрузке)
create_systemd_service() {
    log "Создание systemd сервиса для автозапуска ноды Pop при перезагрузке..."
    
    # Получение текущего пути
    local current_dir=$(pwd)
    local username=$(whoami)
    
    # Создание файла сервиса
    sudo tee /etc/systemd/system/pop.service > /dev/null << EOL
[Unit]
Description=Pop Node Service
After=network.target

[Service]
ExecStart=${current_dir}/pop --ram ${RAM} --max-disk ${DISK} --cache-dir ${current_dir}/download_cache --pubKey ${PUB_KEY} --enable-80-443
WorkingDirectory=${current_dir}
StandardOutput=journal
StandardError=journal
Restart=always
User=${username}

[Install]
WantedBy=multi-user.target
EOL
    
    # Перезагрузка systemd, включение и запуск сервиса
    sudo systemctl daemon-reload || handle_error "Не удалось перезагрузить systemd" 20
    sudo systemctl enable pop || handle_error "Не удалось включить автозапуск сервиса" 21
    
    # Если нода уже запущена как процесс, останавливаем её
    if pgrep -f "pop --ram" > /dev/null; then
        log "Остановка текущей ноды для перехода на systemd сервис..."
        sudo pkill -f "pop --ram" || log "Предупреждение: Не удалось остановить ноду"
        sleep 2
    fi
    
    # Запуск сервиса
    sudo systemctl start pop || handle_error "Не удалось запустить сервис" 22
    
    log "Systemd сервис создан и запущен. Нода будет автоматически запускаться при перезагрузке сервера."
    echo "Systemd сервис создан и запущен. Нода будет автоматически запускаться при перезагрузке сервера."
}

# Функция для отображения логов ноды
show_node_logs() {
    log "Отображение логов работающей ноды. Нажмите Ctrl+C для выхода."
    echo "Отображение логов работающей ноды. Нажмите Ctrl+C для выхода."
    
    # Проверка, настроен ли systemd сервис
    if systemctl list-unit-files | grep -q pop.service; then
        # Если используется systemd
        sudo journalctl -u pop -f
    elif [ -f "/var/log/pop.log" ]; then
        # Если логи пишутся в файл
        tail -f /var/log/pop.log
    else
        # Если не удалось определить метод логирования, пробуем найти процесс и отслеживать его вывод
        local pop_pid=$(pgrep -f "pop --ram")
        if [ -n "$pop_pid" ]; then
            echo "Отслеживание вывода процесса Pop (PID: $pop_pid)..."
            sudo strace -p "$pop_pid" -e trace=write -s 1000 2>&1 | grep -v "resume" | grep "write"
        else
            echo "Не удалось определить метод логирования ноды."
            echo "Попробуйте проверить документацию Pop для получения информации о логах."
        fi
    fi
}

# Функция регистрации ноды (исправленная)
register_node() {
    log "Регистрация ноды..."
    
    # Проверка наличия реферального кода
    if [ -z "$REFERRAL" ]; then
        # Если реферальный код не указан, запрашиваем его у пользователя
        echo "Для регистрации ноды требуется реферальный код."
        read -p "Введите реферальный код (или нажмите Enter для использования кода по умолчанию): " user_referral
        
        if [ -n "$user_referral" ]; then
            REFERRAL="$user_referral"
        else
            # Используем код по умолчанию
            REFERRAL="$DEFAULT_REFERRAL"
            log "Используется реферальный код по умолчанию: $REFERRAL"
        fi
        
        # Обновляем .env файл
        if [ -f ".env" ]; then
            sed -i "s/^REFERRAL=.*/REFERRAL=$REFERRAL/" .env || true
        fi
    fi
    
    # Проверка прав на выполнение
    if [ ! -x "./pop" ]; then
        log "Установка прав на выполнение для файла pop..."
        chmod +x pop || handle_error "Не удалось установить права на выполнение для файла pop" 23
    fi
    
    # Выполняем регистрацию с реферальным кодом
    ./pop --signup-by-referral-route "$REFERRAL" || handle_error "Не удалось зарегистрировать ноду с реферальным кодом: $REFERRAL" 17
    
    log "Нода успешно зарегистрирована с реферальным кодом: $REFERRAL"
}

# Функция проверки публичного ключа Solana
validate_solana_key() {
    local input_key="$1"
    local max_attempts="$2"
    local attempts=0
    local PUB_KEY=""
    
    while [ -z "$PUB_KEY" ] && [ $attempts -lt $max_attempts ]; do
        if [ $attempts -gt 0 ]; then
            read -p "Введите ваш публичный ключ Solana: " input_key
        fi
        
        # Более гибкая проверка формата ключа Solana
        if [[ "$input_key" =~ ^[1-9A-HJ-NP-Za-km-z]{32,44}$ ]]; then
            PUB_KEY="$input_key"
        else
            attempts=$((attempts + 1))
            remaining=$((max_attempts - attempts))
            echo "Ошибка: Неверный формат публичного ключа Solana. Осталось попыток: $remaining"
            
            if [ $attempts -eq $max_attempts ]; then
                echo "Достигнуто максимальное количество попыток."
                read -p "Хотите продолжить без проверки формата ключа? (y/n): " skip_validation
                if [[ "$skip_validation" =~ ^[Yy]$ ]]; then
                    PUB_KEY="$input_key"
                    echo "Продолжение с введенным ключом без проверки формата."
                fi
            fi
        fi
    done
    
    echo "$PUB_KEY"
}

# Основная часть скрипта
main() {
    log "Начало установки Pop $POP_VERSION..."
    
    # Проверка системных требований
    check_system_requirements
    
    # Проверка и установка curl, если он отсутствует
    if ! command -v curl &> /dev/null; then
        log "Установка curl..."
        sudo apt-get update
        sudo apt-get install -y curl || handle_error "Не удалось установить curl" 11
    fi
    
    # Проверка наличия обновлений
    auto_update
    
    # Скачивание бинарного файла pop (если он еще не загружен)
    if [ ! -f "pop" ]; then
        log "Скачивание бинарного файла pop..."
        POP_URL="https://dl.pipecdn.app/${POP_VERSION}/pop"
        curl -L -o pop "${POP_URL}" || handle_error "Не удалось скачать pop" 12
        
        # Загрузка контрольной суммы
        local expected_checksum
        expected_checksum=$(curl -s "$CHECKSUM_URL") || handle_error "Не удалось загрузить контрольную сумму" 13
        
        # Проверка контрольной суммы
        verify_checksum "pop" "$expected_checksum"
    fi
    
    # Установка прав на выполнение
    log "Установка прав на выполнение для файла pop..."
    chmod +x pop || handle_error "Не удалось установить права на выполнение" 14
    
    # Проверка зависимостей
    log "Проверка зависимостей..."
    if ! command -v jq &> /dev/null; then
        log "Установка jq..."
        sudo apt-get install -y jq || handle_error "Не удалось установить jq" 15
    fi
    
    # Создание директории для кэша
    log "Создание директории для кэша..."
    mkdir -p download_cache || handle_error "Не удалось создать директорию для кэша" 16
    
    # Проверка наличия файла конфигурации .env
    if [ ! -f ".env" ]; then
        log "Файл .env не найден. Необходимо ввести данные для конфигурации."
        
        # Запрос публичного ключа с проверкой формата
        read -p "Введите ваш публичный ключ Solana: " input_key
        PUB_KEY=$(validate_solana_key "$input_key" 3)
        
        # Если ключ не был получен, выходим с ошибкой
        if [ -z "$PUB_KEY" ]; then
            handle_error "Не удалось получить корректный публичный ключ Solana" 24
        fi
        
        read -p "Введите вашу реферальную ссылку (если есть, иначе оставьте пустым): " REFERRAL
        
        # Получение информации о системной памяти
        local total_ram_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
        local total_ram_mb=$((total_ram_kb / 1024))
        local total_ram_gb=$((total_ram_mb / 1024))
        
        # Запрос размера ОЗУ с проверкой
        local min_ram_gb=4
        local ram_validated=false
        local ram_attempts=0
        local max_ram_attempts=3
        
        echo "Обнаружено ОЗУ: ${total_ram_gb}GB"
        echo "Рекомендуемый размер ОЗУ для ноды: ${min_ram_gb}GB - ${total_ram_gb}GB"
        
        while [ "$ram_validated" = false ] && [ $ram_attempts -lt $max_ram_attempts ]; do
            read -p "Введите размер оперативной памяти для ноды (в ГБ, например, 8): " RAM_INPUT
            
            # Проверка введенного значения
            if [[ "$RAM_INPUT" =~ ^[0-9]+$ ]]; then
                if [ "$RAM_INPUT" -ge "$min_ram_gb" ]; then
                    if [ "$RAM_INPUT" -gt "$total_ram_gb" ]; then
                        echo "Предупреждение: Указанный размер ОЗУ (${RAM_INPUT}GB) превышает доступный (${total_ram_gb}GB)."
                        read -p "Продолжить с указанным значением? (y/n): " override_ram
                        if [[ "$override_ram" =~ ^[Yy]$ ]]; then
                            RAM="$RAM_INPUT"
                            ram_validated=true
                        fi
                    else
                        RAM="$RAM_INPUT"
                        ram_validated=true
                    fi
                else
                    echo "Ошибка: Размер ОЗУ должен быть не менее ${min_ram_gb}GB."
                fi
            else
                echo "Ошибка: Размер ОЗУ должен быть числом."
            fi
            
            ram_attempts=$((ram_attempts + 1))
            
            if [ "$ram_validated" = false ] && [ $ram_attempts -eq $max_ram_attempts ]; then
                echo "Достигнуто максимальное количество попыток."
                read -p "Использовать рекомендуемое значение (${min_ram_gb}GB)? (y/n): " use_default_ram
                if [[ "$use_default_ram" =~ ^[Yy]$ ]]; then
                    RAM="$min_ram_gb"
                    ram_validated=true
                else
                    handle_error "Не удалось получить корректный размер ОЗУ" 25
                fi
            fi
        done
        
        # Получение информации о свободном месте на диске
        local free_disk_kb=$(df -k . | tail -1 | awk '{print $4}')
        local free_disk_mb=$((free_disk_kb / 1024))
        local free_disk_gb=$((free_disk_mb / 1024))
        
        # Запрос размера диска с проверкой
        local min_disk_gb=50
        local disk_validated=false
        local disk_attempts=0
        local max_disk_attempts=3
        
        echo "Обнаружено свободное место на диске: ${free_disk_gb}GB"
        echo "Рекомендуемый размер диска для ноды: ${min_disk_gb}GB - ${free_disk_gb}GB"
        
        while [ "$disk_validated" = false ] && [ $disk_attempts -lt $max_disk_attempts ]; do
            read -p "Введите максимальный размер диска для ноды (в ГБ, например, 500): " DISK_INPUT
            
            # Проверка введенного значения
            if [[ "$DISK_INPUT" =~ ^[0-9]+$ ]]; then
                if [ "$DISK_INPUT" -ge "$min_disk_gb" ]; then
                    if [ "$DISK_INPUT" -gt "$free_disk_gb" ]; then
                        echo "Предупреждение: Указанный размер диска (${DISK_INPUT}GB) превышает доступный (${free_disk_gb}GB)."
                        read -p "Продолжить с указанным значением? (y/n): " override_disk
                        if [[ "$override_disk" =~ ^[Yy]$ ]]; then
                            DISK="$DISK_INPUT"
                            disk_validated=true
                        fi
                    else
                        DISK="$DISK_INPUT"
                        disk_validated=true
                    fi
                else
                    echo "Ошибка: Размер диска должен быть не менее ${min_disk_gb}GB."
                fi
            else
                echo "Ошибка: Размер диска должен быть числом."
            fi
            
            disk_attempts=$((disk_attempts + 1))
            
            if [ "$disk_validated" = false ] && [ $disk_attempts -eq $max_disk_attempts ]; then
                echo "Достигнуто максимальное количество попыток."
                read -p "Использовать рекомендуемое значение (${min_disk_gb}GB)? (y/n): " use_default_disk
                if [[ "$use_default_disk" =~ ^[Yy]$ ]]; then
                    DISK="$min_disk_gb"
                    disk_validated=true
                else
                    handle_error "Не удалось получить корректный размер диска" 26
                fi
            fi
        done
        
        # Сохранение данных в .env
        echo "PUB_KEY=$PUB_KEY" > .env
        echo "REFERRAL=$REFERRAL" >> .env
        echo "RAM=$RAM" >> .env
        echo "DISK=$DISK" >> .env
        
        # Добавление .env в .gitignore (если необходимо)
        if [ -f ".gitignore" ]; then
            grep -q "^.env$" .gitignore || echo ".env" >> .gitignore
        else
            echo ".env" > .gitignore
        fi
        
        log "Файл конфигурации .env создан"
    else
        log "Файл .env найден. Используем существующие данные."
        source .env
    fi
    
    # Создание резервной копии конфигурации
    backup_configuration
    
    # Регистрация ноды (используем новую функцию)
    register_node
    
    # Запрос о создании systemd сервиса для автозапуска
    read -p "Настроить автозапуск ноды при перезагрузке сервера? (y/n): " setup_autostart
    if [[ "$setup_autostart" =~ ^[Yy]$ ]]; then
        create_systemd_service
    else
        # Запуск ноды напрямую, если не выбран автозапуск
        log "Запуск ноды..."
        sudo ./pop --ram "$RAM" --max-disk "$DISK" --cache-dir download_cache --pubKey "$PUB_KEY" --enable-80-443 || handle_error "Не удалось запустить ноду" 19
    fi
    
    # Проверка статуса ноды
    sleep 5  # Даем ноде время на запуск
    check_node_status
    
    # Запрос о просмотре логов
    read -p "Хотите просмотреть логи работающей ноды? (y/n): " show_logs
    if [[ "$show_logs" =~ ^[Yy]$ ]]; then
        show_node_logs
    else
        log "Установка и настройка Pop успешно завершены."
        echo "Установка и настройка Pop успешно завершены."
        
        # Вывод инструкций по просмотру логов
        if systemctl list-unit-files | grep -q pop.service; then
            echo "Для просмотра логов ноды в будущем используйте команду:"
            echo "sudo journalctl -u pop -f"
        else
            echo "Для просмотра логов ноды в будущем запустите скрипт с параметром --logs:"
            echo "bash $(basename "$0") --logs"
        fi
    fi
}

# Обработка параметров командной строки
if [ "$1" = "--logs" ]; then
    # Если скрипт запущен с параметром --logs, показываем только логи
    if [ -f ".env" ]; then
        source .env
    fi
    show_node_logs
else
    # Иначе запускаем основную функцию
    main
fi

