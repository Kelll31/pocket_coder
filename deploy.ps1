# PowerShell script for deploying Ollama + LiteLLM stack with Custom Modelfiles

param(
    [switch]$Help,
    [switch]$SkipDockerCheck,
    [switch]$SkipModelDownload,
    [string]$Model = "",
    [switch]$Uninstall,
    [string]$MasterKey = ""
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
  -MasterKey <key>      Specify the LiteLLM Master Key
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

if ($MasterKey) {
    [Environment]::SetEnvironmentVariable('LITELLM_MASTER_KEY', $MasterKey, 'Process')
}

if (-not $env:LITELLM_MASTER_KEY) {
    Write-Host "Error: LITELLM_MASTER_KEY is not set." -ForegroundColor Red
    Write-Host "Please set it in the .env file or pass the -MasterKey parameter for secure access." -ForegroundColor Red
    exit 1
}

function Test-CommandSuccess {
    param($ExitCode)
    return $ExitCode -eq 0
}

function New-CustomModel {
    param(
        [string]$TargetModel,
        [string]$ModelfilePath,
        [string]$ClinerulesPath,
        [string]$BaseModel
    )

    $containerPath = "/tmp/$([System.IO.Path]::GetFileName($ModelfilePath))"

    if (Test-Path $ModelfilePath) {
        Write-Host "   Creating custom model $TargetModel from $ModelfilePath..." -ForegroundColor Yellow
        docker cp $ModelfilePath "ollama:$containerPath"
        docker exec ollama ollama create $TargetModel -f $containerPath
        if ($LASTEXITCODE -eq 0) {
            Write-Host "   OK: Model $TargetModel created" -ForegroundColor Green
        }
        else {
            Write-Host "   Error: Failed to create $TargetModel" -ForegroundColor Red
        }
        docker exec ollama rm -f $containerPath
    }
    elseif (Test-Path $ClinerulesPath) {
        Write-Host "   Warning: $ModelfilePath not found. Generating from $ClinerulesPath..." -ForegroundColor Gray
        $rules = Get-Content $ClinerulesPath -Raw
        $modelfile = "FROM $BaseModel`nSYSTEM `"`"`"`n$rules`n`"`"`""
        $tempFile = New-TemporaryFile
        Set-Content -Path $tempFile.FullName -Value $modelfile -Encoding UTF8
        docker cp $tempFile.FullName "ollama:$containerPath"
        docker exec ollama ollama create $TargetModel -f $containerPath
        if ($LASTEXITCODE -eq 0) {
            Write-Host "   OK: Model $TargetModel created" -ForegroundColor Green
        }
        else {
            Write-Host "   Error: Failed to create $TargetModel" -ForegroundColor Red
        }
        docker exec ollama rm -f $containerPath
        Remove-Item -Path $tempFile.FullName -Force
    }
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

    # Create Act model
    New-CustomModel -TargetModel $targetAct -ModelfilePath "act.Modelfile" -ClinerulesPath ".clinerules-act" -BaseModel $baseAct

    # Create Plan model
    New-CustomModel -TargetModel $targetPlan -ModelfilePath "plan.Modelfile" -ClinerulesPath ".clinerules-plan" -BaseModel $basePlan
}

# 5. Healthcheck
Write-Host "5. Running healthchecks..." -ForegroundColor Yellow
$litellmPort = if ($env:LITELLM_PORT) { $env:LITELLM_PORT } else { "4000" }
$litellmKey = $env:LITELLM_MASTER_KEY

Write-Host "   Waiting for LiteLLM to be ready..." -ForegroundColor Yellow
$litellmReady = $false
for ($i = 0; $i -lt 15; $i++) {
    try {
        $headers = @{ "Authorization" = "Bearer $litellmKey" }
        $check = Invoke-RestMethod -Uri "http://localhost:$litellmPort/v1/models" -Headers $headers -ErrorAction Stop
        Write-Host "   OK: LiteLLM responsive on port $litellmPort" -ForegroundColor Green
        $litellmReady = $true
        break
    } catch {
        Start-Sleep -Seconds 2
    }
}

if (-not $litellmReady) {
    Write-Host "   Error: LiteLLM not responding after 30 seconds." -ForegroundColor Red
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