# Ollama + LiteLLM Docker Compose Stack (MVP)

Локальное развертывание связки Ollama с поддержкой GPU и LiteLLM прокси для работы с моделями через OpenAI-совместимый API. Полностью автоматизированное развертывание с PowerShell скриптом.

## Структура проекта

```
.
├── docker-compose.yml      # Конфигурация Docker Compose
├── litellm_config.yaml     # Конфигурация LiteLLM
├── .env                    # Переменные окружения
├── README.md               # Эта инструкция
├── deploy.ps1              # PowerShell скрипт автоматического развертывания
└── ollama_data/            # Папка для хранения моделей (создается автоматически)
```

## Предварительные требования

1. **Docker** и **Docker Compose** установлены на системе
2. **NVIDIA GPU** (опционально, но рекомендуется для производительности)
3. **NVIDIA Container Toolkit** установлен для поддержки GPU в контейнерах

### Установка NVIDIA Container Toolkit (для Linux)

```bash
# Для Ubuntu/Debian
distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
curl -s -L https://nvidia.github.io/nvidia-docker/gpgkey | sudo apt-key add -
curl -s -L https://nvidia.github.io/nvidia-docker/$distribution/nvidia-docker.list | sudo tee /etc/apt/sources.list.d/nvidia-docker.list
sudo apt-get update && sudo apt-get install -y nvidia-container-toolkit
sudo systemctl restart docker
```

## Автоматическое развертывание (PowerShell)

Для Windows пользователей доступен автоматический скрипт развертывания:

### Использование PowerShell скрипта:

```powershell
# Запуск с правами администратора (рекомендуется)
.\deploy.ps1

# Показать справку
.\deploy.ps1 -Help

# Пропустить проверку Docker
.\deploy.ps1 -SkipDockerCheck

# Пропустить загрузку модели
.\deploy.ps1 -SkipModelDownload

# Указать другую модель
.\deploy.ps1 -Model "llama3.2:3b"
```

### Что делает скрипт:
1. Проверяет наличие и работоспособность Docker
2. Создает необходимые директории
3. Запускает Docker Compose стек
4. Загружает указанную модель в Ollama
5. Проверяет работоспособность всех сервисов
6. Выводит итоговую информацию для настройки

## Быстрый старт (вручную)

### 1. Запуск стека

```bash
# Запуск в фоновом режиме
docker compose up -d

# Просмотр логов
docker compose logs -f

# Остановка стека
docker compose down
```

### 2. Загрузка модели в Ollama

После запуска контейнера Ollama, нужно скачать модель:

```bash
# Скачать модель qwen2.5-coder:14b
docker exec ollama ollama pull qwen2.5-coder:14b

# Проверить список доступных моделей
docker exec ollama ollama list
```

### 3. Проверка работоспособности

#### Проверка Ollama:
```bash
# Проверить доступность Ollama
curl http://localhost:11434/api/tags
```

#### Проверка LiteLLM:
```bash
# Проверить доступность LiteLLM
curl http://localhost:4000/health

# Проверить список моделей через LiteLLM
curl http://localhost:4000/v1/models \
  -H "Authorization: Bearer sk-ollama123"
```

## Использование с OpenAI-совместимыми клиентами

### Base URL для клиентов (например, Cline, OpenWebUI, и др.):
```
http://localhost:4000
```

### Пример использования с curl:

```bash
# Запрос к модели через LiteLLM
curl http://localhost:4000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer sk-ollama123" \
  -d '{
    "model": "qwen2.5-coder:14b",
    "messages": [
      {"role": "user", "content": "Напиши hello world на Python"}
    ],
    "temperature": 0.7
  }'
```

## Настройка Cline

Для настройки Cline используйте следующие параметры:

- **Base URL**: `http://localhost:4000`
- **API Key**: `sk-ollama123`
- **Model**: `qwen2.5-coder:14b`

### Визуальная настройка подключения

