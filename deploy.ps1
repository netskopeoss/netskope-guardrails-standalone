# Deploy the Netskope AI Guardrails on Demand stack.
#
#   1) Copy .env.example to .env and fill in your AMI ID / key pair name.
#   2) Ensure AWS creds work:  aws sts get-caller-identity
#   3) Run:  ./deploy.ps1
#
# Infrastructure-only: after CREATE_COMPLETE you still activate the appliance
# manually (enroll node + attach service template in the Netskope UI, then the
# VPE CLI dataplane-cert step). See README "After deployment".

$ErrorActionPreference = 'Stop'
Set-Location -Path $PSScriptRoot

if (-not (Test-Path .env)) {
    throw "No .env found. Copy .env.example to .env and fill it in first."
}

# Load .env (KEY=VALUE; skip blanks and # comments).
Get-Content .env | ForEach-Object {
    $line = $_.Trim()
    if ($line -and -not $line.StartsWith('#') -and $line.Contains('=')) {
        $k, $v = $line.Split('=', 2)
        Set-Item -Path "env:$($k.Trim())" -Value $v.Trim()
    }
}

# Corp TLS-inspection proxy CA bundle, if set in .env (keeps the path out of git).
if ($env:CA_BUNDLE) { $env:AWS_CA_BUNDLE = $env:CA_BUNDLE }

$region = if ($env:AWS_REGION) { $env:AWS_REGION } else { 'us-east-1' }
$stack  = if ($env:STACK_NAME) { $env:STACK_NAME } else { 'netskope-guardrails' }

foreach ($req in 'GUARDRAILS_AMI_ID','GUARDRAILS_KEY_NAME') {
    if (-not (Get-Item "env:$req" -ErrorAction SilentlyContinue).Value) {
        throw "Missing required value '$req' in .env"
    }
}

$overrides = @(
    "GuardrailsAmiId=$env:GUARDRAILS_AMI_ID",
    "GuardrailsKeyName=$env:GUARDRAILS_KEY_NAME"
)
if ($env:VPC_CIDR)               { $overrides += "VpcCidr=$env:VPC_CIDR" }
if ($env:ADDITIONAL_CLIENT_CIDR) { $overrides += "AdditionalClientCidr=$env:ADDITIONAL_CLIENT_CIDR" }
if ($env:GUARDRAILS_INSTANCE_TYPE) { $overrides += "GuardrailsInstanceType=$env:GUARDRAILS_INSTANCE_TYPE" }
if ($env:HOSTED_ZONE_NAME)         { $overrides += "HostedZoneName=$env:HOSTED_ZONE_NAME" }
if ($env:GUARDRAILS_DOMAIN_NAME)   { $overrides += "GuardrailsDomainName=$env:GUARDRAILS_DOMAIN_NAME" }

Write-Host "Deploying stack '$stack' to $region ..."
aws cloudformation deploy `
  --template-file templates/guardrails-standalone.yaml `
  --stack-name $stack `
  --capabilities CAPABILITY_NAMED_IAM `
  --region $region `
  --parameter-overrides $overrides

Write-Host ""
Write-Host "Done. Stack outputs:"
aws cloudformation describe-stacks --stack-name $stack --region $region `
  --query "Stacks[0].Outputs" --output table
