# cognito ---------------------------------------------
resource "aws_cognito_user_pool" "iot_pool" {
  name = "${var.prefix}-iot-pool"
}

# GraphQL ---------------------------------------------
data "local_file" "graphql_schema" {
  filename = "./modules/graphql/schema.graphql"
}

resource "aws_appsync_graphql_api" "iot_data_api" {
  name                = "${var.prefix}_iot_data_api"
  authentication_type = "AMAZON_COGNITO_USER_POOLS"
  user_pool_config {
    aws_region     = "${data.aws_region.current.name}"
    default_action = "ALLOW"
    user_pool_id   = "${aws_cognito_user_pool.iot_pool.id}"
  }

  schema = "${data.local_file.graphql_schema.content}"
}

resource "aws_appsync_datasource" "iot_data_datasource" {
  api_id           = "${aws_appsync_graphql_api.iot_data_api.id}"
  name             = "IOTDATA"
  service_role_arn = "${aws_iam_role.dynamo_graphql_api_role.arn}"
  type             = "AMAZON_DYNAMODB"

  dynamodb_config {
    table_name = "${aws_dynamodb_table.iot_data.name}"
  }
}

resource "aws_appsync_resolver" "get" {
  api_id      = "${aws_appsync_graphql_api.iot_data_api.id}"
  field       = "getIOTDATA"
  type        = "Query"
  data_source = "${aws_appsync_datasource.iot_data_datasource.name}"

  request_template = <<EOF
{
  "version": "2017-02-28",
  "operation": "GetItem",
  "key": {
      "id": $util.dynamodb.toDynamoDBJson($ctx.args.id),
      "unixTimestamp": $util.dynamodb.toDynamoDBJson($ctx.args.unixTimestamp),
  }
}
EOF

  response_template = <<EOF
$util.toJson($context.result)
EOF
}

resource "aws_appsync_resolver" "list" {
  api_id      = "${aws_appsync_graphql_api.iot_data_api.id}"
  field       = "listIOTDATAS"
  type        = "Query"
  data_source = "${aws_appsync_datasource.iot_data_datasource.name}"

  request_template = <<EOF
{
  "version": "2017-02-28",
  "operation": "Scan",
  "filter": #if($context.args.filter) $util.transform.toDynamoDBFilterExpression($ctx.args.filter) #else null #end,
  "limit": $util.defaultIfNull($ctx.args.limit, 20),
  "nextToken": $util.toJson($util.defaultIfNullOrEmpty($ctx.args.nextToken, null)),
}
EOF

  response_template = <<EOF
$util.toJson($context.result)
EOF
}

resource "aws_appsync_resolver" "delete" {
  api_id      = "${aws_appsync_graphql_api.iot_data_api.id}"
  field       = "deleteIOTDATA"
  type        = "Mutation"
  data_source = "${aws_appsync_datasource.iot_data_datasource.name}"

  request_template = <<EOF
{
  "version": "2017-02-28",
  "operation": "DeleteItem",
  "key": {
    "id": $util.dynamodb.toDynamoDBJson($ctx.args.input.id),
    "unixTimestamp": $util.dynamodb.toDynamoDBJson($ctx.args.input.unixTimestamp),
  },
}
EOF

  response_template = <<EOF
$util.toJson($context.result)
EOF
}

resource "aws_appsync_resolver" "get_latest" {
  api_id      = "${aws_appsync_graphql_api.iot_data_api.id}"
  field       = "getLatestIOTDATA"
  type        = "Query"
  data_source = "${aws_appsync_datasource.iot_data_datasource.name}"

  request_template = <<EOF
{
  "version" : "2017-02-28",
  "operation" : "Query",
  "query" : {
      "expression": "id = :id",
      "expressionValues" : {
          ":id" : { "S" : "$ctx.args.id" }
      }
  },
  "scanIndexForward": false,
  "limit": $util.defaultIfNull($ctx.args.limit, 1),
}
EOF

  response_template = <<EOF
$util.toJson($context.result)
EOF
}

