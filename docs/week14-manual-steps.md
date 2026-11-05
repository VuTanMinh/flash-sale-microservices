# Week 14 official runs: the steps that need you

66 official runs on the frozen code (`9d00bea`; GitHub at `a37f082`):

- C1, C2 and C3 at 50, 100 and 200/s: 27 runs
- C3 at 400/s: 3 runs
- C4 with 1, 2 and 4 replicas at 50, 100, 200 and 400/s: 36 runs
- Every point repeated 3 times, so 66 in total.

**How long:** about 8 to 10 hours from apply to destroy (setup and live check
about 45 minutes, runs 6 to 8 hours, copy-back after each third of the runs).
**Cost:** about $2.50 to $3 of credits.

**Why one long session:** every configuration runs on the same physical machine,
so the C1 to C4 comparison is fair. A second apply can land on a different host
or AMI.

The steps are the same as the EC2 confirmation
([week13-manual-steps.md](week13-manual-steps.md)), with two changes: the
servers switch off after 12 hours (720 minutes), and one extra step keeps the PC
awake. Check each "You should see" line, and stop and paste Claude anything that
differs. The run plan is [week14-official-runs.md](week14-official-runs.md).

## Before the session

### Step 1. Pick a time

Pick a time when the PC can stay on for about 10 hours. Keep your phone near: a
permission prompt pauses the runs while the servers keep costing money.

### Step 2. Check the AWS credits (required)

Open <https://us-east-1.console.aws.amazon.com/billing/home#/credits>.

**You should see** Amount remaining of at least $5. If it is less, stop and tell
Claude: running out on the Free plan can close the account.

## On the session day (one PowerShell window, kept open)

### Step 3. Keep the PC awake while plugged in

```powershell
powercfg /change standby-timeout-ac 0
powercfg /change hibernate-timeout-ac 0
```

**You should see** no output. Step 11 restores the settings.

### Step 4. Open the Terraform folder

```powershell
cd D:\DACNTT\infra\terraform
$tf = "E:\terraform_1.16.6_windows_amd64\terraform.exe"
$aws = "C:\Users\Lenovo\AppData\Local\Programs\Amazon\AWSCLIV2\aws.exe"
& $tf version
```

**You should see** `Terraform v1.16.6`.

### Step 5. Log in to AWS

```powershell
& $aws login --profile flashsale-deploy
```

Sign in in the browser, then:

```powershell
& $aws sts get-caller-identity --profile flashsale-deploy
```

**You should see** JSON with `"Account"` and `"Arn"`.

### Step 6. Check that no servers are running

```powershell
& $aws ec2 describe-instances --region ap-southeast-2 --profile flashsale-plan --filters Name=instance-state-name,Values=pending,running,stopping,stopped --query "Reservations[].Instances[].InstanceId"
```

**You should see** `[]`. Otherwise stop and tell Claude.

### Step 7. Create the servers

```powershell
$env:AWS_PROFILE = "flashsale-deploy-tf"
& $tf init
& $tf apply "-var-file=terraform.tfvars" "-var=auto_terminate_minutes=720"
```

Keep the quotes: without them Windows PowerShell 5.1 splits
`-var-file=terraform.tfvars` at the dot.

**You should see** `Plan: 4 to add, 0 to change, 0 to destroy.` Only then type
`yes`; otherwise type `no` and tell Claude. If it fails with
`InsufficientInstanceCapacity`, run the apply again with
`"-var=availability_zone=ap-southeast-2b"` added.

### Step 8. Send Claude the server details

```powershell
& $tf output
```

Paste it all into the thread with the word **"applied"**. From here Claude
deploys, runs the live check and the 66 runs over SSM, and copies the results
back. Keep the PC on and the window open.

### Step 9. Destroy the servers

Only after Claude says the evidence is copied back:

```powershell
$env:AWS_PROFILE = "flashsale-deploy-tf"
& $tf destroy "-var-file=terraform.tfvars"
```

**You should see** `Plan: 0 to add, 0 to change, 4 to destroy.` Type `yes`, then
expect `Destroy complete! Resources: 4 destroyed.` Tell Claude **"destroyed"**.
The login lasts about 12 hours. If it has expired, redo step 5, then this step.

### Step 10. Check nothing is left

```powershell
& $aws ec2 describe-instances --region ap-southeast-2 --profile flashsale-plan --filters Name=instance-state-name,Values=pending,running,stopping,stopped --query "Reservations[].Instances[].InstanceId"
& $aws ec2 describe-volumes --region ap-southeast-2 --profile flashsale-plan --query "Volumes[].VolumeId"
& $aws ec2 describe-addresses --region ap-southeast-2 --profile flashsale-plan --query "Addresses[].PublicIp"
```

**You should see** `[]` three times. If not, paste it to Claude and do not delete
anything by hand.

### Step 11. Restore sleep

```powershell
powercfg /change standby-timeout-ac 30
powercfg /change hibernate-timeout-ac 180
```

These are the Windows defaults; use your own earlier values if they differed.

## If something goes wrong during the runs

- **A run fails its check:** the matrix stops at the first failed run. Claude
  keeps that run's evidence, looks into it, tells you what happened and **asks
  you before rerunning anything**. Only then does it restart from the cells still
  left.
- **The session cannot finish today:** Claude copies back every finished run and
  you destroy as normal. The remaining cells run in a second session, plus one
  repeated cell from the first, so the report can show whether the two machines
  differ.

## Afterwards

Claude builds the results tables and figures from the saved runs and writes
Results, Discussion and Conclusion. Every run is extracted on the backend before
the next reset, so its database numbers are kept. The open Notion box "C1 and
C2–C4 invariants" closes with the first C4 run, which carries checks 0b to 7.
