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