resource "aws_iam_role" "dynamo_graphql_api_role" {
  name = "${var.prefix}-dynamo-graphql-api"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "appsync.amazonaws.com"
      },
      "Effect": "Allow"
    }
  ]
}
EOF
}


resource "aws_iam_role_policy" "dynamo_graphql_api_policy" {
  name = "${var.prefix}-dynamo-graphql-api-policy"
  role = "${aws_iam_role.dynamo_graphql_api_role.id}"

  policy = <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "dynamodb:DeleteItem",
                "dynamodb:GetItem",
                "dynamodb:PutItem",
                "dynamodb:Query",
                "dynamodb:Scan",
                "dynamodb:UpdateItem"
            ],
            "Resource": [
                "${aws_dynamodb_table.iot_data.arn}",
                "${aws_dynamodb_table.iot_data.arn}/*"
            ]
        }
    ]
}
EOF
}

resource "aws_cloudformation_stack" "iot_data_rule" {
  name = "${var.prefix}-iot-data-rule"

  template_body = <<EOF
AWSTemplateFormatVersion : 2010-09-09
Resources:
  TopicRule:
    Type: AWS::IoT::TopicRule
    Properties: 
      RuleName: "${var.prefix}_iot_data_rule"
      TopicRulePayload: 
        AwsIotSqlVersion: "2016-03-23"
        Sql: SELECT device AS id, newuuid() AS messageId, timestamp() AS unixTimestamp, cast((timestamp()/1000) as Int)+7*60*60*24 AS timeToExist, parse_time("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", timestamp()) AS datetime, * AS payload FROM 'abt/data/#'
        RuleDisabled: False
        Actions: 
          - DynamoDBv2:
              PutItem:
                TableName: "${aws_dynamodb_table.iot_data.id}"
              RoleArn: "${module.dynamodb_put_role.iam_role_arn}"
          - Firehose:
              DeliveryStreamName: "${aws_kinesis_firehose_delivery_stream.stream_to_elasticsearch.name}"
              RoleArn: "${module.firehose_put_role.iam_role_arn}"
              Separator: "\n"
          - Firehose:
              DeliveryStreamName: "${aws_kinesis_firehose_delivery_stream.stream_to_s3.name}"
              RoleArn: "${module.firehose_put_role.iam_role_arn}"
              Separator: "\n"
        ErrorAction: 
          S3:
            BucketName: "${aws_s3_bucket.error_bucket.id}"
            Key: "$${timestamp()}"
            RoleArn: "${module.s3_put_role.iam_role_arn}"
EOF
}

data "aws_iam_policy_document" "firehose_put_policy" {
  statement {
    effect  = "Allow"
    actions = ["firehose:PutRecord"]
    resources = [
      "${aws_kinesis_firehose_delivery_stream.stream_to_elasticsearch.arn}",
      "${aws_kinesis_firehose_delivery_stream.stream_to_s3.arn}"
    ]
  }
}

module "firehose_put_role" {
  source     = "./modules/iam_role"
  name       = "${var.prefix}-firehose-put-role"
  identifier = "iot.amazonaws.com"
  policy     = data.aws_iam_policy_document.firehose_put_policy.json
}


data "aws_iam_policy_document" "dynamodb_put_policy" {
  statement {
    effect    = "Allow"
    actions   = ["dynamodb:PutItem"]
    resources = ["${aws_dynamodb_table.iot_data.arn}"]
  }
}

module "dynamodb_put_role" {
  source     = "./modules/iam_role"
  name       = "${var.prefix}-dynamodb-put-role"
  identifier = "iot.amazonaws.com"
  policy     = data.aws_iam_policy_document.dynamodb_put_policy.json
}

