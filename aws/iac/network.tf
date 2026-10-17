data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 2)
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "todo-vpc" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "todo-igw" }
}

# --- Public subnets: the two EC2 hosts ---
resource "aws_subnet" "ops" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, 1)
  availability_zone       = local.azs[0]
  map_public_ip_on_launch = true
  tags                    = { Name = "todo-ops-subnet" }
}

resource "aws_subnet" "app" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, 2)
  availability_zone       = local.azs[0]
  map_public_ip_on_launch = true
  tags                    = { Name = "todo-app-subnet" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "todo-public-rt" }
}

resource "aws_route_table_association" "ops" {
  subnet_id      = aws_subnet.ops.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "app" {
  subnet_id      = aws_subnet.app.id
  route_table_id = aws_route_table.public.id
}

# --- Private subnets: RDS only. No route to the internet at all. ---
# RDS needs a subnet group that spans at least two availability zones.
resource "aws_subnet" "db_a" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, 11)
  availability_zone = local.azs[0]
  tags              = { Name = "todo-db-subnet-a" }
}

resource "aws_subnet" "db_b" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, 12)
  availability_zone = local.azs[1]
  tags              = { Name = "todo-db-subnet-b" }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "todo-private-rt" }
}

resource "aws_route_table_association" "db_a" {
  subnet_id      = aws_subnet.db_a.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "db_b" {
  subnet_id      = aws_subnet.db_b.id
  route_table_id = aws_route_table.private.id
}

resource "aws_db_subnet_group" "main" {
  name       = "todo-db-subnets"
  subnet_ids = [aws_subnet.db_a.id, aws_subnet.db_b.id]
}

# --- Security groups ---
resource "aws_security_group" "app" {
  name        = "todo-app-sg"
  description = "App host"
  vpc_id      = aws_vpc.main.id
}

resource "aws_security_group" "ops" {
  name        = "todo-ops-sg"
  description = "Monitoring host"
  vpc_id      = aws_vpc.main.id
}

resource "aws_security_group" "rds" {
  name        = "todo-rds-sg"
  description = "Database"
  vpc_id      = aws_vpc.main.id
}

# App host: port 80 is the only thing open to the internet.
resource "aws_vpc_security_group_ingress_rule" "app_http" {
  security_group_id = aws_security_group.app.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
}

resource "aws_vpc_security_group_ingress_rule" "app_ssh" {
  security_group_id = aws_security_group.app.id
  cidr_ipv4         = var.operator_cidr
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
}

# Prometheus (on the ops host) scrapes backend metrics, node-exporter and cAdvisor.
resource "aws_vpc_security_group_ingress_rule" "app_metrics" {
  for_each                     = toset(["8080", "9100", "8081"])
  security_group_id            = aws_security_group.app.id
  referenced_security_group_id = aws_security_group.ops.id
  ip_protocol                  = "tcp"
  from_port                    = tonumber(each.value)
  to_port                      = tonumber(each.value)
}

# Ops host: only the operator can reach SSH and Grafana.
resource "aws_vpc_security_group_ingress_rule" "ops_ssh" {
  security_group_id = aws_security_group.ops.id
  cidr_ipv4         = var.operator_cidr
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
}

resource "aws_vpc_security_group_ingress_rule" "ops_grafana" {
  security_group_id = aws_security_group.ops.id
  cidr_ipv4         = var.operator_cidr
  ip_protocol       = "tcp"
  from_port         = 3000
  to_port           = 3000
}

# Optional extra viewers (for example a reviewer). Never 0.0.0.0/0, see the variable validation.
resource "aws_vpc_security_group_ingress_rule" "ops_grafana_viewers" {
  for_each          = toset([for c in var.grafana_viewer_cidrs : c if c != var.operator_cidr])
  security_group_id = aws_security_group.ops.id
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 3000
  to_port           = 3000
}

# RDS: MySQL only, and only from the app security group.
resource "aws_vpc_security_group_ingress_rule" "rds_from_app" {
  security_group_id            = aws_security_group.rds.id
  referenced_security_group_id = aws_security_group.app.id
  ip_protocol                  = "tcp"
  from_port                    = 3306
  to_port                      = 3306
}

# Both hosts need outbound access (package installs, ECR pulls, image downloads).
resource "aws_vpc_security_group_egress_rule" "app_all" {
  security_group_id = aws_security_group.app.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_vpc_security_group_egress_rule" "ops_all" {
  security_group_id = aws_security_group.ops.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}