<div style="display: flex; justify-content: space-between; align-items: flex-start; gap: 20px;">
  <div style="flex: 1;">
    <img src="images/plan_mode_settings.png" alt="Настройки Plan Mode в Cline" style="width: 100%; max-width: 600px; border: 1px solid #ddd; border-radius: 4px;">
    <p style="text-align: center; font-size: 0.9em; color: #666; margin-top: 8px;">Настройки Plan Mode</p>
  </div>
  <div style="flex: 1;">
    <img src="images/act_mode_settings.png" alt="Настройки Act Mode в Cline" style="width: 100%; max-width: 600px; border: 1px solid #ddd; border-radius: 4px;">
    <p style="text-align: center; font-size: 0.9em; color: #666; margin-top: 8px;">Настройки Act Mode</p>
  </div>
</div>

## Конфигурация

### Переменные окружения (.env)

| Переменная | Значение по умолчанию | Описание |
|------------|----------------------|----------|
| OLLAMA_IMAGE | `ollama/ollama:latest` | Образ Ollama |
| LITELLM_IMAGE | `ghcr.io/berriai/litellm:main-latest` | Образ LiteLLM |
| OLLAMA_PORT | `11434` | Порт Ollama |
| LITELLM_PORT | `4000` | Порт LiteLLM |

### Конфигурация LiteLLM (litellm_config.yaml)

- Модель: `qwen2.5-coder:14b`
- Эндпоинт Ollama: `http://ollama:11434`
- Мастер-ключ: `sk-ollama123`

## Добавление новых моделей

1. Скачать модель в Ollama:
```bash
docker exec ollama ollama pull <название-модели>
```

2. Добавить модель в `litellm_config.yaml`:
```yaml
model_list:
  - model_name: qwen2.5-coder:14b
    litellm_params:
      model: ollama/qwen2.5-coder:14b
      api_base: http://ollama:11434
      api_key: "ollama"
  - model_name: llama3.2:3b  # Новая модель
    litellm_params:
      model: ollama/llama3.2:3b
      api_base: http://ollama:11434
      api_key: "ollama"
```

3. Перезапустить LiteLLM:
```bash
docker compose restart litellm
```

## Устранение неполадок

### Проблемы с GPU

```bash
# Проверить доступность GPU в Docker
docker run --rm --gpus all nvidia/cuda:11.0-base nvidia-smi

# Если GPU не доступен, проверьте установку NVIDIA Container Toolkit
nvidia-container-cli --version
```

### Проблемы с сетью

```bash
# Проверить доступность сервисов
docker compose ps

# Проверить логи конкретного сервиса
docker compose logs ollama
docker compose logs litellm
```

### Проблемы с загрузкой модели

```bash
# Проверить свободное место на диске
df -h

# Очистить кэш Docker (осторожно!)
docker system prune -a
```

## Разработка на Delphi (Object Pascal)

### Контекст разработки
Проект включает файл `.clinerules`, который содержит подробные инструкции для работы с кодом на Delphi (Object Pascal). Этот файл задает контекст для AI-ассистента при генерации и анализе кода.

### Ключевые правила из .clinerules:

**Структура проекта Delphi:**
```
ProjectRoot/
├── Source/           # Исходный код
│   ├── Core/        # Основные модули
│   ├── Forms/       # Формы и их модули
│   ├── Components/  # Кастомные компоненты
│   ├── Services/    # Сервисные классы
│   └── Utils/       # Вспомогательные утилиты
├── Packages/        # Пакеты Delphi
│   ├── Runtime/     # Runtime пакеты
│   └── DesignTime/  # DesignTime пакеты
└── Scripts/        # Скрипты сборки
```

**Управление памятью:**
- Обязательное использование `try...finally` блоков
- Использование `FreeAndNil` для безопасного освобождения объектов
- Правильная работа с интерфейсами (reference counting)

