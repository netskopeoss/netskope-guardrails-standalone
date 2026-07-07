# CLAUDE.md

Project instructions for Claude Code working in this repository.

## Project Overview

This repo deploys **only** the Netskope **AI Guardrails** service into AWS. It
is a standalone carve-out of the
[AWS AI Gateway Reference Architecture by jharris-ns](https://github.com/jharris-ns/AWS-AIGW-Reference-Architecture)
— the AI Gateway and DLP On Demand (DLPoD) components are intentionally **not**
present. It mirrors the structure of the sibling DLPoD standalone repo.

AI Guardrails is a GPU-hosted LLM container (content moderation / prompt and
response safety) that fronts an internal Application Load Balancer with a
self-signed CA cert, so an AI Gateway (or any RFC1918 client) can call it over
HTTPS.

## Architecture

1. **ASG launches a GPU instance** from a Deep Learning AMI (NVIDIA drivers +
   Docker preinstalled).
2. **EC2 UserData self-starts the container**: fetch region from IMDSv2 →
   `aws ecr get-login-password` → `docker login` → `docker pull <ImageUri>` →
   `docker run -d --restart always --gpus all -p <port>:<port>`.
3. The instance registers with the **internal ALB target group** (HTTP on the
   container port); the ALB serves **HTTPS 443** with a self-signed cert.
4. **Route 53** private zone resolves `guardrails.aigw.internal` to the ALB.

**Key difference from DLPoD:** there are **no** ASG lifecycle hooks, SNS, Step
Functions, activation/tethering Lambdas, or paramiko layer. The container
self-starts via UserData, so the only Lambda is the inline self-signed-cert
custom resource. Deployment is a single `aws cloudformation deploy` — **no
prebuilt S3 artifacts** are required.

## Repository Layout

| Path | Purpose |
|------|---------|
| `templates/guardrails-standalone.yaml` | The CloudFormation template (the deliverable). |
| `docs/` | Operational notes (optional). |

## Deployment

The template is fully self-contained (the cert generator is inlined), so there
is no build step and no S3 upload.

```bash
aws cloudformation deploy \
  --template-file templates/guardrails-standalone.yaml \
  --stack-name netskope-guardrails \
  --capabilities CAPABILITY_NAMED_IAM \
  --region us-west-1 \
  --parameter-overrides \
    VpcId=vpc-xxxx \
    AlbSubnetIds=subnet-a,subnet-b \
    PrivateSubnetIds=subnet-c \
    GuardrailsAmiId=ami-xxxx \
    GuardrailsImageUri=<account>.dkr.ecr.us-west-1.amazonaws.com/aisecurityllm:latest
```

## Operations Quick Reference

| Task | Command |
|------|---------|
| Guardrails instance state | `aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names <stack>-guardrails-asg --query "AutoScalingGroups[0].Instances[*].[InstanceId,LifecycleState,HealthStatus]" --output table` |
| Target health (is the container serving?) | `aws elbv2 describe-target-health --target-group-arn <tg-arn> --output table` |
| Container boot log (on instance) | `sudo cat /var/log/guardrails-init.log` |
| Get ALB cert PEM | `aws ssm get-parameter --name /<stack>/guardrails-cert --query Parameter.Value --output text` |

## Rules & Gotchas

- **GPU quota / AZ availability.** g4dn / g5 instances need vCPU quota (the
  "Running On-Demand G and VT instances" limit) and capacity in the chosen
  AZs. Put `PrivateSubnetIds` in AZs that have the instance type.
- **Deep Learning AMI required.** The AMI must have NVIDIA drivers + Docker +
  the NVIDIA container toolkit so `docker run --gpus all` works. A plain
  Amazon Linux AMI will fail to start the container.
- **ALB subnets need ≥ 8 free IPs each** — `/28` subnets are too small.
- **Private subnets need outbound internet** (NAT) so the instance can reach
  ECR to pull the image.
- **`HostedZoneName` must be unique per VPC.** If an AI Gateway or DLPoD
  deployment already associated `aigw.internal` with the VPC, pick a different
  name to avoid a Route 53 resolution collision.
- The container image comes from a **Netskope-provided ECR URI** — pass it as
  `GuardrailsImageUri`.
- **Don't commit secrets.** `.env`, `*.pem`, `*.key` are git-ignored.
- The `source/` directory (if present locally) is scratch/reference only and
  is git-ignored.

## Attribution

Derived from jharris-ns/AWS-AIGW-Reference-Architecture (Apache-2.0). See
`NOTICE` and `LICENSE`.

## Related Resources

- [Netskope AI Gateway Documentation](https://docs.netskope.com/en/ai-gateway/)
- [Upstream reference architecture](https://github.com/jharris-ns/AWS-AIGW-Reference-Architecture)
