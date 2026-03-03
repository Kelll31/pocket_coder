# PowerShell script for deploying Ollama + LiteLLM stack with Custom Modelfiles

param(
    [switch]$Help,
    [switch]$SkipDockerCheck,
    [switch]$SkipModelDownload,
    [string]$Model = "",
    [switch]$Uninstall
)

# Force UTF8 encoding for piping to prevent "no Modelfile found" errors in Ollama
$OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::InputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Centralized data directory configuration
$DataDirectories = @("ollama_data", "postgres_data")

if ($Help) {
    Write-Host @"
Ollama + LiteLLM Deployment Script
===================================

Usage:
  .\deploy.ps1 [parameters]

Parameters:
  -Help                 Show this help message
  -SkipDockerCheck      Skip Docker verification
  -SkipModelDownload    Skip downloading and creating custom models
  -Model <model_name>   Specify an additional base model to download
  -Uninstall            Completely remove the stack, containers, networks, and all local data
"@
    exit 0
}

# Load environment variables from .env
if (Test-Path ".env") {
    Write-Host "Loading environment variables from .env..." -ForegroundColor Yellow
    Get-Content ".env" | Where-Object { $_ -match '^\s*[^#]' -and $_ -match '=' } | ForEach-Object {
        $name, $value = $_ -split '=', 2
        $name = $name.Trim()
        $value = $value.Trim()
        $value = $value -replace '^"(.*)"$', '$1' -replace "^'(.*)'$", '$1'
        [Environment]::SetEnvironmentVariable($name, $value, 'Process')
    }
    Write-Host "   OK: .env loaded successfully" -ForegroundColor Green
    Write-Host ""
}

function Test-CommandSuccess {
    param($ExitCode)
    return $ExitCode -eq 0
}

# Full uninstallation logic
if ($Uninstall) {
    Write-Host "=== Uninstalling Ollama + LiteLLM Stack ===" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "1. Stopping and removing containers and volumes..." -ForegroundColor Yellow
    try {
        docker compose down -v
        Write-Host "   OK: Containers removed" -ForegroundColor Green
    }
    catch {
        Write-Host "   Error: Failed to remove containers - $_" -ForegroundColor Red
    }

    Write-Host "2. Deleting local data directories..." -ForegroundColor Yellow
    $directoriesToRemove = $DataDirectories
    foreach ($dir in $directoriesToRemove) {
        if (Test-Path $dir) {
            Remove-Item -Path $dir -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host "   OK: Directory $dir deleted" -ForegroundColor Green
        }
    }

    Write-Host ""
    Write-Host "=== UNINSTALL COMPLETE ===" -ForegroundColor Cyan
    exit 0
}

Write-Host "=== Deploying Ollama + LiteLLM (Custom Modelfiles) ===" -ForegroundColor Cyan
Write-Host ""

# 1. Docker Verification
if (-not $SkipDockerCheck) {
    Write-Host "1. Checking Docker..." -ForegroundColor Yellow
    $dockerVersion = docker --version 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "   Error: Docker not found. Please install Docker Desktop." -ForegroundColor Red
        exit 1
    }
    Write-Host "   OK: Docker is running ($dockerVersion)" -ForegroundColor Green
}

# 2. Create Directory Structure
Write-Host "2. Creating project structure..." -ForegroundColor Yellow
$directories = $DataDirectories
foreach ($dir in $directories) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Write-Host "   OK: Directory $dir created" -ForegroundColor Green
    }
}

# Pre-flight check for required environment variables
Write-Host "Checking required environment variables..." -ForegroundColor Yellow
if (-not $env:POSTGRES_PASSWORD) {
    Write-Host "   Error: POSTGRES_PASSWORD must be set in .env" -ForegroundColor Red
    exit 1
}
if (-not $env:LITELLM_MASTER_KEY) {
    Write-Host "   Error: LITELLM_MASTER_KEY must be set in .env" -ForegroundColor Red
    exit 1
}
Write-Host "   OK: Required variables are set" -ForegroundColor Green
Write-Host ""

# 3. Start Docker Compose
Write-Host "3. Starting Docker Compose..." -ForegroundColor Yellow
docker compose up -d
if (-not (Test-CommandSuccess $LASTEXITCODE)) {
    Write-Host "   Error: Failed to start containers" -ForegroundColor Red
    exit 1
}
Write-Host "   OK: Containers started" -ForegroundColor Green
Start-Sleep -Seconds 5

