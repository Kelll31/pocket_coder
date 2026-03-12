# PowerShell script for deploying Ollama + LiteLLM stack with Custom Modelfiles

param(
    [switch]$Help,
    [switch]$SkipDockerCheck,
    [switch]$SkipModelDownload,
    [string]$Model = "",
    [string]$ActModel = "",
    [string]$PlanModel = "",
    [switch]$Uninstall,
    [string]$MasterKey = "",
    [string]$PostgresPassword = ""
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
  -ActModel <model>     Specify the base model for Act Mode (default: user prompt or qwen2.5-coder:7b)
  -PlanModel <model>    Specify the base model for Plan Mode (default: user prompt or deepseek-r1:8b)
  -Uninstall            Completely remove the stack, containers, networks, and all local data
  -MasterKey <key>      Specify the LiteLLM Master Key
  -PostgresPassword <pw> Specify the Postgres Database Password
"@
    exit 0
}

# Load environment variables from .env
$envFile = ".env"
$envDict = @{}

if (Test-Path $envFile) {
    Write-Host "Loading environment variables from .env..." -ForegroundColor Yellow
    Get-Content $envFile | Where-Object { $_ -match '^\s*[^#]' -and $_ -match '=' } | ForEach-Object {
        $name, $value = $_ -split '=', 2
        $name = $name.Trim()
        $value = $value.Trim()
        $value = $value -replace '^"(.*)"$', '$1' -replace "^'(.*)'$", '$1'
        $envDict[$name] = $value
    }
    Write-Host "   OK: .env loaded successfully" -ForegroundColor Green
} else {
    Write-Host "Creating new .env file..." -ForegroundColor Yellow
}

$envChanged = $false

# Apply overrides from parameters
if ($MasterKey) {
    $envDict['LITELLM_MASTER_KEY'] = $MasterKey
    $envChanged = $true
}
if ($PostgresPassword) {
    $envDict['POSTGRES_PASSWORD'] = $PostgresPassword
    $envChanged = $true
}

# Auto-generate if missing
if (-not $envDict.ContainsKey('LITELLM_MASTER_KEY') -or [string]::IsNullOrWhiteSpace($envDict['LITELLM_MASTER_KEY'])) {
    $envDict['LITELLM_MASTER_KEY'] = "sk-$([guid]::NewGuid().ToString('N'))"
    $envChanged = $true
    Write-Host "   Generated new LITELLM_MASTER_KEY" -ForegroundColor Green
}
if (-not $envDict.ContainsKey('POSTGRES_PASSWORD') -or [string]::IsNullOrWhiteSpace($envDict['POSTGRES_PASSWORD'])) {
    $envDict['POSTGRES_PASSWORD'] = [guid]::NewGuid().ToString('N')
    $envChanged = $true
    Write-Host "   Generated new POSTGRES_PASSWORD" -ForegroundColor Green
}

# Save .env if changed
if ($envChanged) {
    $envLines = @()
    foreach ($key in $envDict.Keys) {
        $envLines += "$key=$($envDict[$key])"
    }
    Set-Content -Path $envFile -Value $envLines -Encoding UTF8
    Write-Host "   OK: .env file updated with secure credentials" -ForegroundColor Green
}

# Load into process environment
foreach ($key in $envDict.Keys) {
    [Environment]::SetEnvironmentVariable($key, $envDict[$key], 'Process')
}
Write-Host ""

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