**Соглашения об именовании:**
- `T` - префикс для типов (классов, записей)
- `F` - префикс для приватных полей класса
- `I` - префикс для интерфейсов
- Константы в верхнем регистре

**Сборка без IDE:**
- Компиляция через `dcc32.exe`, `dcc64.exe` или `MSBuild`
- Автоматизация сборки через `.bat` и PowerShell скрипты
- Разделение на runtime и designtime пакеты

### Рекомендуемые модели для Delphi

Помимо `qwen2.5-coder:14b`, для разработки на Delphi хорошо подходят:

1. **deepseek-coder:6.14b** - отлично понимает Object Pascal, хорош для работы с VCL
2. **codellama:14b** - имеет хорошую поддержку Delphi
3. **wizardcoder:14b** - хорошо справляется с генерацией компонентов

### Загрузка дополнительных моделей:
```bash
# Для Delphi разработки рекомендуется
docker exec ollama ollama pull deepseek-coder:6.14b
docker exec ollama ollama pull codellama:14b
```

### Настройки для больших файлов
Конфигурация LiteLLM оптимизирована для работы с большими `.pas` и `.dfm` файлами:
- `max_tokens: 16384` - увеличенный контекст
- `request_timeout: 900` - 15 минут для обработки
- `num_retries: 5` - больше попыток при ошибках

### Пример использования для Delphi задач
```bash
# Запрос на создание компонента Delphi
curl http://localhost:4000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer sk-ollama123" \
  -d '{
    "model": "deepseek-coder:6.14b",
    "messages": [
      {"role": "system", "content": "Ты эксперт по Delphi (Object Pascal). Следуй правилам из .clinerules."},
      {"role": "user", "content": "Создай кастомный компонент TMyButton, наследующий от TButton"}
    ],
    "temperature": 0.7,
    "max_tokens": 4096
  }'
```

## Режимы Plan и Act

Проект поддерживает архитектуру разделения ролей для разработки на Delphi VCL:

### Plan Mode (Архитектор/Аналитик)
- **Модель**: `deepseek-r1:14b`
- **Назначение**: Анализ архитектуры, выявление проблем, проектирование решений
- **Задачи**:
  - Анализ .pas модулей и связей в .dfm
  - Поиск утечек памяти и архитектурных проблем
  - Проектирование компонентов и интерфейсов
  - Составление пошаговых планов модификации кода
- **Правила**: Следует `.clinerules-plan`

### Act Mode (Исполнитель)
- **Модель**: `qwen2.5-coder:14b`
- **Назначение**: Быстрая реализация утвержденных планов
- **Задачи**:
  - Написание готового к компиляции Object Pascal кода
  - Строгое соблюдение правил управления памятью VCL
  - Сохранение целостности больших функций
  - Работа с DFM-файлами
- **Правила**: Следует `.clinerules-act`

### Процесс работы
1. **Plan Mode**: Анализирует код, выявляет проблемы, составляет план
2. **Act Mode**: Берет утвержденный план и реализует его в виде кода

### Конфигурация моделей
В `litellm_config.yaml` настроены обе модели:
- `deepseek-r1:14b` - для аналитического мышления (temperature: 0.3, max_tokens: 32768)
- `qwen2.5-coder:14b` - для генерации кода (temperature: 0.7, max_tokens: 16384)

### Использование в Cline/OpenWebUI
- Для анализа и планирования: Выберите модель `deepseek-r1:14b`
- Для реализации кода: Выберите модель `qwen2.5-coder:14b`
- Base URL: `http://localhost:4000`
- API Key: `sk-ollama123`

### Загрузка моделей
```powershell
# Загрузить все модели для Plan/Act архитектуры
.\deploy.ps1 -DownloadAllModels

# Или по отдельности
.\deploy.ps1 -Model "deepseek-r1:14b"
.\deploy.ps1 -Model "qwen2.5-coder:14b"
```

## Лицензия

Проект предоставляется как есть. Используйте на свой страх и риск.