data "aws_iam_policy_document" "s3_put_policy" {
  statement {
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.error_bucket.arn}", "${aws_s3_bucket.error_bucket.arn}/*"]
  }
}

module "s3_put_role" {
  source     = "./modules/iam_role"
  name       = "${var.prefix}-s3-put-role"
  identifier = "iot.amazonaws.com"
  policy     = data.aws_iam_policy_document.s3_put_policy.json
}

# Kinesis Firehose ---------------------------------------------
resource "aws_kinesis_firehose_delivery_stream" "stream_to_elasticsearch" {
  name        = "${var.prefix}-kinesis-firehose-iot-stream-to-elasticsearch"
  destination = "elasticsearch"

  elasticsearch_configuration {
    domain_arn            = "${aws_elasticsearch_domain.elasticsearch_cluster.arn}"
    role_arn              = "${aws_iam_role.firehose_iot_role.arn}"
    index_name            = "iot-data"
    type_name             = "iot-data"
    buffering_interval    = 60
    buffering_size        = 1
    index_rotation_period = "OneDay"
    retry_duration        = 300
    s3_backup_mode        = "FailedDocumentsOnly"
  }

  s3_configuration {
    role_arn           = "${aws_iam_role.firehose_iot_role.arn}"
    bucket_arn         = "${aws_s3_bucket.elasticsearch_backup_bucket.arn}"
    buffer_size        = 10
    buffer_interval    = 300
    compression_format = "GZIP"
  }
}

resource "aws_kinesis_firehose_delivery_stream" "stream_to_s3" {
  name        = "${var.prefix}-kinesis-firehose-iot-stream-to-s3"
  destination = "s3"

  s3_configuration {
    role_arn           = "${aws_iam_role.firehose_iot_role.arn}"
    bucket_arn         = "${aws_s3_bucket.api_bucket.arn}"
    buffer_size        = 10
    buffer_interval    = 300
    compression_format = "UNCOMPRESSED"
  }
}

# Hack: Must modify right to access
resource "aws_iam_role" "firehose_iot_role" {
  name = "${var.prefix}-firehose-iot-role"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "firehose.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF
}

resource "aws_iam_role_policy" "firehose_iot_policy" {
  name = "${var.prefix}-firehose-iot-policy"
  role = "${aws_iam_role.firehose_iot_role.id}"

  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "",
      "Effect": "Allow",
      "Action": [
        "s3:AbortMultipartUpload",
        "s3:GetBucketLocation",
        "s3:GetObject",
        "s3:ListBucket",
        "s3:ListBucketMultipartUploads",
        "s3:PutObject"
      ],
      "Resource": [
        "${aws_s3_bucket.error_bucket.arn}",
        "${aws_s3_bucket.error_bucket.arn}/*"
      ]
    },
    {
      "Sid": "",
      "Effect": "Allow",
      "Action": [
        "lambda:InvokeFunction",
        "lambda:GetFunctionConfiguration"
      ],
      "Resource": "arn:aws:lambda:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:function:%FIREHOSE_DEFAULT_FUNCTION%:%FIREHOSE_DEFAULT_VERSION%"
    },
    {
      "Sid": "",
      "Effect": "Allow",
      "Action": [
        "es:DescribeElasticsearchDomain",
        "es:DescribeElasticsearchDomains",
        "es:DescribeElasticsearchDomainConfig",
        "es:ESHttpPost",
        "es:ESHttpPut"
      ],
      "Resource": [
        "arn:aws:es:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:domain/${aws_elasticsearch_domain.elasticsearch_cluster.domain_name}",
        "arn:aws:es:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:domain/${aws_elasticsearch_domain.elasticsearch_cluster.domain_name}/*"
      ]
    },
    {
      "Sid": "",
      "Effect": "Allow",
      "Action": [
        "es:ESHttpGet"
      ],
      "Resource": [
        "arn:aws:es:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:domain/${aws_elasticsearch_domain.elasticsearch_cluster.domain_name}/_all/_settings",
        "arn:aws:es:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:domain/${aws_elasticsearch_domain.elasticsearch_cluster.domain_name}/_cluster/stats",
        "arn:aws:es:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:domain/${aws_elasticsearch_domain.elasticsearch_cluster.domain_name}/qrwrtetgjhhr*/_mapping/wqefrtntrgwef",
        "arn:aws:es:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:domain/${aws_elasticsearch_domain.elasticsearch_cluster.domain_name}/_nodes",
        "arn:aws:es:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:domain/${aws_elasticsearch_domain.elasticsearch_cluster.domain_name}/_nodes/stats",
        "arn:aws:es:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:domain/${aws_elasticsearch_domain.elasticsearch_cluster.domain_name}/_nodes/*/stats",
        "arn:aws:es:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:domain/${aws_elasticsearch_domain.elasticsearch_cluster.domain_name}/_stats",
        "arn:aws:es:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:domain/${aws_elasticsearch_domain.elasticsearch_cluster.domain_name}/qrwrtetgjhhr*/_stats"
      ]
    },
    {
      "Sid": "",
      "Effect": "Allow",
      "Action": [
        "logs:PutLogEvents"
      ],
      "Resource": [
        "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:/aws/kinesisfirehose/wer:log-stream:*"
      ]
    },
    {
      "Sid": "",
      "Effect": "Allow",
      "Action": [
        "kinesis:DescribeStream",
        "kinesis:GetShardIterator",
        "kinesis:GetRecords"
      ],
      "Resource": "arn:aws:kinesis:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:stream/%FIREHOSE_STREAM_NAME%"
    },
    {
      "Effect": "Allow",
      "Action": [
        "kms:Decrypt"
      ],
      "Resource": [
        "arn:aws:kms:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:key/%SSE_KEY_ID%"
      ],
      "Condition": {
        "StringEquals": {
          "kms:ViaService": "kinesis.%REGION_NAME%.amazonaws.com"
        },
        "StringLike": {
          "kms:EncryptionContext:aws:kinesis:arn": "arn:aws:kinesis:%REGION_NAME%:${data.aws_caller_identity.current.account_id}:stream/%FIREHOSE_STREAM_NAME%"
        }
      }
    }
  ]
}
EOF
}

