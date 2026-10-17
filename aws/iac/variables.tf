variable "region" {
  type    = string
  default = "ap-south-1"
}

variable "operator_cidr" {
  type        = string
  description = "Your public IP as a /32 (for example 203.0.113.4/32). The only address allowed to use SSH and Grafana."

  validation {
    condition     = can(cidrhost(var.operator_cidr, 0)) && endswith(var.operator_cidr, "/32")
    error_message = "operator_cidr must be a single address in CIDR form, like 203.0.113.4/32."
  }
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "app_instance_type" {
  type    = string
  default = "t3.small"
}

variable "ops_instance_type" {
  type    = string
  default = "t3.medium"
}

variable "db_instance_class" {
  type    = string
  default = "db.t3.micro"
}

variable "ssh_key_path" {
  type        = string
  default     = "todo-key.pem"
  description = "Where the generated SSH private key is written. It is never committed."
}

variable "grafana_viewer_cidrs" {
  type        = list(string)
  default     = []
  description = "Extra IPs allowed to open Grafana, for example a reviewer. The operator address is always allowed."

  validation {
    condition     = alltrue([for c in var.grafana_viewer_cidrs : can(cidrhost(c, 0)) && c != "0.0.0.0/0"])
    error_message = "Each entry must be a valid CIDR such as 203.0.113.4/32, and 0.0.0.0/0 is not allowed."
  }
}
