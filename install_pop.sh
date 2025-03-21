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
EXCLUDE_CACHE=false  # По умолчанию включаем кэш в резервную копию
REMOVE_ENV_FROM_GITIGNORE=false  # По умолчанию не удаляем .env из .gitignore
SHOW_LOGS_ONLY=false  # По умолчанию не показываем только логи

# Обработка параметров командной строки
for arg in "$@"; do
    case $arg in
        --logs)
            SHOW_LOGS_ONLY=true
            ;;
        --no-cache)
            EXCLUDE_CACHE=true
            ;;
        --remove-env)
            REMOVE_ENV_FROM_GITIGNORE=true
            ;;
    esac
done

# Функция логирования с использованием logger
log() {
    local current_time=$(date +"%Y-%m-%d %H:%M:%S")
    echo "$current_time: $1" >> "$LOG_FILE"
    echo "$current_time: $1"
    
    # Использование logger, если он доступен
    if command -v logger &> /dev/null; then
        logger -t pop_install "$1"
    fi
}

# Функция обработки ошибок
handle_error() {
    local error_message="$1"
    local error_code="${2:-1}"
    log "ОШИБКА: $error_message (код: $error_code)"
    echo "ОШИБКА: $error_message"
    exit "$error_code"
}

# Функция проверки системных требований с использованием free и df -h
check_system_requirements() {
    log "Проверка системных требований..."
    
    # Проверка ОЗУ с использованием free
    local total_ram_mb=$(free -m | awk 'NR==2{print $2}')
    local total_ram_gb=$((total_ram_mb / 1024))
    
    log "Обнаружено ОЗУ: ${total_ram_mb}MB (${total_ram_gb}GB)"
    
    if [ "$total_ram_mb" -lt "$MIN_RAM_MB" ]; then
        handle_error "Недостаточно оперативной памяти. Требуется минимум ${MIN_RAM_MB}MB (4GB), доступно ${total_ram_mb}MB" 2
    fi
    
    # Проверка свободного места на диске с использованием df -h
    local free_disk_gb=$(df -h . | tail -1 | awk '{print $4}' | sed 's/G//')
    
    # Проверка, содержит ли значение 'T' (терабайты)
    if [[ "$free_disk_gb" == *T* ]]; then
        # Конвертация из TB в GB
        free_disk_gb=$(echo "$free_disk_gb" | sed 's/T//')
        free_disk_gb=$(echo "$free_disk_gb * 1024" | bc)
    fi
    
    log "Обнаружено свободное место на диске: ${free_disk_gb}GB"
    
    if (( $(echo "$free_disk_gb < $MIN_DISK_GB" | bc -l) )); then
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
    
    # Архивирование всех важных файлов с учетом параметра --no-cache
    if [ "$EXCLUDE_CACHE" = false ]; then
        log "Создание полной резервной копии (включая кэш)..."
        tar -czf "$backup_file" .env pop_install.log download_cache node_info.json 2>/dev/null || true
    else
        log "Создани�� резервной копии без кэша..."
        tar -czf "$backup_file" .env pop_install.log node_info.json 2>/dev/null || true
    fi
    
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

# Функция проверки статуса ноды с анализом логов
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
        
        # Анализ логов на наличие ошибок
        if systemctl list-unit-files | grep -q pop.service; then
            # Если используется systemd, проверяем журнал
            if sudo journalctl -u pop -n 100 | grep -i "error\|exception\|fail\|critical" > /dev/null; then
                log "Предупреждение: В логах обнаружены ошибки."
                echo "Предупреждение: В логах обнаружены ошибки. Проверьте логи с помощью команды:"
                echo "sudo journalctl -u pop | grep -i 'error\\|exception\\|fail\\|critical'"
            fi
        elif [ -f "/var/log/pop.log" ]; then
            # Если логи пишутся в файл
            if grep -i "error\|exception\|fail\|critical" /var/log/pop.log > /dev/null; then
                log "Предупреждение: В логах обнаружены ошибки."
                echo "Предупреждение: В логах обнаружены ошибки. Проверьте логи с помощью команды:"
                echo "grep -i 'error\\|exception\\|fail\\|critical' /var/log/pop.log"
            fi
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
    
    # Проверка доступности GitHub API
    if ! curl -s "https://api.github.com/repos/PipeNetwork/pop/releases/latest" > /dev/null; then
        log "GitHub API недоступен. Продолжаем с текущей версией."
        return
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
        
        # Установка прав на выполнение с проверкой
        chmod +x pop || handle_error "Не удалось установить права на выполнение" 10
        if [ ! -x "./pop" ]; then
            handle_error "Не удалось установить права на выполнение" 10
        fi
        
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

# Функция проверки реферального кода
validate_referral_code() {
    local referral_code="$1"
    
    # Проверка, что реферальный код не пустой и имеет правильный формат
    if [ -z "$referral_code" ]; then
        return 1
    fi
    
    # Проверка минимальной длины (обычно реферальные коды имеют минимальную длину)
    if [ ${#referral_code} -lt 3 ]; then
        echo "Реферальный код слишком короткий. Минимальная длина - 3 символа."
        return 1
    fi
    
    # Проверка на допустимые символы (буквы, цифры, дефисы, подчеркивания)
    if ! [[ "$referral_code" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        echo "Реферальный код содержит недопустимые символы. Разрешены только буквы, цифры, дефисы и подчеркивания."
        return 1
    fi
    
    return 0
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
            # Проверка введенного реферального кода
            if validate_referral_code "$user_referral"; then
                REFERRAL="$user_referral"
            else
                echo "Введен некорректный реферальный код. Будет использован код по умолчанию."
                REFERRAL="$DEFAULT_REFERRAL"
            fi
        else
            # Используем код по умолчанию
            REFERRAL="$DEFAULT_REFERRAL"
            log "Используется реферальный код по умолчанию: $REFERRAL"
        fi
        
        # Обновляем .env файл
        if [ -f ".env" ]; then
            sed -i "s/^REFERRAL=.*/REFERRAL=$REFERRAL/" .env || true
        fi
    else
        # Проверка существующего реферального кода
        if ! validate_referral_code "$REFERRAL"; then
            echo "Существующий реферальный код некорректен. Будет использован код по умолчанию."
            REFERRAL="$DEFAULT_REFERRAL"
            # Обновляем .env файл
            if [ -f ".env" ]; then
                sed -i "s/^REFERRAL=.*/REFERRAL=$REFERRAL/" .env || true
            fi
        fi
    fi
    
    # Проверка прав на выполнение с улучшенной проверкой
    if [ ! -x "./pop" ]; then
        log "Установка прав на выполнение для файла pop..."
        chmod +x pop || handle_error "Не удалось установить права на выполнение для файла pop" 23
        
        # Дополнительная проверка после chmod
        if [ ! -x "./pop" ]; then
            handle_error "Не удалось установить права на выполнение для файла pop" 23
        fi
    fi
    
    # Проверка наличия файла node_info.json
    if [ -f "node_info.json" ]; then
        log "Обнаружен существующий файл node_info.json. Нода уже может быть зарегистрирована."
        echo "Обнаружен существующий файл node_info.json. Нода уже может быть зарегистрирована."
        return 0
    fi
    
    # Выполняем регистрацию с реферальным кодом
    local registration_output
    registration_output=$(./pop --signup-by-referral-route "$REFERRAL" 2>&1)
    local registration_status=$?
    
    # Проверка результата регистрации
    if [ $registration_status -ne 0 ] || echo "$registration_output" | grep -q "Invalid referral code\|Rate limit\|error\|Error\|failed"; then
        log "Ошибка при регистрации ноды: $registration_output"
        echo "Ошибка при регистрации ноды: $registration_output"
        
        # Проверка на ограничение по частоте запросов
        if echo "$registration_output" | grep -q "Rate limit"; then
            log "Обнаружено ограничение по частоте запросов. Попробуйте повторить через час или с другого IP-адреса."
            echo "Обнаружено ограничение по частоте запросов. Попробуйте повторить через час или с другого IP-адреса."
            echo "Вы можете продолжить установку, но нода не будет зарегистрирована."
            read -p "Продолжить установку без регистрации? (y/n): " continue_without_registration
            if [[ "$continue_without_registration" =~ ^[Yy]$ ]]; then
                log "Продолжение установки без регистрации."
                return 0
            else
                handle_error "Регистрация ноды не удалась из-за ограничения по частоте запросов" 17
            fi
        fi
        
        # Проверка на неверный реферальный код
        if echo "$registration_output" | grep -q "Invalid referral code"; then
            log "Неверный реферальный код. Попробуйте использовать другой код."
            echo "Неверный реферальный код. Попробуйте использовать другой код."
            read -p "Введите другой реферальный код (или нажмите Enter для использования кода по умолчанию): " new_referral
            
            if [ -n "$new_referral" ]; then
                if validate_referral_code "$new_referral"; then
                    REFERRAL="$new_referral"
                else
                    echo "Введен некорректный реферальный код. Будет использован код по умолчанию."
                    REFERRAL="$DEFAULT_REFERRAL"
                fi
            else
                REFERRAL="$DEFAULT_REFERRAL"
            fi
            
            # Обновляем .env файл
            if [ -f ".env" ]; then
                sed -i "s/^REFERRAL=.*/REFERRAL=$REFERRAL/" .env || true
            fi
            
            # Повторная попытка регистрации
            log "Повторная попытка регистрации с кодом: $REFERRAL"
            registration_output=$(./pop --signup-by-referral-route "$REFERRAL" 2>&1)
            registration_status=$?
            
            if [ $registration_status -ne 0 ] || echo "$registration_output" | grep -q "Invalid referral code\|Rate limit\|error\|Error\|failed"; then
                log "Повторная попытка регистрации не удалась: $registration_output"
                echo "Повторная попытка регистрации не удалась: $registration_output"
                echo "Вы можете продолжить установку, но нода не будет зарегистрирована."
                read -p "Продолжить установку без регистрации? (y/n): " continue_without_registration
                if [[ "$continue_without_registration" =~ ^[Yy]$ ]]; then
                    log "Продолжение установки без регистрации."
                    return 0
                else
                    handle_error "Регистрация ноды не удалась" 17
                fi
            fi
        else
            # Другие ошибки
            echo "Вы можете продолжить установку, но нода не будет зарегистрирована."
            read -p "Продолжить установку без регистрации? (y/n): " continue_without_registration
            if [[ "$continue_without_registration" =~ ^[Yy]$ ]]; then
                log "Продолжение установки без регистрации."
                return 0
            else
                handle_error "Регистрация ноды не удалась" 17
            fi
        fi
    fi
    
    log "Нода успешно зарегистрирована с реферальным кодом: $REFERRAL"
    echo "Нода успешно зарегистрирована с реферальным кодом: $REFERRAL"
}

# Функция проверки публичного ключа Solana с исправленной логикой
validate_solana_key() {
    local input_key="$1"
    local max_attempts="$2"
    local attempts=0
    local PUB_KEY=""
    
    while [ -z "$PUB_KEY" ] && [ $attempts -lt $max_attempts ]; do
        if [ $attempts -gt 0 ]; then
            read -p "Введите ваш публичный ключ Solana: " input_key
        fi
        
        # Проверка с помощью solana-keygen, если он установлен
        if command -v solana-keygen &> /dev/null; then
            if solana-keygen verify "$input_key" &> /dev/null; then
                PUB_KEY="$input_key"
                log "Ключ проверен с помощью solana-keygen"
            else
                log "Ключ не прошел проверку solana-keygen"
            fi
        # Резервная проверка формата, если solana-keygen не установлен
        elif [[ "$input_key" =~ ^[1-9A-HJ-NP-Za-km-z]{32,44}$ ]]; then
            PUB_KEY="$input_key"
            log "Ключ проверен по формату (solana-keygen не установлен)"
        else
            log "Ключ не прошел проверку формата"
        fi
        
        # Если ключ не прошел проверку
        if [ -z "$PUB_KEY" ]; then
            attempts=$((attempts + 1))
            remaining=$((max_attempts - attempts))
            echo "Ошибка: Неверный формат публичного ключа Solana. Осталось попыток: $remaining"
            echo "Публичный ключ Solana должен содержать от 32 до 44 символов и состоять из букв и цифр."
            echo "Пример правильного ключа: 7UX2i7SucgLMQcfZ75s3VXmZZY4YRUyJN9X1RgfMoDUi"
            
            if [ $attempts -eq $max_attempts ]; then
                echo "Достигнуто максимальное количество попыток."
                read -p "Хотите продолжить без проверки формата ключа? (y/n): " skip_validation
                if [[ "$skip_validation" =~ ^[Yy]$ ]]; then
                    PUB_KEY="$input_key"
                    echo "Продолжение с введенным ключом без проверки формата."
                    log "Пользователь решил продолжить с непроверенным ключом: $PUB_KEY"
                fi
            fi
        fi
    done
    
    echo "$PUB_KEY"
}

# Функция для удаления .env из .gitignore
remove_env_from_gitignore() {
    log "Удаление .env из .gitignore..."
    
    if [ -f ".gitignore" ]; then
        sed -i '/\.env/d' .gitignore
        log ".env удален из .gitignore"
        echo ".env удален из .gitignore"
    else
        log ".gitignore не найден"
        echo ".gitignore не найден"
    fi
}

# Функция проверки и исправления файла .env
validate_env_file() {
    log "Проверка файла .env..."
    
    local env_valid=true
    local pub_key_found=false
    local referral_found=false
    local ram_found=false
    local disk_found=false
    
    # Проверка существования файла
    if [ ! -f ".env" ]; then
        log "Файл .env не найден."
        return 1
    fi
    
    # Проверка содержимого файла
    while IFS= read -r line || [ -n "$line" ]; do
        # Пропускаем пустые строки и комментарии
        if [ -z "$line" ] || [[ "$line" =~ ^# ]]; then
            continue
        fi
        
        # Проверка формата KEY=VALUE
        if ! [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
            log "Некорректная строка в .env: $line"
            env_valid=false
            break
        fi
        
        # Проверка наличия необходимых переменных
        if [[ "$line" =~ ^PUB_KEY= ]]; then
            pub_key_found=true
            # Проверка, что значение не пустое
            if [[ "$line" == "PUB_KEY=" ]]; then
                log "Пустое значение PUB_KEY в .env"
                env_valid=false
                break
            fi
        elif [[ "$line" =~ ^REFERRAL= ]]; then
            referral_found=true
        elif [[ "$line" =~ ^RAM= ]]; then
            ram_found=true
        elif [[ "$line" =~ ^DISK= ]]; then
            disk_found=true
        fi
    done < ".env"
    
    # Проверка наличия всех необходимых переменных
    if [ "$pub_key_found" = false ] || [ "$ram_found" = false ] || [ "$disk_found" = false ]; then
        log "В файле .env отсутствуют необходимые переменные"
        env_valid=false
    fi
    
    # Если файл некорректен, создаем резервную копию и возвращаем ошибку
    if [ "$env_valid" = false ]; then
        log "Файл .env некорректен. Создание резервной копии..."
        mv .env .env.backup.$(date +%Y%m%d_%H%M%S) || true
        return 1
    fi
    
    log "Файл .env проверен и корректен"
    return 0
}

# Основная часть скрипта
main() {
    log "Начало установки Pop $POP_VERSION..."
    
    # Обработка параметра --remove-env
    if [ "$REMOVE_ENV_FROM_GITIGNORE" = true ]; then
        remove_env_from_gitignore
        # Если это единственная операция, выходим
        if [ "$SHOW_LOGS_ONLY" = false ]; then
            log "Операция удаления .env из .gitignore завершена"
            exit 0
        fi
    fi
    
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
    
    # Установка прав на выполнение с улучшенной проверкой
    log "Установка прав на выполнение для файла pop..."
    chmod +x pop || handle_error "Не удалось установить права на выполнение" 14
    if [ ! -x "./pop" ]; then
        handle_error "Не удалось установить права на выполнение" 14
    fi
    
    # Проверка зависимостей
    log "Проверка зависимостей..."

    # Проверка libssl-dev
    if ! dpkg -s libssl-dev &> /dev/null; then
        log "Установка libssl-dev..."
        sudo apt-get update
        sudo apt-get install -y libssl-dev || handle_error "Не удалось установить libssl-dev" 18
    fi

    # Проверка build-essential
    if ! dpkg -s build-essential &> /dev/null; then
        log "Установка build-essential..."
        sudo apt-get install -y build-essential || handle_error "Не удалось установить build-essential" 30
    fi

    # Проверка pkg-config
    if ! command -v pkg-config &> /dev/null; then
        log "Установка pkg-config..."
        sudo apt-get install -y pkg-config || handle_error "Не удалось установить pkg-config" 31
    fi

    # Проверка jq
    if ! command -v jq &> /dev/null; then
        log "Установка jq..."
        sudo apt-get install -y jq || handle_error "Не удалось установить jq" 15
    fi

    # Проверка git
    if ! command -v git &> /dev/null; then
        log "Установка git..."
        sudo apt-get install -y git || handle_error "Не удалось установить git" 32
    fi

    # Проверка ca-certificates
    if ! dpkg -s ca-certificates &> /dev/null; then
        log "Установка ca-certificates..."
        sudo apt-get install -y ca-certificates || handle_error "Не удалось установить ca-certificates" 33
    fi

    # Проверка net-tools
    if ! dpkg -s net-tools &> /dev/null; then
        log "Установка net-tools..."
        sudo apt-get install -y net-tools || handle_error "Не удалось установить net-tools" 34
    fi

    # Проверка lsof
    if ! command -v lsof &> /dev/null; then
        log "Установка lsof..."
        sudo apt-get install -y lsof || handle_error "Не удалось установить lsof" 35
    fi

    # Проверка libudev-dev (необходимо для работы с USB и аппаратными устройствами)
    if ! dpkg -s libudev-dev &> /dev/null; then
        log "Установка libudev-dev..."
        sudo apt-get install -y libudev-dev || handle_error "Не удалось установить libudev-dev" 36
    fi

    # Проверка libclang-dev (может потребоваться для компиляции некоторых Rust-зависимостей)
    if ! dpkg -s libclang-dev &> /dev/null; then
        log "Установка libclang-dev..."
        sudo apt-get install -y libclang-dev || handle_error "Не удалось установить libclang-dev" 37
    fi

    # Проверка openssl
    if ! command -v openssl &> /dev/null; then
        log "Установка openssl..."
        sudo apt-get install -y openssl || handle_error "Не удалось установить openssl" 38
    fi

    # Проверка solana-keygen (опционально)
    if ! command -v solana-keygen &> /dev/null; then
        log "Предупреждение: solana-keygen не установлен. Будет использована базовая проверка формата ключа."
        echo "Предупреждение: solana-keygen не установлен. Будет использована базовая проверка формата ключа."
        echo "Для более надежной проверки ключей рекомендуется установить solana-cli."
    fi

    log "Все необходимые зависимости установлены"
    
    # Создание директории для кэша
    log "Создание директории для кэша..."
    mkdir -p download_cache || handle_error "Не удалось создать директорию для кэша" 16
    
    # Проверка наличия файла конфигурации .env
    # if [ ! -f ".env" ]; then
    #     log "Файл .env не найден. Необходимо ввести данные для конфигурации."
        
    #     # Запрос публичного ключа с проверкой формата
    #     echo "Введите ваш публичный ключ Solana (32-44 символа, буквы и цифры)."
    #     echo "Пример: 7UX2i7SucgLMQcfZ75s3VXmZZY4YRUyJN9X1RgfMoDUi"
    #     read -p "Публичный ключ Solana: " input_key
    #     PUB_KEY=$(validate_solana_key "$input_key" 3)
        
    #     # Если ключ не был получен, выходим с ошибкой
    #     if [ -z "$PUB_KEY" ]; then
    #         handle_error "Не удалось получить корректный публичный ключ Solana" 24
    #     fi
        
    #     # Запрос реферального кода с проверкой
    #     echo "Введите реферальный код (минимум 3 символа, буквы, цифры, дефисы или подчеркивания)."
    #     read -p "Реферальный код (или нажмите Enter для использования кода по умолчанию): " input_referral
        
    #     if [ -n "$input_referral" ]; then
    #         if validate_referral_code "$input_referral"; then
    #             REFERRAL="$input_referral"
    #         else
    #             echo "Введен некорректный реферальный код. Будет использован код по умолчанию."
    #             REFERRAL="$DEFAULT_REFERRAL"
    #         fi
    #     else
    #         REFERRAL="$DEFAULT_REFERRAL"
    #     fi
        
    #     # Получение информации о системной памяти с использованием free
    #     local total_ram_mb=$(free -m | awk 'NR==2{print $2}')
    #     local total_ram_gb=$((total_ram_mb / 1024))
        
    #     # Запрос размера ОЗУ с проверкой
    #     local min_ram_gb=4
        
    #     echo "Обнаружено ОЗУ: ${total_ram_gb}GB"
    #     echo "Рекомендуемый размер ОЗУ для ноды: ${min_ram_gb}GB - ${total_ram_gb}GB"
        
    #     # Устанавливаем значение по умолчанию
    #     RAM="$min_ram_gb"
    #     echo "Установлено значение ОЗУ по умолчанию: ${RAM}GB"
        
    #     # Спрашиваем, хочет ли пользователь изменить значение
    #     read -p "Хотите изменить размер ОЗУ? (y/n, по умолчанию - n): " change_ram
        
    #     if [[ "$change_ram" =~ ^[Yy]$ ]]; then
    #         local ram_validated=false
    #         local ram_attempts=0
    #         local max_ram_attempts=3
            
    #         while [ "$ram_validated" = false ] && [ $ram_attempts -lt $max_ram_attempts ]; do
    #             read -p "Введите размер оперативной памяти для ноды (в ГБ, целое число): " RAM_INPUT
                
    #             # Проверяем, что введено целое число
    #             if [[ "$RAM_INPUT" =~ ^[0-9]+$ ]]; then
    #                 if [ "$RAM_INPUT" -ge "$min_ram_gb" ]; then
    #                     if [ "$RAM_INPUT" -gt "$total_ram_gb" ]; then
    #                         echo "Предупреждение: Указанный размер ОЗУ (${RAM_INPUT}GB) превышает доступный (${total_ram_gb}GB)."
    #                         read -p "Продолжить с указанным значением? (y/n): " override_ram
    #                         if [[ "$override_ram" =~ ^[Yy]$ ]]; then
    #                             RAM="$RAM_INPUT"
    #                             ram_validated=true
    #                             echo "Установлено значение ОЗУ: ${RAM}GB"
    #                         fi
    #                     else
    #                         RAM="$RAM_INPUT"
    #                         ram_validated=true
    #                         echo "Установлено значение ОЗУ: ${RAM}GB"
    #                     fi
    #                 else
    #                     echo "Ошибка: Размер ОЗУ должен быть не менее ${min_ram_gb}GB."
    #                 fi
    #             else
    #                 echo "Ошибка: Введите целое число без дополнительных символов."
    #             fi
                
    #             ram_attempts=$((ram_attempts + 1))
                
    #             if [ "$ram_validated" = false ] && [ $ram_attempts -eq $max_ram_attempts ]; then
    #                 echo "Достигнуто максимальное количество попыток. Будет использовано значение по умолчанию: ${min_ram_gb}GB"
    #                 RAM="$min_ram_gb"
    #                 break
    #             fi
    #         done
    #     fi
        
    #     # Аналогично улучшим запрос размера диска
    #     local free_disk_gb=$(df -h . | tail -1 | awk '{print $4}' | sed 's/G//')
        
    #     # Проверка, содержит ли значение 'T' (терабайты)
    #     if [[ "$free_disk_gb" == *T* ]]; then
    #         # Конвертация из TB в GB
    #         free_disk_gb=$(echo "$free_disk_gb" | sed 's/T//')
    #         free_disk_gb=$(echo "$free_disk_gb * 1024" | bc)
    #     fi
        
    #     # Запрос размера диска с проверкой
    #     local min_disk_gb=50
        
    #     echo "Обнаружено свободное место на диске: ${free_disk_gb}GB"
    #     echo "Рекомендуемый размер диска для ноды: ${min_disk_gb}GB - ${free_disk_gb}GB"
        
    #     # Устанавливаем значение по умолчанию
    #     DISK="$min_disk_gb"
    #     echo "Установлено значение диска по умолчанию: ${DISK}GB"
        
    #     # Спрашиваем, хочет ли пользователь изменить значение
    #     read -p "Хотите изменить размер диска? (y/n, по умолчанию - n): " change_disk
        
    #     if [[ "$change_disk" =~ ^[Yy]$ ]]; then
    #         local disk_validated=false
    #         local disk_attempts=0
    #         local max_disk_attempts=3
            
    #         while [ "$disk_validated" = false ] && [ $disk_attempts -lt $max_disk_attempts ]; do
    #             read -p "Введите максимальный размер диска для ноды (в ГБ, целое число): " DISK_INPUT
                
    #             # Проверяем, что введено целое число
    #             if [[ "$DISK_INPUT" =~ ^[0-9]+$ ]]; then
    #                 if [ "$DISK_INPUT" -ge "$min_disk_gb" ]; then
    #                     if (( $(echo "$DISK_INPUT > $free_disk_gb" | bc -l) )); then
    #                         echo "Предупреждение: Указанный размер диска (${DISK_INPUT}GB) превышает доступный (${free_disk_gb}GB)."
    #                         read -p "Продолжить с указанным значением? (y/n): " override_disk
    #                         if [[ "$override_disk" =~ ^[Yy]$ ]]; then
    #                             DISK="$DISK_INPUT"
    #                             disk_validated=true
    #                             echo "Установлено значение диска: ${DISK}GB"
    #                         fi
    #                     else
    #                         DISK="$DISK_INPUT"
    #                         disk_validated=true
    #                         echo "Установлено значение диска: ${DISK}GB"
    #                     fi
    #                 else
    #                     echo "Ошибка: Размер диска должен быть не менее ${min_disk_gb}GB."
    #                 fi
    #             else
    #                 echo "Ошибка: Введите целое число без дополнительных символов."
    #             fi
                
    #             disk_attempts=$((disk_attempts + 1))
                
    #             if [ "$disk_validated" = false ] && [ $disk_attempts -eq $max_disk_attempts ]; then
    #                 echo "Достигнуто максимальное количество попыток. Будет использовано значение по умолчанию: ${min_disk_gb}GB"
    #                 DISK="$min_disk_gb"
    #                 break
    #             fi
    #         done
    #     fi
        
    #     # Сохранение данных в .env
    #     echo "PUB_KEY=$PUB_KEY" > .env
    #     echo "REFERRAL=$REFERRAL" >> .env
    #     echo "RAM=$RAM" >> .env
    #     echo "DISK=$DISK" >> .env
        
    #     # Добавление .env в .gitignore (если необходимо)
    #     if [ -f ".gitignore" ]; then
    #         grep -q "^.env$" .gitignore || echo ".env" >> .gitignore
    #     else
    #         echo ".env" > .gitignore
    #     fi
        
    #     log "Файл конфигурации .env создан"
    # else
    #     log "Файл .env найден. Используем существующие данные."
    #     source .env
    # fi

    # Проверка наличия и корректности файла конфигурации .env
    if [ -f ".env" ]; then
        log "Файл .env найден. Проверка корректности..."
        if validate_env_file; then
            log "Файл .env корректен. Используем существующие данные."
            source .env
        else
            log "Файл .env некорректен. Необходимо ввести данные заново."
            create_new_env_file=true
        fi
    else
        log "Файл .env не найден. Необходимо ввести данные для конфигурации."
        create_new_env_file=true
    fi
    
    # Создание нового файла .env при необходимости
    if [ "${create_new_env_file:-false}" = true ]; then
        log "Создание нового файла .env..."
        
        # Запрос публичного ключа с проверкой формата
        echo "Введите ваш публичный ключ Solana (32-44 символа, буквы и цифры)."
        echo "Пример: 7UX2i7SucgLMQcfZ75s3VXmZZY4YRUyJN9X1RgfMoDUi"
        read -p "Публичный ключ Solana: " input_key
        PUB_KEY=$(validate_solana_key "$input_key" 3)
        
        # Если ключ не был получен, выходим с ошибкой
        if [ -z "$PUB_KEY" ]; then
            handle_error "Не удалось получить корректный публичный ключ Solana" 24
        fi
        
        # Запрос реферального кода с проверкой
        echo "Введите реферальный код (минимум 3 символа, буквы, цифры, дефисы или подчеркивания)."
        read -p "Реферальный код (или нажмите Enter для использования кода по умолчанию): " input_referral
        
        if [ -n "$input_referral" ]; then
            if validate_referral_code "$input_referral"; then
                REFERRAL="$input_referral"
            else
                echo "Введен некорректный реферальный код. Будет использован код по умолчанию."
                REFERRAL="$DEFAULT_REFERRAL"
            fi
        else
            REFERRAL="$DEFAULT_REFERRAL"
        fi
        
        # Получение информации о системной памяти с использованием free
        local total_ram_mb=$(free -m | awk 'NR==2{print $2}')
        local total_ram_gb=$((total_ram_mb / 1024))
        
        # Запрос размера ОЗУ с проверкой
        local min_ram_gb=4
        
        echo "Обнаружено ОЗУ: ${total_ram_gb}GB"
        echo "Рекомендуемый размер ОЗУ для ноды: ${min_ram_gb}GB - ${total_ram_gb}GB"
        
        # Устанавливаем значение по умолчанию
        RAM="$min_ram_gb"
        echo "Установлено значение ОЗУ по умолчанию: ${RAM}GB"
        
        # Спрашиваем, хочет ли пользователь изменить значение
        read -p "Хотите изменить размер ОЗУ? (y/n, по умолчанию - n): " change_ram
        
        if [[ "$change_ram" =~ ^[Yy]$ ]]; then
            local ram_validated=false
            local ram_attempts=0
            local max_ram_attempts=3
            
            while [ "$ram_validated" = false ] && [ $ram_attempts -lt $max_ram_attempts ]; do
                read -p "Введите размер оперативной памяти для ноды (в ГБ, целое число): " RAM_INPUT
                
                # Очистка ввода от нечисловых символов
                RAM_INPUT=$(echo "$RAM_INPUT" | tr -cd '0-9')
                
                # Проверяем, что введено целое число
                if [ -n "$RAM_INPUT" ]; then
                    if [ "$RAM_INPUT" -ge "$min_ram_gb" ]; then
                        if [ "$RAM_INPUT" -gt "$total_ram_gb" ]; then
                            echo "Предупреждение: Указанный размер ОЗУ (${RAM_INPUT}GB) превышает доступный (${total_ram_gb}GB)."
                            read -p "Продолжить с указанным значением? (y/n): " override_ram
                            if [[ "$override_ram" =~ ^[Yy]$ ]]; then
                                RAM="$RAM_INPUT"
                                ram_validated=true
                                echo "Установлено значение ОЗУ: ${RAM}GB"
                            fi
                        else
                            RAM="$RAM_INPUT"
                            ram_validated=true
                            echo "Установлено значение ОЗУ: ${RAM}GB"
                        fi
                    else
                        echo "Ошибка: Размер ОЗУ должен быть не менее ${min_ram_gb}GB."
                    fi
                else
                    echo "Ошибка: Размер ОЗУ должен быть числом."
                fi
                
                ram_attempts=$((ram_attempts + 1))
                
                if [ "$ram_validated" = false ] && [ $ram_attempts -eq $max_ram_attempts ]; then
                    echo "Достигнуто максимальное количество попыток. Будет использовано значение по умолчанию: ${min_ram_gb}GB"
                    RAM="$min_ram_gb"
                    break
                fi
            done
        fi
        
        # Аналогично улучшим запрос размера диска
        local free_disk_gb=$(df -h . | tail -1 | awk '{print $4}' | sed 's/G//')
        
        # Проверка, содержит ли значение 'T' (терабайты)
        if [[ "$free_disk_gb" == *T* ]]; then
            # Конвертация из TB в GB
            free_disk_gb=$(echo "$free_disk_gb" | sed 's/T//')
            free_disk_gb=$(echo "$free_disk_gb * 1024" | bc)
        fi
        
        # Запрос размера диска с проверкой
        local min_disk_gb=50
        
        echo "Обнаружено свободное место на диске: ${free_disk_gb}GB"
        echo "Рекомендуемый размер диска для ноды: ${min_disk_gb}GB - ${free_disk_gb}GB"
        
        # Устанавливаем значение по умолчанию
        DISK="$min_disk_gb"
        echo "Установлено значение диска по умолчанию: ${DISK}GB"
        
        # Спрашиваем, хочет ли пользователь изменить значение
        read -p "Хотите изменить размер диска? (y/n, по умолчанию - n): " change_disk
        
        if [[ "$change_disk" =~ ^[Yy]$ ]]; then
            local disk_validated=false
            local disk_attempts=0
            local max_disk_attempts=3
            
            while [ "$disk_validated" = false ] && [ $disk_attempts -lt $max_disk_attempts ]; do
                read -p "Введите максимальный размер диска для ноды (в ГБ, целое число): " DISK_INPUT
                
                # Очистка ввода от нечисловых символов
                DISK_INPUT=$(echo "$DISK_INPUT" | tr -cd '0-9')
                
                # Проверяем, что введено целое число
                if [ -n "$DISK_INPUT" ]; then
                    if [ "$DISK_INPUT" -ge "$min_disk_gb" ]; then
                        if (( $(echo "$DISK_INPUT > $free_disk_gb" | bc -l) )); then
                            echo "Предупреждение: Указанный размер диска (${DISK_INPUT}GB) превышает доступный (${free_disk_gb}GB)."
                            read -p "Продолжить с указанным значением? (y/n): " override_disk
                            if [[ "$override_disk" =~ ^[Yy]$ ]]; then
                                DISK="$DISK_INPUT"
                                disk_validated=true
                                echo "Установлено значение диска: ${DISK}GB"
                            fi
                        else
                            DISK="$DISK_INPUT"
                            disk_validated=true
                            echo "Установлено значение диска: ${DISK}GB"
                        fi
                    else
                        echo "Ошибка: Размер диска должен быть не менее ${min_disk_gb}GB."
                    fi
                else
                    echo "Ошибка: Размер диска должен быть числом."
                fi
                
                disk_attempts=$((disk_attempts + 1))
                
                if [ "$disk_validated" = false ] && [ $disk_attempts -eq $max_disk_attempts ]; then
                    echo "Достигнуто максимальное количество попыток. Будет использовано значение по умолчанию: ${min_disk_gb}GB"
                    DISK="$min_disk_gb"
                    break
                fi
            done
        fi
        
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
if [ "$SHOW_LOGS_ONLY" = true ]; then
    # Если скрипт запущен с параметром --logs, показываем только логи
    if [ -f ".env" ]; then
        source .env
    fi
    show_node_logs
else
    # Иначе запускаем основную функцию
    main
fi