function New-LiteLLMConfig {
    param(
        [string]$ActModel,
        [string]$PlanModel
    )

    $configContent = @"
model_list:
  - model_name: $($ActModel)-act
    litellm_params:
      model: ollama/$($ActModel)-act
      api_base: http://ollama:11434
      api_key: "ollama"
      max_tokens: 32768
      temperature: 0.8
      top_p: 0.95

  - model_name: $($PlanModel)-plan
    litellm_params:
      model: ollama/$($PlanModel)-plan
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
  completion_model: "$($ActModel)-act"
  use_azure_ad: false
  default_timeout: 1200
  disable_user_auth: false

ollama_settings:
  custom_llm_provider: "ollama"
  num_retries: 5
  request_timeout: 1200
  max_retries: 3
"@

    Set-Content -Path "litellm_config.yaml" -Value $configContent -Encoding UTF8
    Write-Host "   OK: litellm_config.yaml updated for selected models" -ForegroundColor Green
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

$baseAct = "qwen2.5-coder:7b"
$basePlan = "deepseek-r1:8b"

if ($SkipModelDownload) {
    Write-Host "Model download skipped via parameter." -ForegroundColor Gray
} else {
    if ($ActModel -ne "" -and $PlanModel -ne "") {
        $baseAct = $ActModel
        $basePlan = $PlanModel
        Write-Host "Using provided models: Act=$baseAct, Plan=$basePlan" -ForegroundColor Green
    } else {
        Write-Host "Select Model Configuration:" -ForegroundColor Cyan
        Write-Host "1. 10GB VRAM Optimized (qwen2.5-coder:7b + deepseek-r1:8b) - Recommended"
        Write-Host "2. High Performance (qwen2.5-coder:14b + deepseek-r1:14b) - Requires 16GB+ VRAM"
        Write-Host "3. Custom Models"
        Write-Host "4. Skip Model Download"

        $choice = Read-Host "Enter your choice (1-4) [Default: 1]"

        switch ($choice) {
            "2" {
                $baseAct = "qwen2.5-coder:14b"
                $basePlan = "deepseek-r1:14b"
                Write-Host "Selected High Performance models." -ForegroundColor Green
            }
            "3" {
                $baseAct = Read-Host "Enter Act Model (e.g., qwen2.5-coder:7b) [Default: qwen2.5-coder:7b]"
                if ([string]::IsNullOrWhiteSpace($baseAct)) { $baseAct = "qwen2.5-coder:7b" }

                $basePlan = Read-Host "Enter Plan Model (e.g., deepseek-r1:8b) [Default: deepseek-r1:8b]"
                if ([string]::IsNullOrWhiteSpace($basePlan)) { $basePlan = "deepseek-r1:8b" }

                Write-Host "Selected Custom models: Act=$baseAct, Plan=$basePlan" -ForegroundColor Green
            }
            "4" {
                $SkipModelDownload = $true
                Write-Host "Skipping model download." -ForegroundColor Yellow
            }
            default {
                $baseAct = "qwen2.5-coder:7b"
                $basePlan = "deepseek-r1:8b"
                Write-Host "Selected 10GB VRAM Optimized models." -ForegroundColor Green
            }
        }
    }
}
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

# 3. Generate LiteLLM Config
Write-Host "3. Generating LiteLLM Config..." -ForegroundColor Yellow
New-LiteLLMConfig -ActModel $baseAct -PlanModel $basePlan

# 4. Start Docker Compose
Write-Host "4. Starting Docker Compose..." -ForegroundColor Yellow
docker compose up -d
if (-not (Test-CommandSuccess $LASTEXITCODE)) {
    Write-Host "   Error: Failed to start containers" -ForegroundColor Red
    exit 1
}
Write-Host "   OK: Containers started" -ForegroundColor Green
Start-Sleep -Seconds 5

# 5. Pull Base Models and Create Custom Versions
if (-not $SkipModelDownload) {
    Write-Host "5. Pulling base models and creating custom versions..." -ForegroundColor Yellow
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

    $targetAct = "${baseAct}-act"
    $targetPlan = "${basePlan}-plan"

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

# 6. Healthcheck
Write-Host "6. Running healthchecks..." -ForegroundColor Yellow
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
Write-Host "  Model Act:  ${baseAct}-act" -ForegroundColor White
Write-Host "  Model Plan: ${basePlan}-plan" -ForegroundColor White
Write-Host ""