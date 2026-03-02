# PowerShell script for deploying Ollama + LiteLLM stack

param(
    [switch]$Help,
    [switch]$SkipDockerCheck,
    [switch]$SkipModelDownload,
    [string]$Model = "deepseek-ai/DeepSeek-R1-Distill-Qwen-7B",
    [switch]$DownloadAllModels
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
  -Model <model_name>   Specify model to download (default: deepseek-ai/DeepSeek-R1-Distill-Qwen-7B)
  -DownloadAllModels    Download all models for Plan/Act architecture (qwen2.5-coder:7b and deepseek-ai/DeepSeek-R1-Distill-Qwen-7B)
"@
    exit 0
}

Write-Host "=== Ollama + LiteLLM Deployment ===" -ForegroundColor Cyan
Write-Host ""

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
$directories = @("ollama_data")
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
    if ($DownloadAllModels) {
        Write-Host "4. Downloading all models for Plan/Act architecture..." -ForegroundColor Yellow
        Write-Host "   Waiting for Ollama to start (30 seconds)..." -ForegroundColor Yellow
        Start-Sleep -Seconds 30
        
        $models = @("qwen2.5-coder:7b", "deepseek-ai/DeepSeek-R1-Distill-Qwen-7B")
        
        foreach ($modelToDownload in $models) {
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
    else {
        Write-Host "4. Downloading model $Model..." -ForegroundColor Yellow
        Write-Host "   Waiting for Ollama to start (30 seconds)..." -ForegroundColor Yellow
        Start-Sleep -Seconds 30
        
        try {
            Write-Host "   Pulling model..." -ForegroundColor Yellow
            docker exec ollama ollama pull $Model
            
            if (Test-CommandSuccess $LASTEXITCODE) {
                Write-Host "   OK: Model $Model downloaded successfully" -ForegroundColor Green
                docker exec ollama ollama list
            }
            else {
                Write-Host "   Error downloading model" -ForegroundColor Red
            }
        }
        catch {
            Write-Host "   Error: $_" -ForegroundColor Red
        }
    }
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
    $litellmCheck = Invoke-RestMethod -Uri "http://localhost:$litellmPort/health" -ErrorAction Stop
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
Write-Host "    - qwen2.5-coder:7b (Act mode)" -ForegroundColor White
Write-Host "    - deepseek-ai/DeepSeek-R1-Distill-Qwen-7B (Plan mode)" -ForegroundColor White
Write-Host ""
Write-Host "Usage for Plan/Act architecture:" -ForegroundColor Yellow
Write-Host "  Plan mode (analysis): Use deepseek-ai/DeepSeek-R1-Distill-Qwen-7B" -ForegroundColor White
Write-Host "  Act mode (execution): Use qwen2.5-coder:7b" -ForegroundColor White
Write-Host ""