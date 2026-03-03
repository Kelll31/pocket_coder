#!/bin/bash

# Default parameter values
HELP=false
SKIP_DOCKER_CHECK=false
SKIP_MODEL_DOWNLOAD=false
MODEL=""
UNINSTALL=false

# Parse arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -Help|--help|-h) HELP=true; shift ;;
        -SkipDockerCheck|--skip-docker-check) SKIP_DOCKER_CHECK=true; shift ;;
        -SkipModelDownload|--skip-model-download) SKIP_MODEL_DOWNLOAD=true; shift ;;
        -Model|--model) MODEL="$2"; shift 2 ;;
        -Uninstall|--uninstall) UNINSTALL=true; shift ;;
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
  -Uninstall            Completely remove the stack, containers, networks, and all local data
EOF
    exit 0
fi

create_custom_model() {
    local target_model=$1
    local modelfile_path=$2
    local clinerules_path=$3
    local base_model=$4

    if [ -f "$modelfile_path" ]; then
        echo -e "   \e[33mCreating custom model $target_model from $modelfile_path...\e[0m"
        if cat "$modelfile_path" | docker exec -i ollama ollama create "$target_model" -f -; then
            echo -e "   \e[32mOK: Model $target_model created\e[0m"
        else
            echo -e "   \e[31mError: Failed to create $target_model\e[0m"
        fi
    elif [ -f "$clinerules_path" ]; then
        echo -e "   \e[90mWarning: $modelfile_path not found. Generating from $clinerules_path...\e[0m"
        local rules
        rules=$(cat "$clinerules_path")
        local modelfile="FROM $base_model\nSYSTEM \"\"\"\n$rules\n\"\"\""
        if echo -e "$modelfile" | docker exec -i ollama ollama create "$target_model" -f -; then
            echo -e "   \e[32mOK: Model $target_model created\e[0m"
        else
            echo -e "   \e[31mError: Failed to create $target_model\e[0m"
        fi
    fi
}

# Load environment variables from .env
if [ -f ".env" ]; then
    echo -e "\e[33mLoading environment variables from .env...\e[0m"
    set -a
    source .env
    set +a
    echo -e "   \e[32mOK: .env loaded successfully\e[0m\n"
fi

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

# 3. Start Docker Compose
echo -e "\e[33m3. Starting Docker Compose...\e[0m"
if docker compose up -d; then
    echo -e "   \e[32mOK: Containers started\e[0m"
else
    echo -e "   \e[31mError: Failed to start containers\e[0m"
    exit 1
fi
sleep 5

targetAct="qwen2.5-coder:14b-act"
targetPlan="deepseek-r1:14b-plan"

# 4. Pull Base Models and Create Custom Versions
if [ "$SKIP_MODEL_DOWNLOAD" = false ]; then
    echo -e "\e[33m4. Pulling base models and creating custom versions...\e[0m"
    echo -e "   \e[33mWaiting for Ollama to be ready (30 seconds)...\e[0m"
    sleep 30

    baseAct="qwen2.5-coder:14b"
    basePlan="deepseek-r1:14b"

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

# 5. Healthcheck
echo -e "\e[33m5. Running healthchecks...\e[0m"
litellmPort="${LITELLM_PORT:-4000}"

# Get LITELLM_MASTER_KEY from env or default to sk-ollama123 if not set yet
litellmKey="${LITELLM_MASTER_KEY:-sk-ollama123}"

if curl -s -f -H "Authorization: Bearer $litellmKey" "http://localhost:$litellmPort/v1/models" > /dev/null; then
    echo -e "   \e[32mOK: LiteLLM responsive on port $litellmPort\e[0m"
else
    echo -e "   \e[31mError: LiteLLM not responding\e[0m"
fi

echo -e "\n\e[36m=== DEPLOYMENT COMPLETE ===\e[0m\n"
echo -e "\e[33mCline Configuration (OpenAI Compatible):\e[0m"
echo -e "\e[37m  Base URL:   http://localhost:$litellmPort/v1\e[0m"
echo -e "\e[37m  API Key:    $litellmKey\e[0m"
echo -e "\e[37m  Model Act:  $targetAct\e[0m"
echo -e "\e[37m  Model Plan: $targetPlan\e[0m\n"
