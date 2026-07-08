# Netskope AI Guardrails on Demand — Standalone AWS Deployment

Deploy **only** the Netskope **AI Guardrails on Demand** appliance into AWS —
no AI Gateway, no DLPoD.

AI Guardrails on Demand ships as a **Netskope Virtual Private Edge (VPE)**
appliance VM. This repo is a standalone carve-out of the
[AWS AI Gateway Reference Architecture by **jharris-ns**](https://github.com/jharris-ns/AWS-AIGW-Reference-Architecture),
extracting just the Guardrails slice into a self-contained CloudFormation stack.

> **Attribution:** the ALB/DNS/cert pattern and the inline self-signed
> certificate generator are derived from jharris-ns's project, used under the
> Apache License 2.0. See [`NOTICE`](NOTICE) and [`LICENSE`](LICENSE).

> ⚠️ **Beta / infrastructure-only.** Netskope AI Guardrails on Demand is a Beta
> feature. This template stands up the **AWS infrastructure**; **tenant-side
> activation is manual** (see [After deployment](#after-deployment)). Contact
> Netskope Support / your SE to enable the feature and get the appliance AMI.

---

## What gets deployed

The VPE appliance in a single-instance ASG, fronted by a private ALB that
serves HTTPS 443 and forwards to the appliance's AI Guardrails on Demand API
on HTTP `:8080`.

```
                         ┌─────────────────────────────────────────┐
                         │                  VPC                     │
   client / AI Gateway   │                                          │
   ───────────────────►  │   Route53 (guardrails.aigw.internal)     │
   https://guardrails...  │            │                            │
                         │            ▼                            │
                         │   Internal ALB (HTTPS 443) ── self-signed CA cert
                         │            │  forward → HTTP :8080        │
                         │            ▼                            │
                         │   AI Guardrails on Demand (VPE)          │
                         │   appliance — ASG, 1 instance ──────────►│ Netskope
                         │            ▲                            │  mgmt plane
                         │            │ SSH (manual VPE CLI)        │  (via NAT)
                         │        operator / bastion               │
                         └─────────────────────────────────────────┘

   (optional) GPU LLM detection backend = a SEPARATE VM the VPE connects to
   via the service template — NOT deployed by this stack.
```

**Resources created:**

- VPE appliance — EC2 Launch Template + Auto Scaling Group (Netskope VPE AMI,
  general-purpose CPU instance, 300 GB encrypted gp3, IMDSv2 required).
- Internal Application Load Balancer + Target Group (HTTP to the appliance API
  port) + HTTPS 443 listener.
- A self-signed **CA certificate**, generated inline (Lambda custom resource),
  imported to ACM and stored in SSM Parameter Store.
- Route 53 private hosted zone resolving `guardrails.aigw.internal` to the ALB.
- Two security groups (ALB; appliance — API from ALB + SSH from RFC1918 for the
  CLI activation step).

**No prebuilt artifacts, no build step, no GPU, no ECR** — the only Lambda (the
cert generator) is inlined, so deployment is a single `aws cloudformation deploy`.

---

## Prerequisites

| Requirement | Notes |
|-------------|-------|
| **VPE appliance AMI** | Netskope-shared "Virtual Private Edge (VPE)" AMI for AI Guardrails on Demand. The share is in **us-east-1**; deploy there, or copy the AMI to your region (needs Netskope to also share the backing snapshot). |
| **Netskope tenant w/ Guardrails on Demand** | Beta feature — have Netskope enable it for your tenant. |
| **Existing VPC** | Private subnets with **outbound internet (NAT)** so the appliance reaches the Netskope management plane. |
| **2 ALB subnets** | Different AZs, each with **≥ 8 free IPs** (`/24`+ recommended; `/28` is too small). |
| **In-VPC CLI access** | A bastion / SSM path to SSH the appliance for the one-time dataplane-cert CLI step. |
| **AWS CLI** | Configured for the target account/region. |

---

## Quick start

Deploy in **us-east-1** (where the AMI is shared):

```bash
aws cloudformation deploy \
  --template-file templates/guardrails-standalone.yaml \
  --stack-name netskope-guardrails \
  --capabilities CAPABILITY_NAMED_IAM \
  --region us-east-1 \
  --parameter-overrides \
    VpcId=vpc-xxxxxxxx \
    AlbSubnetIds=subnet-aaaa,subnet-bbbb \
    PrivateSubnetIds=subnet-cccc \
    GuardrailsAmiId=ami-0685e188113ed2f85
```

---

## Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `VpcId` | ✅ | — | Existing VPC. |
| `AlbSubnetIds` | ✅ | — | Two subnets (different AZs) for the internal ALB. |
| `PrivateSubnetIds` | ✅ | — | Private subnet(s) with NAT for the appliance. |
| `GuardrailsAmiId` | ✅ | — | Netskope VPE appliance AMI ID. |
| `GuardrailsInstanceType` | | `m5.2xlarge` | CPU general-purpose, ≥ 8 vCPU / 32 GiB (`m5`/`m6i` 2xl–4xl). **No GPU** — GPU detection is a separate VM. |
| `GuardrailsApiPort` | | `8080` | Appliance API port (ALB target). |
| `GuardrailsHealthCheckPath` | | `/` | ALB health check path. |
| `HostedZoneName` | | `aigw.internal` | Route 53 private zone name (unique per VPC). |
| `GuardrailsDomainName` | | `guardrails.aigw.internal` | Internal FQDN; matches the cert CN/SAN. |
| `GuardrailsMinCapacity` | | `1` | Min appliance instances. |
| `GuardrailsDesiredCapacity` | | `1` | Desired instances (usually 1). |
| `GuardrailsMaxCapacity` | | `2` | Max instances (manual scale-out). |

---

## After deployment

The stack gives you a booted, network-reachable VPE appliance behind the ALB.
**Activation is manual** (Netskope Beta — automation is incomplete):

1. **Confirm the instance is up.**
   ```bash
   aws autoscaling describe-auto-scaling-groups \
     --auto-scaling-group-names netskope-guardrails-guardrails-asg \
     --query "AutoScalingGroups[0].Instances[*].[InstanceId,LifecycleState,HealthStatus]" \
     --region us-east-1 --output table
   ```
   > The ASG uses an **EC2** health check (not ELB), so the appliance is *not*
   > killed while its API health check is still failing pre-activation.

2. **Enroll the VPE node** and **attach templates** in the Netskope UI:
   *Settings → Security Cloud Platform → On-Premises Infrastructure* — attach a
   **platform template** and the **AI Guardrails** service template to the node.

3. **Generate the dataplane certificate from the VPE CLI** (SSH to the
   appliance from within the VPC):
   ```
   request certificate generate forward-proxy self-signed \
     common-name <mycert> email-address <admin-email>
   ```

4. **(Optional) Connect a GPU LLM backend** in the service template (Container
   URL/IP + OAuth2) if you want LLM-based detection. That backend is a separate
   VM — not part of this stack.

5. **Point clients at the service** using the `GuardrailsHostUrl` output
   (`https://guardrails.aigw.internal`). Clients that must trust the ALB need
   the self-signed CA cert from SSM:
   ```bash
   aws ssm get-parameter --name /netskope-guardrails/guardrails-cert \
     --query Parameter.Value --region us-east-1 --output text
   ```

### Stack outputs

| Output | Description |
|--------|-------------|
| `GuardrailsHostUrl` | `https://guardrails.aigw.internal` — client host URL (post-activation). |
| `GuardrailsAlbDnsName` | Internal ALB DNS name. |
| `GuardrailsCertificateArn` | ACM ARN of the self-signed cert. |
| `CertParameterName` | SSM param holding the cert PEM. |
| `GuardrailsAsgName` | Guardrails Auto Scaling Group name. |
| `PrivateHostedZoneId` | Route 53 private zone ID. |

---

## Teardown

```bash
aws cloudformation delete-stack --stack-name netskope-guardrails --region us-east-1
```

This terminates the appliance, removes the ALB, Route 53 zone, cert Lambda,
role, and the imported ACM certificate. De-enroll the node in the Netskope UI
separately.

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

- **It's a VPE appliance, not a container.** The AI Guardrails on Demand image
  is a Netskope Virtual Private Edge VM. There is no ECR pull and no GPU on this
  instance — GPU-based LLM detection runs on a *separate* VM the VPE connects to
  via the service template.
- **CPU sizing.** Netskope virtual appliances want ≥ 8 vCPU / 32 GiB; the
  default `m5.2xlarge` meets the minimum.
- **AMI region.** The AMI is shared in **us-east-1**. Cross-region copy also
  needs Netskope to share the backing EBS snapshot (and any KMS key), so the
  simplest path is to deploy in us-east-1.
- **Private subnets need outbound internet (NAT)** so the appliance can reach
  the Netskope management plane.
- **`HostedZoneName` is unique per VPC** — if `aigw.internal` is already
  associated with the VPC (AI Gateway / DLPoD), pick a different name.
- **Activation is manual (Beta).** The template does not enroll the node or
  generate the dataplane cert; do those via the Netskope UI + VPE CLI.

## License

Apache License 2.0 — see [`LICENSE`](LICENSE) and [`NOTICE`](NOTICE).
Derived from [jharris-ns/AWS-AIGW-Reference-Architecture](https://github.com/jharris-ns/AWS-AIGW-Reference-Architecture).
