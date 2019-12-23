output "kibana_endpoint" {
  value = aws_elasticsearch_domain.elasticsearch_cluster.kibana_endpoint
}

output "elasticsearch_backup_bucket_name" {
  value = aws_s3_bucket.elasticsearch_backup_bucket.id
}

output "api_bucket_name" {
  value = aws_s3_bucket.api_bucket.id
}

output "error_bucket_name" {
  value = aws_s3_bucket.error_bucket.id
}
