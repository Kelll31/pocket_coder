#!/bin/bash

# Default parameter values
HELP=false
SKIP_DOCKER_CHECK=false
SKIP_MODEL_DOWNLOAD=false
MODEL=""
ACT_MODEL=""
PLAN_MODEL=""
UNINSTALL=false
MASTER_KEY=""
POSTGRES_PASSWORD=""

# Parse arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -Help|--help|-h) HELP=true; shift ;;
        -SkipDockerCheck|--skip-docker-check) SKIP_DOCKER_CHECK=true; shift ;;
        -SkipModelDownload|--skip-model-download) SKIP_MODEL_DOWNLOAD=true; shift ;;
        -Model|--model) MODEL="$2"; shift 2 ;;
        -ActModel|--act-model) ACT_MODEL="$2"; shift 2 ;;
        -PlanModel|--plan-model) PLAN_MODEL="$2"; shift 2 ;;
        -Uninstall|--uninstall) UNINSTALL=true; shift ;;
        -MasterKey|--master-key) MASTER_KEY="$2"; shift 2 ;;
        -PostgresPassword|--postgres-password) POSTGRES_PASSWORD="$2"; shift 2 ;;
        *) echo "Unknown parameter passed: $1"; exit 1 ;;
    esac
done

if [ "$HELP" = true ]; then
    cat << EOF
Ollama + LiteLLM Deployment Script
===================================

Usage:
  ./deploy.sh [parameters]

Parameters:
  -Help                 Show this help message
  -SkipDockerCheck      Skip Docker verification
  -SkipModelDownload    Skip downloading and creating custom models
  -Model <model_name>   Specify an additional base model to download
  -ActModel <model>     Specify the base model for Act Mode (default: user prompt or qwen2.5-coder:7b)
  -PlanModel <model>    Specify the base model for Plan Mode (default: user prompt or deepseek-r1:8b)
  -Uninstall            Completely remove the stack, containers, networks, and all local data
  -MasterKey <key>      Specify the LiteLLM Master Key
  -PostgresPassword <pw> Specify the Postgres Database Password
EOF
    exit 0
fi

create_custom_model() {
    local target_model=$1
    local modelfile_path=$2
    local clinerules_path=$3
    local base_model=$4

    local container_path="/tmp/$(basename "$modelfile_path")"

    if [ -f "$modelfile_path" ]; then
        echo -e "   \e[33mCreating custom model $target_model from $modelfile_path...\e[0m"
        docker cp "$modelfile_path" "ollama:$container_path"
        if docker exec ollama ollama create "$target_model" -f "$container_path"; then
            echo -e "   \e[32mOK: Model $target_model created\e[0m"
        else
            echo -e "   \e[31mError: Failed to create $target_model\e[0m"
        fi
        docker exec ollama rm -f "$container_path"
    elif [ -f "$clinerules_path" ]; then
        echo -e "   \e[90mWarning: $modelfile_path not found. Generating from $clinerules_path...\e[0m"
        local rules
        rules=$(cat "$clinerules_path")
        local modelfile="FROM $base_model\nSYSTEM \"\"\"\n$rules\n\"\"\""
        local temp_file=$(mktemp)
        echo -e "$modelfile" > "$temp_file"
        docker cp "$temp_file" "ollama:$container_path"
        if docker exec ollama ollama create "$target_model" -f "$container_path"; then
            echo -e "   \e[32mOK: Model $target_model created\e[0m"
        else
            echo -e "   \e[31mError: Failed to create $target_model\e[0m"
        fi
        docker exec ollama rm -f "$container_path"
        rm -f "$temp_file"
    fi
}

generate_litellm_config() {
    local act_model=$1
    local plan_model=$2

    cat << EOF > litellm_config.yaml
model_list:
  - model_name: ${act_model}-act
    litellm_params:
      model: ollama/${act_model}-act
      api_base: http://ollama:11434
      api_key: "ollama"
      max_tokens: 32768
      temperature: 0.8
      top_p: 0.95

  - model_name: ${plan_model}-plan
    litellm_params:
      model: ollama/${plan_model}-plan
      api_base: http://ollama:11434
      api_key: "ollama"
      max_tokens: 32768
      temperature: 0.3
      top_p: 0.8

litellm_settings:
  drop_params: true
  set_verbose: false
  default_max_tokens: 32768
  default_temperature: 0.7

general_settings:
  completion_model: "${act_model}-act"
  use_azure_ad: false
  default_timeout: 1200
  disable_user_auth: false

ollama_settings:
  custom_llm_provider: "ollama"
  num_retries: 5
  request_timeout: 1200
  max_retries: 3
EOF
    echo -e "   \e[32mOK: litellm_config.yaml updated for selected models\e[0m"
}

