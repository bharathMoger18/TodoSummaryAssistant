output "app_public_ip" {
  value = aws_instance.app.public_ip
}

output "app_private_ip" {
  value = aws_instance.app.private_ip
}

output "ops_public_ip" {
  value = aws_instance.ops.public_ip
}

output "ops_private_ip" {
  value = aws_instance.ops.private_ip
}

output "app_url" {
  value = "http://${aws_instance.app.public_ip}"
}

output "grafana_url" {
  value = "http://${aws_instance.ops.public_ip}:3000"
}

output "ecr_registry" {
  value = "${data.aws_caller_identity.me.account_id}.dkr.ecr.${var.region}.amazonaws.com"
}

output "rds_endpoint" {
  value = aws_db_instance.main.address
}
