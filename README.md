# Netskope AI Guardrails — Standalone AWS Deployment

Deploy **only** the Netskope **AI Guardrails** service into AWS — no AI
Gateway, no DLPoD.

This is a standalone carve-out of the
[AWS AI Gateway Reference Architecture by **jharris-ns**](https://github.com/jharris-ns/AWS-AIGW-Reference-Architecture).
That project deploys AI Gateway, AI Guardrails, **and** DLPoD together; this
repo extracts the AI Guardrails slice into a self-contained CloudFormation
stack for teams that just want the GPU-hosted guardrails LLM.

> **Attribution:** the AI Guardrails resources and the inline self-signed
> certificate generator are derived from jharris-ns's project, used under the
> Apache License 2.0. See [`NOTICE`](NOTICE) and [`LICENSE`](LICENSE).

---

## What gets deployed

A GPU instance running the AI Guardrails container, fronted by a private ALB,
that starts itself on boot with zero manual steps.

```
                         ┌─────────────────────────────────────────┐
                         │                  VPC                     │
   client / AI Gateway   │                                          │
   ───────────────────►  │   Route53 (guardrails.aigw.internal)     │
   https://guardrails...  │            │                            │
                         │            ▼                            │
                         │   Internal ALB (HTTPS 443) ── self-signed CA cert
                         │            │                            │
                         │            ▼  (HTTP :container-port)     │
                         │   Guardrails GPU instance (ASG)          │
                         │            │  UserData: ECR login →       │
                         │            │  docker pull → docker run    │
                         │            ▼  --gpus all                 │
                         │        ECR (image pull, via NAT) ───────►│
                         └─────────────────────────────────────────┘
```

**Resources created:**

- Guardrails GPU appliance — EC2 Launch Template + Auto Scaling Group
  (Deep Learning AMI, 100 GB encrypted gp3, IMDSv2 required). The container
  self-starts via UserData (ECR login → `docker pull` → `docker run --gpus all`).
- Internal Application Load Balancer + Target Group (HTTP to the container
  port) + HTTPS 443 listener.
- A self-signed **CA certificate**, generated inline (Lambda custom resource),
  imported to ACM and stored in SSM Parameter Store.
- Route 53 private hosted zone resolving `guardrails.aigw.internal` to the ALB.
- IAM role + instance profile (ECR auth/pull + CloudWatch Logs) and two
  security groups.

**No prebuilt artifacts, no build step** — the only Lambda (the cert
generator) is inlined in the template, so deployment is a single
`aws cloudformation deploy`.

---

## Prerequisites

| Requirement | Notes |
|-------------|-------|
| **Guardrails ECR image URI** | Netskope-provided container image in ECR, e.g. `<account>.dkr.ecr.<region>.amazonaws.com/aisecurityllm:latest`. |
| **Deep Learning AMI ID** | AMI with NVIDIA drivers + Docker + NVIDIA container toolkit (e.g. AWS "Deep Learning Base OSS Nvidia Driver GPU AMI"). |
| **GPU quota** | vCPU quota for G instances (*Running On-Demand G and VT instances*) and capacity in the target AZs. |
| **Existing VPC** | With private subnets that have **outbound internet (NAT)** for the ECR pull. |
| **2 ALB subnets** | Different AZs, each with **≥ 8 free IPs** (`/24`+ recommended; `/28` is too small). |
| **AWS CLI** | Configured for the target account/region. |

---

## Quick start

```bash
aws cloudformation deploy \
  --template-file templates/guardrails-standalone.yaml \
  --stack-name netskope-guardrails \
  --capabilities CAPABILITY_NAMED_IAM \
  --region us-west-1 \
  --parameter-overrides \
    VpcId=vpc-xxxxxxxx \
    AlbSubnetIds=subnet-aaaa,subnet-bbbb \
    PrivateSubnetIds=subnet-cccc \
    GuardrailsAmiId=ami-xxxxxxxx \
    GuardrailsImageUri=<account>.dkr.ecr.us-west-1.amazonaws.com/aisecurityllm:latest
```

---

## Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `VpcId` | ✅ | — | Existing VPC. |
| `AlbSubnetIds` | ✅ | — | Two subnets (different AZs) for the internal ALB. |
| `PrivateSubnetIds` | ✅ | — | Private subnet(s) with NAT for the GPU instance. |
| `GuardrailsAmiId` | ✅ | — | Deep Learning AMI (NVIDIA drivers + Docker). |
| `GuardrailsImageUri` | ✅ | — | ECR image URI for the guardrails container. |
| `GuardrailsInstanceType` | | `g4dn.xlarge` | `g4dn` / `g5`, xlarge–2xlarge. |
| `GuardrailsContainerPort` | | `8080` | Port the container listens on. |
| `GuardrailsHealthCheckPath` | | `/` | ALB health check path. |
| `HostedZoneName` | | `aigw.internal` | Route 53 private zone name (unique per VPC). |
| `GuardrailsDomainName` | | `guardrails.aigw.internal` | Internal FQDN; matches the cert CN/SAN. |
| `GuardrailsMinCapacity` | | `1` | Min GPU instances. |
| `GuardrailsDesiredCapacity` | | `1` | Desired GPU instances (usually 1). |
| `GuardrailsMaxCapacity` | | `2` | Max GPU instances (manual scale-out). |

---

## After deployment

**Watch the instance come healthy** (the container pull/start takes a few
minutes on first boot):

```bash
# Instance lifecycle + health
aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names netskope-guardrails-guardrails-asg \
  --query "AutoScalingGroups[0].Instances[*].[InstanceId,LifecycleState,HealthStatus]" \
  --output table

# ALB target health — Healthy means the container is serving
aws elbv2 describe-target-health \
  --target-group-arn "$(aws elbv2 describe-target-groups \
    --names netskope-guardrails-guardrails-tg \
    --query 'TargetGroups[0].TargetGroupArn' --output text)" \
  --output table
```

If a target stays unhealthy, SSH/SSM onto the instance and check
`sudo cat /var/log/guardrails-init.log` for the ECR/docker output.

**Point clients at the service.** Use the `GuardrailsHostUrl` output
(`https://guardrails.aigw.internal`). Any client that must trust the ALB
endpoint needs the self-signed CA cert from SSM:

```bash
aws ssm get-parameter --name /netskope-guardrails/guardrails-cert \
  --query Parameter.Value --output text
```

### Stack outputs

| Output | Description |
|--------|-------------|
| `GuardrailsHostUrl` | `https://guardrails.aigw.internal` — the guardrails host URL for clients. |
| `GuardrailsAlbDnsName` | Internal ALB DNS name. |
| `GuardrailsCertificateArn` | ACM ARN of the self-signed cert. |
| `CertParameterName` | SSM param holding the cert PEM. |
| `GuardrailsAsgName` | Guardrails Auto Scaling Group name. |
| `PrivateHostedZoneId` | Route 53 private zone ID. |

---

## Teardown

```bash
aws cloudformation delete-stack --stack-name netskope-guardrails
```

This terminates the GPU instance, removes the ALB, Route 53 zone, cert
Lambda, roles, and the imported ACM certificate.

---

## Repository layout

```
templates/guardrails-standalone.yaml   CloudFormation template (the deliverable)
docs/                                   Operational notes (optional)
CLAUDE.md                               Guidance for Claude Code in this repo
NOTICE / LICENSE                        Apache-2.0 + attribution to jharris-ns
```

---

## Notes & gotchas

- **Deep Learning AMI required** — the AMI must ship NVIDIA drivers, Docker,
  and the NVIDIA container toolkit, or `docker run --gpus all` fails.
- **GPU quota & AZ capacity** — request G-instance vCPU quota ahead of time
  and place `PrivateSubnetIds` in AZs with capacity for the chosen type.
- **Private subnets need outbound internet (NAT)** so the instance can pull
  from ECR.
- **`HostedZoneName` is unique per VPC** — if `aigw.internal` is already
  associated with the VPC (AI Gateway / DLPoD), pick a different name.
- First-boot health can take several minutes while the image is pulled; the
  ASG uses a 600s health-check grace period.

## License

Apache License 2.0 — see [`LICENSE`](LICENSE) and [`NOTICE`](NOTICE).
Derived from [jharris-ns/AWS-AIGW-Reference-Architecture](https://github.com/jharris-ns/AWS-AIGW-Reference-Architecture).
