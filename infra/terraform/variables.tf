variable "aws_region" {
  description = "AWS region (locked to ap-southeast-2 by the account's Free plan)."
  type        = string
  default     = "ap-southeast-2"
}

variable "name_prefix" {
  description = "Prefix for resource names and the Name tag."
  type        = string
  default     = "flashsale"
}

variable "availability_zone" {
  description = "Availability zone for both instances (backend and JMeter share one AZ)."
  type        = string
  default     = "ap-southeast-2a"
}

variable "backend_instance_type" {
  description = "EC2 instance type for the backend host (Docker + all services)."
  type        = string
  default     = "m7i-flex.large"

  validation {
    condition     = contains(["t3.micro", "t3.small", "t4g.micro", "t4g.small", "c7i-flex.large", "m7i-flex.large"], var.backend_instance_type)
    error_message = "backend_instance_type must be one of: t3.micro, t3.small, t4g.micro, t4g.small, c7i-flex.large, m7i-flex.large."
  }
}

variable "jmeter_instance_type" {
  description = "EC2 instance type for the JMeter load generator."
  type        = string
  default     = "c7i-flex.large"

  validation {
    condition     = contains(["t3.micro", "t3.small", "t4g.micro", "t4g.small", "c7i-flex.large", "m7i-flex.large"], var.jmeter_instance_type)
    error_message = "jmeter_instance_type must be one of: t3.micro, t3.small, t4g.micro, t4g.small, c7i-flex.large, m7i-flex.large."
  }
}

variable "root_volume_size_gb" {
  description = "Root volume size in GiB (gp3, encrypted, delete on termination)."
  type        = number
  default     = 30
}

variable "auto_terminate_minutes" {
  description = "Minutes after boot each instance powers itself off as a forgotten-session safety net; AWS then terminates it (instance_initiated_shutdown_behavior = 'terminate'). terraform destroy is still the normal cleanup."
  type        = number
  default     = 240

  validation {
    condition     = var.auto_terminate_minutes >= 30 && var.auto_terminate_minutes <= 720
    error_message = "auto_terminate_minutes must be between 30 and 720 (inclusive)."
  }
}
