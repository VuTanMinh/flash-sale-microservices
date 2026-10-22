output "backend_instance_id" {
  description = "ID of the backend EC2 instance (all services)."
  value       = aws_instance.backend.id
}

output "jmeter_instance_id" {
  description = "ID of the JMeter EC2 instance."
  value       = aws_instance.jmeter.id
}

output "backend_private_ip" {
  description = "Private IP of the backend; Nginx listens here on port 80."
  value       = aws_instance.backend.private_ip
}

output "jmeter_private_ip" {
  description = "Private IP of the JMeter host."
  value       = aws_instance.jmeter.private_ip
}

output "backend_url_for_jmeter" {
  description = "Private URL the JMeter host uses to reach the API through Nginx."
  value       = "http://${aws_instance.backend.private_ip}"
}
