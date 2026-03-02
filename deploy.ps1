# PowerShell script for deploying Ollama + LiteLLM stack

param(
    [switch]$Help,
    [switch]$SkipDockerCheck,
    [switch]$SkipModelDownload,
    [string]$Model = "",
    [switch]$DownloadAllModels, # Оставлен для обратной совместимости
    [switch]$Uninstall
)

if ($Help) {
    Write-Host @"
Ollama + LiteLLM Deployment Script
===================================

Usage:
  .\deploy.ps1 [parameters]

Parameters:
  -Help                 Show this help message
  -SkipDockerCheck      Skip Docker verification
  -SkipModelDownload    Skip downloading the model
  -Model <model_name>   Specify an additional model to download
  -Uninstall            Completely remove the stack, containers, networks, and all local data
"@
    exit 0
}

# Load .env file
if (Test-Path ".env") {
    Write-Host "Loading environment variables from .env..." -ForegroundColor Yellow
    Get-Content ".env" | Where-Object { $_ -match '^\s*[^#]' -and $_ -match '=' } | ForEach-Object {
        $name, $value = $_ -split '=', 2
        $name = $name.Trim()
        $value = $value.Trim()
        # Remove quotes if present
        $value = $value -replace '^"(.*)"$', '$1' -replace "^'(.*)'$", '$1'
        [Environment]::SetEnvironmentVariable($name, $value, 'Process')
    }
    Write-Host "   OK: .env loaded successfully" -ForegroundColor Green
    Write-Host ""
}

# Если запрошено полное удаление
if ($Uninstall) {
    Write-Host "=== Uninstalling Ollama + LiteLLM Stack ===" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "1. Stopping and removing Docker containers, networks, and volumes..." -ForegroundColor Yellow
    try {
        docker compose down -v
        Write-Host "   OK: Containers and volumes removed" -ForegroundColor Green
    }
    catch {
        Write-Host "   Error: Failed to remove containers - $_" -ForegroundColor Red
    }

    Write-Host "2. Deleting local data directories..." -ForegroundColor Yellow
    $directoriesToRemove = @("ollama_data", "postgres_data")
    foreach ($dir in $directoriesToRemove) {
        if (Test-Path $dir) {
            try {
                Remove-Item -Path $dir -Recurse -Force -ErrorAction Stop
                Write-Host "   OK: Deleted directory $dir" -ForegroundColor Green
            }
            catch {
                Write-Host "   Error: Could not delete $dir. It might be in use. - $_" -ForegroundColor Red
            }
        }
        else {
            Write-Host "   Info: Directory $dir does not exist, skipping." -ForegroundColor Gray
        }
    }

    Write-Host ""
    Write-Host "=== UNINSTALL COMPLETE ===" -ForegroundColor Cyan
    exit 0
}

Write-Host "=== Ollama + LiteLLM Deployment ===" -ForegroundColor Cyan
Write-Host ""

# Get models from environment or use defaults
$planModel = if ($env:PLAN_MODEL) { $env:PLAN_MODEL } else { "deepseek-r1:14b" }
$actModel = if ($env:ACT_MODEL) { $env:ACT_MODEL } else { "qwen2.5-coder:14b" }

function Test-CommandSuccess {
    param($ExitCode)
    return $ExitCode -eq 0
}

# 1. Check Docker
if (-not $SkipDockerCheck) {
    Write-Host "1. Checking Docker..." -ForegroundColor Yellow
    
    try {
        $dockerVersion = docker --version 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "   OK: Docker installed: $dockerVersion" -ForegroundColor Green
        }
        else {
            Write-Host "   Error: Docker not found or not running" -ForegroundColor Red
            exit 1
        }
    }
    catch {
        Write-Host "   Error checking Docker: $_" -ForegroundColor Red
        exit 1
    }
    
    Write-Host "   Checking Docker daemon..." -ForegroundColor Yellow
    try {
        $dockerInfo = docker info 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "   OK: Docker daemon is running" -ForegroundColor Green
        }
        else {
            Write-Host "   Error: Docker daemon is not running. Please start Docker Desktop." -ForegroundColor Red
            exit 1
        }
    }
    catch {
        Write-Host "   Error: $_" -ForegroundColor Red
        exit 1
    }
}