# 4. Pull Base Models and Create Custom Versions
if (-not $SkipModelDownload) {
    Write-Host "4. Pulling base models and creating custom versions..." -ForegroundColor Yellow
    $ollamaPort = if ($env:OLLAMA_PORT) { $env:OLLAMA_PORT } else { "11434" }
    Write-Host "   Waiting for Ollama to be ready..." -ForegroundColor Yellow
    $ollamaReady = $false
    for ($i = 0; $i -lt 15; $i++) {
        try {
            $null = Invoke-RestMethod -Uri "http://localhost:${ollamaPort}/api/tags" -ErrorAction Stop
            Write-Host "   OK: Ollama is ready" -ForegroundColor Green
            $ollamaReady = $true
            break
        } catch {
            Start-Sleep -Seconds 2
        }
    }
    if (-not $ollamaReady) {
        Write-Host "   Warning: Ollama not ready after 30 seconds. Proceeding anyway..." -ForegroundColor Red
    }

    $baseAct = "qwen2.5-coder:14b"
    $basePlan = "deepseek-r1:14b"
    $targetAct = "qwen2.5-coder:14b-act"
    $targetPlan = "deepseek-r1:14b-plan"

    $modelsToPull = @($baseAct, $basePlan)
    if ($Model -ne "") { $modelsToPull += $Model }

    foreach ($m in $modelsToPull) {
        Write-Host "   Pulling base model: $m..." -ForegroundColor Yellow
        docker exec ollama ollama pull $m
    }

    # Create Act model from act.Modelfile
    if (Test-Path "act.Modelfile") {
        Write-Host "   Creating custom model $targetAct from act.Modelfile..." -ForegroundColor Yellow
        $content = Get-Content "act.Modelfile" -Raw
        $content | docker exec -i ollama ollama create $targetAct -f -
        if ($LASTEXITCODE -eq 0) {
            Write-Host "   OK: Model $targetAct created" -ForegroundColor Green
        }
        else {
            Write-Host "   Error: Failed to create $targetAct" -ForegroundColor Red
        }
    }
    elseif (Test-Path ".clinerules-act") {
        Write-Host "   Warning: act.Modelfile not found. Generating from .clinerules-act..." -ForegroundColor Gray
        $rules = Get-Content ".clinerules-act" -Raw
        $modelfile = "FROM $baseAct`nSYSTEM `"`"`"`n$rules`n`"`"`""
        $modelfile | docker exec -i ollama ollama create $targetAct -f -
        if ($LASTEXITCODE -eq 0) {
            Write-Host "   OK: Model $targetAct created" -ForegroundColor Green
        }
    }

    # Create Plan model from plan.Modelfile
    if (Test-Path "plan.Modelfile") {
        Write-Host "   Creating custom model $targetPlan from plan.Modelfile..." -ForegroundColor Yellow
        $content = Get-Content "plan.Modelfile" -Raw
        $content | docker exec -i ollama ollama create $targetPlan -f -
        if ($LASTEXITCODE -eq 0) {
            Write-Host "   OK: Model $targetPlan created" -ForegroundColor Green
        }
        else {
            Write-Host "   Error: Failed to create $targetPlan" -ForegroundColor Red
        }
    }
    elseif (Test-Path ".clinerules-plan") {
        Write-Host "   Warning: plan.Modelfile not found. Generating from .clinerules-plan..." -ForegroundColor Gray
        $rules = Get-Content ".clinerules-plan" -Raw
        $modelfile = "FROM $basePlan`nSYSTEM `"`"`"`n$rules`n`"`"`""
        $modelfile | docker exec -i ollama ollama create $targetPlan -f -
        if ($LASTEXITCODE -eq 0) {
            Write-Host "   OK: Model $targetPlan created" -ForegroundColor Green
        }
    }
}

# 5. Healthcheck
Write-Host "5. Running healthchecks..." -ForegroundColor Yellow
$litellmPort = if ($env:LITELLM_PORT) { $env:LITELLM_PORT } else { "4000" }
$litellmKey = $env:LITELLM_MASTER_KEY

try {
    $headers = @{ "Authorization" = "Bearer $litellmKey" }
    $check = Invoke-RestMethod -Uri "http://localhost:$litellmPort/v1/models" -Headers $headers -ErrorAction Stop
    Write-Host "   OK: LiteLLM responsive on port $litellmPort" -ForegroundColor Green
}
catch {
    Write-Host "   Error: LiteLLM not responding - $_" -ForegroundColor Red
}

Write-Host ""
Write-Host "=== DEPLOYMENT COMPLETE ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "Cline Configuration (OpenAI Compatible):" -ForegroundColor Yellow
Write-Host "  Base URL:   http://localhost:$litellmPort/v1" -ForegroundColor White
Write-Host "  API Key:    $litellmKey" -ForegroundColor White
Write-Host "  Model Act:  $targetAct" -ForegroundColor White
Write-Host "  Model Plan: $targetPlan" -ForegroundColor White
Write-Host ""