# Load environment variables from .env
if [ -f ".env" ]; then
    echo -e "\e[33mLoading environment variables from .env...\e[0m"
    set -a
    source .env
    set +a
    echo -e "   \e[32mOK: .env loaded successfully\e[0m"
else
    echo -e "\e[33mCreating new .env file...\e[0m"
    touch .env
fi

ENV_CHANGED=false

# Apply overrides from parameters
if [ -n "$MASTER_KEY" ]; then
    export LITELLM_MASTER_KEY="$MASTER_KEY"
    ENV_CHANGED=true
fi
if [ -n "$POSTGRES_PASSWORD" ]; then
    export POSTGRES_PASSWORD="$POSTGRES_PASSWORD"
    ENV_CHANGED=true
fi

# Auto-generate if missing
if [ -z "$LITELLM_MASTER_KEY" ]; then
    export LITELLM_MASTER_KEY="sk-$(openssl rand -hex 16 2>/dev/null || date +%s%N | sha256sum | head -c 32)"
    ENV_CHANGED=true
    echo -e "   \e[32mGenerated new LITELLM_MASTER_KEY\e[0m"
fi
if [ -z "$POSTGRES_PASSWORD" ]; then
    export POSTGRES_PASSWORD="$(openssl rand -hex 16 2>/dev/null || date +%s%N | sha256sum | head -c 32)"
    ENV_CHANGED=true
    echo -e "   \e[32mGenerated new POSTGRES_PASSWORD\e[0m"
fi

# Save .env if changed
if [ "$ENV_CHANGED" = true ]; then
    # Create or replace variables in .env file
    if grep -q "^LITELLM_MASTER_KEY=" .env; then
        sed -i.bak "s|^LITELLM_MASTER_KEY=.*|LITELLM_MASTER_KEY=$LITELLM_MASTER_KEY|" .env && rm -f .env.bak
    else
        echo "LITELLM_MASTER_KEY=$LITELLM_MASTER_KEY" >> .env
    fi

    if grep -q "^POSTGRES_PASSWORD=" .env; then
        sed -i.bak "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=$POSTGRES_PASSWORD|" .env && rm -f .env.bak
    else
        echo "POSTGRES_PASSWORD=$POSTGRES_PASSWORD" >> .env
    fi
    echo -e "   \e[32mOK: .env file updated with secure credentials\e[0m"
fi
echo -e "\n"

# Full uninstallation logic
if [ "$UNINSTALL" = true ]; then
    echo -e "\e[33m=== Uninstalling Ollama + LiteLLM Stack ===\e[0m\n"

    echo -e "\e[33m1. Stopping and removing containers and volumes...\e[0m"
    if docker compose down -v; then
        echo -e "   \e[32mOK: Containers removed\e[0m"
    else
        echo -e "   \e[31mError: Failed to remove containers\e[0m"
    fi

    echo -e "\e[33m2. Deleting local data directories...\e[0m"
    for dir in "ollama_data" "postgres_data"; do
        if [ -d "$dir" ]; then
            rm -rf "$dir"
            echo -e "   \e[32mOK: Directory $dir deleted\e[0m"
        fi
    done

    echo -e "\n\e[36m=== UNINSTALL COMPLETE ===\e[0m"
    exit 0
fi

echo -e "\e[36m=== Deploying Ollama + LiteLLM (Custom Modelfiles) ===\e[0m\n"

baseAct="qwen2.5-coder:7b"
basePlan="deepseek-r1:8b"

if [ "$SKIP_MODEL_DOWNLOAD" = true ]; then
    echo -e "\e[90mModel download skipped via parameter.\e[0m"
