# Week 13 EC2 session: the steps only you can do

Claude does everything on the servers: it deploys the stack over SSM, runs the
live check and the pilot, and copies the evidence back. You do the AWS account
steps below, because Claude never runs `terraform apply` or `destroy`.

Allow one sitting for steps 1 to 7 (about 15 minutes), then stay reachable. The
servers cost credits from step 6 until step 9, so do step 9 the same day.

Run every command in **PowerShell on your PC**. The full background is in
[deployment.md](deployment.md), sections 0a, 3 and 8.

## Step 1. Say "push"

The servers clone `main-test-bug-fix` from GitHub, so they only get what has been
pushed. Tell Claude "push" and wait for the new hash before step 2.

## Step 2. Open a terminal in the Terraform folder

```powershell
cd D:\DACNTT\infra\terraform
```

## Step 3. Create the settings file

Skip this if `terraform.tfvars` already exists. It is git-ignored and holds no
secrets.

```powershell
if (-not (Test-Path terraform.tfvars)) { Copy-Item terraform.tfvars.example terraform.tfvars }
```

## Step 4. Log in to AWS

```powershell
aws login --profile flashsale-deploy
```

A browser window opens. Sign in there, then check it worked:

```powershell
aws sts get-caller-identity --profile flashsale-deploy
```

**You should see** your account number, `706421610937`. The login lasts about
12 hours. If a later step says the session expired, run this step again.

## Step 5. Check the instance profile is still there

```powershell
aws iam get-instance-profile --instance-profile-name flashsale-ec2-ssm --profile flashsale-deploy
```

**You should see** a block of JSON naming `flashsale-ec2-ssm`. If you see
`NoSuchEntity`, stop and tell Claude.

## Step 6. Create the servers

Terraform uses its own profile, `flashsale-deploy-tf`, which borrows the login
from step 4. The 480 keeps the servers alive for 8 hours, because the default of 4
hours could end the pilot midway and lose its data.

```powershell
$env:AWS_PROFILE = "flashsale-deploy-tf"
terraform init
terraform apply -var-file=terraform.tfvars -var auto_terminate_minutes=480
```

Read the plan. **It should say** `4 to add, 0 to change, 0 to destroy`. If it does,
type `yes`. If it shows anything else, type `no` and tell Claude.

## Step 7. Send Claude the server details

```powershell
terraform output
```

Paste the whole output to Claude. It holds instance ids and private addresses,
not secrets. Claude takes over from here.

## Step 8. Sign off the pilot

Claude reports the pilot results and the values it proposes to freeze: the shedding
limits, the Worker delay and the workload matrix. The Week 13 milestone needs your
sign-off on these before any official run, so read them and answer yes or no.

The backend stays on `m7i-flex.large`, as you decided, so the results report the
achieved rate as a limitation against the 2,000/s target.

## Step 9. Destroy the servers

**Wait until Claude says the evidence is copied back.** Anything still on the
servers is lost here.

```powershell
cd D:\DACNTT\infra\terraform
$env:AWS_PROFILE = "flashsale-deploy-tf"
terraform destroy -var-file=terraform.tfvars
```

Type `yes`. **It should end with** `Destroy complete! Resources: 4 destroyed.`
If the login expired, do step 4 first.

## Step 10. Check nothing is left

```powershell
aws ec2 describe-instances --filters "Name=tag:Project,Values=flash-sale" "Name=instance-state-name,Values=pending,running,stopping,stopped" --query "Reservations[].Instances[].InstanceId" --profile flashsale-deploy
aws ec2 describe-security-groups --filters "Name=tag:Project,Values=flash-sale" --query "SecurityGroups[].GroupId" --profile flashsale-deploy
aws ec2 describe-volumes --filters "Name=tag:Project,Values=flash-sale" --query "Volumes[].VolumeId" --profile flashsale-deploy
```

**Each command should print** `[]`. Paste the output to Claude. If any list is not
empty, tell Claude before closing the terminal.

## If something goes wrong

- Stop at the failing step and paste the error to Claude.
- If a step fails after step 6, the servers are still costing credits, so tell
  Claude soon. Step 9 is safe to run at any time once you accept losing what is on
  them.
- Never paste passwords, access keys or the contents of `infra/ec2.env`.
