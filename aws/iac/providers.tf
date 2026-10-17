terraform {
  required_version = ">= 1.6"

  required_providers {
    aws    = { source = "hashicorp/aws", version = "~> 5.80" }
    random = { source = "hashicorp/random", version = "~> 3.6" }
    tls    = { source = "hashicorp/tls", version = "~> 4.0" }
    local  = { source = "hashicorp/local", version = "~> 2.5" }
  }

  # State stays on local disk. The path is passed at init time
  # (terraform init -backend-config="path=...") so Jenkins can keep it in its own volume.
  backend "local" {}
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "todo-summary-assistant"
      ManagedBy = "terraform"
    }
  }
}