else
    if [ -n "$ACT_MODEL" ] && [ -n "$PLAN_MODEL" ]; then
        baseAct="$ACT_MODEL"
        basePlan="$PLAN_MODEL"
        echo -e "\e[32mUsing provided models: Act=$baseAct, Plan=$basePlan\e[0m"
    else
        echo -e "\e[36mSelect Model Configuration:\e[0m"
        echo "1. 10GB VRAM Optimized (qwen2.5-coder:7b + deepseek-r1:8b) - Recommended"
        echo "2. High Performance (qwen2.5-coder:14b + deepseek-r1:14b) - Requires 16GB+ VRAM"
        echo "3. Custom Models"
        echo "4. Skip Model Download"

        read -p "Enter your choice (1-4) [Default: 1]: " choice

        case "$choice" in
            2)
                baseAct="qwen2.5-coder:14b"
                basePlan="deepseek-r1:14b"
                echo -e "\e[32mSelected High Performance models.\e[0m"
                ;;
            3)
                read -p "Enter Act Model (e.g., qwen2.5-coder:7b) [Default: qwen2.5-coder:7b]: " inputAct
                baseAct=${inputAct:-"qwen2.5-coder:7b"}
                read -p "Enter Plan Model (e.g., deepseek-r1:8b) [Default: deepseek-r1:8b]: " inputPlan
                basePlan=${inputPlan:-"deepseek-r1:8b"}
                echo -e "\e[32mSelected Custom models: Act=$baseAct, Plan=$basePlan\e[0m"
                ;;
            4)
                SKIP_MODEL_DOWNLOAD=true
                echo -e "\e[33mSkipping model download.\e[0m"
                ;;
            *)
                baseAct="qwen2.5-coder:7b"
                basePlan="deepseek-r1:8b"
                echo -e "\e[32mSelected 10GB VRAM Optimized models.\e[0m"
                ;;
        esac
    fi
fi
echo -e "\n"

# 1. Docker Verification
if [ "$SKIP_DOCKER_CHECK" = false ]; then
    echo -e "\e[33m1. Checking Docker...\e[0m"
    if docker_version=$(docker --version 2>&1); then
        echo -e "   \e[32mOK: Docker is running ($docker_version)\e[0m"
    else
        echo -e "   \e[31mError: Docker not found. Please install Docker.\e[0m"
        exit 1
    fi
fi

# 2. Create Directory Structure
echo -e "\e[33m2. Creating project structure...\e[0m"
for dir in "ollama_data" "postgres_data"; do
    if [ ! -d "$dir" ]; then
        mkdir -p "$dir"
        echo -e "   \e[32mOK: Directory $dir created\e[0m"
    fi
done

# 3. Generate LiteLLM Config
echo -e "\e[33m3. Generating LiteLLM Config...\e[0m"
generate_litellm_config "$baseAct" "$basePlan"

# 4. Start Docker Compose
echo -e "\e[33m4. Starting Docker Compose...\e[0m"
if docker compose up -d; then
    echo -e "   \e[32mOK: Containers started\e[0m"
else
    echo -e "   \e[31mError: Failed to start containers\e[0m"
    exit 1
fi
sleep 5

targetAct="${baseAct}-act"
targetPlan="${basePlan}-plan"

# 5. Pull Base Models and Create Custom Versions
if [ "$SKIP_MODEL_DOWNLOAD" = false ]; then
    echo -e "\e[33m5. Pulling base models and creating custom versions...\e[0m"
    echo -e "   \e[33mWaiting for Ollama to be ready (30 seconds)...\e[0m"
    sleep 30

    modelsToPull=("$baseAct" "$basePlan")
    if [ -n "$MODEL" ]; then
        modelsToPull+=("$MODEL")
    fi

    for m in "${modelsToPull[@]}"; do
        echo -e "   \e[33mPulling base model: $m...\e[0m"
        docker exec ollama ollama pull "$m"
    done

    # Create Act model
    create_custom_model "$targetAct" "act.Modelfile" ".clinerules-act" "$baseAct"

    # Create Plan model
    create_custom_model "$targetPlan" "plan.Modelfile" ".clinerules-plan" "$basePlan"
fi

# 6. Healthcheck
echo -e "\e[33m6. Running healthchecks...\e[0m"
litellmPort="${LITELLM_PORT:-4000}"

# Use LITELLM_MASTER_KEY directly, as it's required for security
litellmKey="${LITELLM_MASTER_KEY}"

echo -e "   \e[33mWaiting for LiteLLM to be ready...\e[0m"
litellm_ready=false
for i in {1..15}; do
    if curl -s -f -H "Authorization: Bearer $litellmKey" "http://localhost:$litellmPort/v1/models" > /dev/null; then
        echo -e "   \e[32mOK: LiteLLM responsive on port $litellmPort\e[0m"
        litellm_ready=true
        break
    fi
    sleep 2
done

if [ "$litellm_ready" = false ]; then
    echo -e "   \e[31mError: LiteLLM not responding after 30 seconds.\e[0m"
fi

echo -e "\n\e[36m=== DEPLOYMENT COMPLETE ===\e[0m\n"
echo -e "\e[33mCline Configuration (OpenAI Compatible):\e[0m"
echo -e "\e[37m  Base URL:   http://localhost:$litellmPort/v1\e[0m"
echo -e "\e[37m  API Key:    $litellmKey\e[0m"
echo -e "\e[37m  Model Act:  $targetAct\e[0m"
echo -e "\e[37m  Model Plan: $targetPlan\e[0m\n"