# 2. Create directories
Write-Host "2. Creating project structure..." -ForegroundColor Yellow
$directories = @("ollama_data", "postgres_data")
foreach ($dir in $directories) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Write-Host "   OK: Created directory: $dir" -ForegroundColor Green
    }
    else {
        Write-Host "   OK: Directory already exists: $dir" -ForegroundColor Green
    }
}

# 3. Start Docker Compose
Write-Host "3. Starting Docker Compose stack..." -ForegroundColor Yellow
try {
    Write-Host "   Starting containers..." -ForegroundColor Yellow
    docker compose up -d
    
    if (Test-CommandSuccess $LASTEXITCODE) {
        Write-Host "   OK: Containers started successfully" -ForegroundColor Green
        Start-Sleep -Seconds 5
        docker compose ps
    }
    else {
        Write-Host "   Error starting containers" -ForegroundColor Red
        exit 1
    }
}
catch {
    Write-Host "   Error: $_" -ForegroundColor Red
    exit 1
}

# 4. Download Model(s)
if (-not $SkipModelDownload) {
    Write-Host "4. Downloading models for Plan/Act architecture..." -ForegroundColor Yellow
    Write-Host "   Waiting for Ollama to start (30 seconds)..." -ForegroundColor Yellow
    Start-Sleep -Seconds 30
    
    # Всегда загружаем обе основные модели
    $modelsToDownload = @($planModel, $actModel)
    
    # Если передана кастомная модель через аргумент, добавляем её в очередь
    if ($Model -ne "" -and $Model -ne $planModel -and $Model -ne $actModel) {
        $modelsToDownload += $Model
    }
    
    foreach ($modelToDownload in $modelsToDownload) {
        try {
            Write-Host "   Pulling model: $modelToDownload..." -ForegroundColor Yellow
            docker exec ollama ollama pull $modelToDownload
            
            if (Test-CommandSuccess $LASTEXITCODE) {
                Write-Host "   OK: Model $modelToDownload downloaded successfully" -ForegroundColor Green
            }
            else {
                Write-Host "   Error downloading model $modelToDownload" -ForegroundColor Red
            }
        }
        catch {
            Write-Host "   Error: $_" -ForegroundColor Red
        }
    }
    
    Write-Host "   Listing all available models..." -ForegroundColor Yellow
    docker exec ollama ollama list
}

# 5. Healthcheck
Write-Host "5. Running healthchecks..." -ForegroundColor Yellow

$ollamaPort = if ($env:OLLAMA_PORT) { $env:OLLAMA_PORT } else { "11434" }
$litellmPort = if ($env:LITELLM_PORT) { $env:LITELLM_PORT } else { "4000" }

try {
    $ollamaCheck = Invoke-RestMethod -Uri "http://localhost:$ollamaPort/api/tags" -ErrorAction Stop
    Write-Host "   OK: Ollama is available on port $ollamaPort" -ForegroundColor Green
}
catch {
    Write-Host "   Error: Ollama is not responding - $_" -ForegroundColor Red
}

try {
    $headers = @{ "Authorization" = "Bearer sk-ollama123" }
    $litellmCheck = Invoke-RestMethod -Uri "http://localhost:$litellmPort/v1/models" -Headers $headers -ErrorAction Stop
    Write-Host "   OK: LiteLLM is available on port $litellmPort" -ForegroundColor Green
}
catch {
    Write-Host "   Error: LiteLLM is not responding - $_" -ForegroundColor Red
}

Write-Host ""
Write-Host "=== DEPLOYMENT COMPLETE ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "Cline Configuration Settings:" -ForegroundColor Yellow
Write-Host "  Base URL:   http://localhost:$litellmPort" -ForegroundColor White
Write-Host "  API Key:    sk-ollama123" -ForegroundColor White
Write-Host "  Available Models:" -ForegroundColor White
Write-Host "    - $actModel (Act mode)" -ForegroundColor White
Write-Host "    - $planModel (Plan mode)" -ForegroundColor White
Write-Host ""
Write-Host "Usage for Plan/Act architecture:" -ForegroundColor Yellow
Write-Host "  Plan mode (analysis): Use $planModel" -ForegroundColor White
Write-Host "  Act mode (execution): Use $actModel" -ForegroundColor White
Write-Host ""