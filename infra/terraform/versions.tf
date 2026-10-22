# Terraform for the Week 12 box 3 EC2 deployment (offline half).
#
# Local state only (no remote backend): .terraform/, *.tfstate* and *.tfvars are
# git-ignored. `terraform init` writes .terraform.lock.hcl, which pins the exact
# provider version and hashes and MUST be committed.
terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "5.100.0"
    }
  }
}