# Elasticsearch ---------------------------------------------
resource "aws_elasticsearch_domain" "elasticsearch_cluster" {
  domain_name           = "${var.prefix}-es"
  elasticsearch_version = "6.8"

  cluster_config {
    instance_type  = "t2.small.elasticsearch"
    instance_count = 1
  }

  ebs_options {
    ebs_enabled = true
    volume_type = "gp2"
    volume_size = 10
  }

  snapshot_options {
    automated_snapshot_start_hour = 14 # 23:00 JST
  }

  tags = {
    deploy_type = "${var.deploy_type}"
  }

  access_policies = <<POLICY
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Action": "es:*",
            "Principal": "*",
            "Effect": "Allow",
            "Condition": {
                "IpAddress": {"aws:SourceIp": "202.246.248.0/21"}
            },
            "Resource": "arn:aws:es:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:domain/${var.prefix}-es/*"
        }
    ]
}
POLICY
}

# Dynamo DB ---------------------------------------------
resource "aws_dynamodb_table" "iot_data" {
  name         = "${var.prefix}-iot-data"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "id"
  range_key    = "unixTimestamp"

  attribute {
    name = "id"
    type = "S"
  }

  attribute {
    name = "unixTimestamp"
    type = "N"
  }

  ttl {
    enabled        = true
    attribute_name = "timeToExist"
  }

  tags = {
    deploy_type = "${var.deploy_type}"
  }
}

# S3 ---------------------------------------------
resource "aws_s3_bucket" "elasticsearch_backup_bucket" {
  bucket_prefix = "${var.prefix}-elasticsearch-backup"
  acl           = "private"
  force_destroy = true

  tags = {
    deploy_type = "${var.deploy_type}"
  }
}

resource "aws_s3_bucket" "api_bucket" {
  bucket_prefix = "${var.prefix}-api-bucket"
  acl           = "private"
  force_destroy = true

  tags = {
    deploy_type = "${var.deploy_type}"
  }
}

resource "aws_s3_bucket" "error_bucket" {
  bucket_prefix = "${var.prefix}-error-bucket"
  acl           = "private"
  force_destroy = true

  tags = {
    deploy_type = "${var.deploy_type}"
  }
}
