# CLAUDE.md

Project instructions for Claude Code working in this repository.

## Project Overview

This repo deploys **only** the Netskope **AI Guardrails on Demand** service
into AWS. It is a standalone carve-out of the
[AWS AI Gateway Reference Architecture by jharris-ns](https://github.com/jharris-ns/AWS-AIGW-Reference-Architecture)
— the AI Gateway and DLP On Demand (DLPoD) components are intentionally **not**
present. It mirrors the structure of the sibling DLPoD standalone repo.

**AI Guardrails on Demand ships as a Netskope Virtual Private Edge (VPE)
appliance VM** (AMI name: `Virtual Private Edge (VPE) - x.y.z`). It is *not* a
GPU container. The appliance exposes the AI Guardrails on Demand API on HTTP
`:8080` (explicit-proxy mode). GPU-based LLM detection is **optional** and runs
on a **separate** VM the VPE connects to via the service template (Container
URL/IP + OAuth2) — that GPU backend is out of scope for this template.

## Architecture

0. **The stack creates its own VPC** (IGW, 2 public + 2 private /24 subnets,
   one NAT gateway, route tables, S3 gateway endpoint) — mirrors the
   AI Gateway reference architecture. No existing network is required.
1. **ASG launches the VPE appliance** from the Netskope-shared VPE AMI on a
   general-purpose CPU instance (≥ 8 vCPU / 32 GiB).
2. The appliance boots and reaches the **Netskope management plane** outbound
   (via NAT) to be managed.
3. An **internal ALB** serves **HTTPS 443** (self-signed cert) and forwards to
   the appliance API on **HTTP :8080**; **Route 53** resolves
   `guardrails.aigw.internal` to the ALB.
4. **Activation is manual** (Netskope Beta): enroll the node + attach the
   platform and AI Guardrails service templates in the Netskope UI (*Settings →
   Security Cloud Platform → On-Premises Infrastructure*), then generate the
   dataplane cert from the VPE CLI
   (`request certificate generate forward-proxy self-signed …`).

**Key differences from DLPoD:** the container/GPU model was wrong for this
image — corrected to a VPE appliance. There are **no** lifecycle hooks, SNS,
Step Functions, tethering/activation Lambdas, paramiko layer, ECR pull, GPU,
or UserData bootstrap. The only Lambda is the inline self-signed-cert custom
resource, so deployment is a single `aws cloudformation deploy` — **no S3
artifacts**. Activation is done by hand rather than automated (unlike DLPoD),
because VPE enrollment is undocumented/Beta. The ASG uses an **EC2** health
check (not ELB) so an un-activated appliance isn't replaced in a loop.

## Repository Layout

| Path | Purpose |
|------|---------|
| `templates/guardrails-standalone.yaml` | The CloudFormation template (the deliverable). |
| `docs/` | Operational notes (optional). |

## Deployment

The template is fully self-contained (cert generator inlined), so there is no
build step and no S3 upload. Deploy in the AMI's region (**us-east-1** for the
current share):

```bash
aws cloudformation deploy \
  --template-file templates/guardrails-standalone.yaml \
  --stack-name netskope-guardrails \
  --capabilities CAPABILITY_NAMED_IAM \
  --region us-east-1 \
  --parameter-overrides \
    GuardrailsAmiId=ami-0685e188113ed2f85 \
    GuardrailsKeyName=my-key-pair
```

## Operations Quick Reference

| Task | Command |
|------|---------|
| Appliance instance state | `aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names <stack>-guardrails-asg --query "AutoScalingGroups[0].Instances[*].[InstanceId,LifecycleState,HealthStatus]" --output table` |
| ALB target health | `aws elbv2 describe-target-health --target-group-arn <tg-arn> --output table` |
| Get ALB cert PEM | `aws ssm get-parameter --name /<stack>/guardrails-cert --query Parameter.Value --output text` |

## Rules & Gotchas

- **VPE appliance, not a container.** No ECR, no GPU, no `docker run` on this
  instance. If you find yourself adding a Deep Learning AMI, `GuardrailsImageUri`,
  or GPU instance types, stop — that was the wrong (earlier) model.
- **CPU sizing:** ≥ 8 vCPU / 32 GiB (default `m5.2xlarge`).
- **AMI is shared in us-east-1.** Cross-region copy needs Netskope to also
  share the backing snapshot (and KMS key if encrypted); otherwise deploy in
  us-east-1.
- **`VpcCidr` must be /16–/22** — four /24 subnets are carved from it with
  `Fn::Cidr`. Don't overlap networks you'll peer/connect.
- **ALB + appliance are in the private subnets**; one NAT gateway (first AZ)
  provides the outbound path to the management plane. Keep the
  `DependsOn: PrivateRoute` on the ASG.
- **No bastion/SSM in the VPC.** SG ingress (443, SSH) is limited to `VpcCidr`
  plus optional `AdditionalClientCidr` (peering/VPN/TGW).
- **`HostedZoneName`** — avoid collision with an AI Gateway / DLPoD
  `aigw.internal` zone if you later share DNS across VPCs.
- **Activation is manual (Beta)** — the template does not enroll the node or
  generate the dataplane cert.
- **ASG health check is EC2, not ELB** — deliberate, so the un-activated
  appliance (failing the API health check) isn't terminated/replaced.
- **Don't commit secrets.** `.env`, `*.pem`, `*.key` are git-ignored.

## Attribution

Derived from jharris-ns/AWS-AIGW-Reference-Architecture (Apache-2.0). See
`NOTICE` and `LICENSE`.

## Related Resources

- [AI Guardrails on Demand](https://docs.netskope.com/en/ai-guardrails-on-demand)
- [Configuring Virtual Private Edge](https://docs.netskope.com/en/configuring-virtual-private-edge)
- [Netskope AI Gateway Documentation](https://docs.netskope.com/en/ai-gateway/)
- [Upstream reference architecture](https://github.com/jharris-ns/AWS-AIGW-Reference-Architecture)
