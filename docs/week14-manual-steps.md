# Week 14 official runs: the steps only you can do

Claude does everything on the servers. It deploys the frozen stack over SSM, runs
the live check and all 66 official runs, extracts each run, and copies the data
back. You do the AWS account steps below, because Claude never runs
`terraform apply` or `destroy`.

## How long it takes

| Part | Time |
| --- | --- |
| Your steps 1 to 6 | about 15 minutes |
| Deploy, live check, warm-up | about 40 minutes |
| 66 official runs (22 cells x 3 repeats) | about 5 to 6.5 hours |
| Copy the data back | about 30 to 45 minutes |
| **Total, servers running** | **about 7 to 8 hours** |

The estimate comes from the Week 13 runs on the same hosts: 2.5 to 4 minutes per
run at 50 and 100/s, and up to 8 minutes when a run drains for several minutes.

**Start in the morning** so step 8 happens the same day. The servers cost credits
from step 6 until step 8. Step 6 gives them 12 hours before they switch
themselves off, which covers the session with room to spare. The safety timer is
only a safety net, though: always do step 8.

You do not need to watch. Stay reachable in case Claude reports a failed run (the
matrix stops at the first run that fails validation, and Claude asks you before
deciding anything about it).

Run every command in **PowerShell on your PC**. The background is in
[deployment.md](deployment.md), sections 0a, 3, 8 and 11.

## What runs

The frozen matrix from [week14-freeze.md](week14-freeze.md), at commit
`9d00bea` (already pushed, together with the re-sign record):

- C1, C2 and C3 at 50, 100 and 200/s; C3 also at 400/s;
- C4 with 1, 2 and 4 Inventory consumers at 50, 100, 200 and 400/s;
- 60 s of open-loop load per run, 3 repeats, one hot product with 100,000 units;
- a full reset, seed and warm-up before every run, and the validator after it.

Repeat 1 of every cell runs first, then repeat 2, then repeat 3, so a slow drift
in the hosts spreads across all cells instead of landing on one.

## Step 1. Open a terminal in the Terraform folder

```powershell
cd D:\DACNTT\infra\terraform
```

## Step 2. Check the settings file

Skip this if `terraform.tfvars` already exists. It is git-ignored and holds no
secrets.

```powershell
if (-not (Test-Path terraform.tfvars)) { Copy-Item terraform.tfvars.example terraform.tfvars }
```

## Step 3. Log in to AWS

```powershell
aws login --profile flashsale-deploy
```

A browser window opens. Sign in there, then check it worked:

```powershell
aws sts get-caller-identity --profile flashsale-deploy
```

**You should see** your account number, `706421610937`. The login lasts about
12 hours. If a later step says the session expired, run this step again.

## Step 4. Check the instance profile is still there

```powershell
aws iam get-instance-profile --instance-profile-name flashsale-ec2-ssm --profile flashsale-deploy
```

**You should see** a block of JSON naming `flashsale-ec2-ssm`. If you see
`NoSuchEntity`, stop and tell Claude.

## Step 5. Create the servers

The 720 keeps the servers alive for up to 12 hours.

```powershell
$env:AWS_PROFILE = "flashsale-deploy-tf"
terraform init
terraform apply "-var-file=terraform.tfvars" "-var=auto_terminate_minutes=720"
```

Keep the quotes: without them Windows PowerShell 5.1 splits
`-var-file=terraform.tfvars` at the dot and Terraform stops with "Too many command
line arguments".

Read the plan. **It should say** `4 to add, 0 to change, 0 to destroy`. If it does,
type `yes`. If it shows anything else, type `no` and tell Claude.

## Step 6. Send Claude the server details

```powershell
terraform output
```

Paste the whole output to Claude. It holds instance ids and private addresses,
not secrets. Claude takes over from here and reports the live check, then
progress every few hours and when the runs finish.

## Step 7. Wait for "evidence copied back"

Claude copies every run's manifest, raw JTL, collector samples, validator output,
extraction summary and database dump to this PC and checks the copies before it
tells you to destroy. Do not destroy before that message: anything still on the
servers is lost.

## Step 8. Destroy the servers

```powershell
cd D:\DACNTT\infra\terraform
$env:AWS_PROFILE = "flashsale-deploy-tf"
terraform destroy "-var-file=terraform.tfvars"
```

Type `yes`. **It should end with** `Destroy complete! Resources: 4 destroyed.`
If the login expired, do step 3 first.

## Step 9. Check nothing is left

```powershell
aws ec2 describe-instances --filters "Name=tag:Project,Values=flash-sale" "Name=instance-state-name,Values=pending,running,stopping,stopped" --query "Reservations[].Instances[].InstanceId" --profile flashsale-deploy
aws ec2 describe-security-groups --filters "Name=tag:Project,Values=flash-sale" --query "SecurityGroups[].GroupId" --profile flashsale-deploy
aws ec2 describe-volumes --filters "Name=tag:Project,Values=flash-sale" --query "Volumes[].VolumeId" --profile flashsale-deploy
```

**Each command should print** `[]`. Paste the output to Claude.

## If something goes wrong

- Stop at the failing step and paste the error to Claude.
- If a run fails validation, the matrix stops. Claude tells you which run and
  why, and asks before it reruns anything. A failed run is kept as data, never
  deleted.
- If a step fails after step 5, the servers are still costing credits, so tell
  Claude soon. Step 8 is safe at any time once you accept losing what is on them.
- Never paste passwords, access keys or the contents of `infra/ec2.env`.
