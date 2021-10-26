// -----------------------------------------
// ---------------- IMPORTS ----------------
// -----------------------------------------
terraform {
  required_providers {
    databricks = {
      source  = "databrickslabs/databricks"
      version = "0.3.7"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "3.49.0"
    }
  }
}

// -------------------------------------------------
// ---------------- INPUT VARIABLES ----------------
// -------------------------------------------------

variable "tags" {
  description = "additional resource tags"
  default     = {}
}

variable "aws_region" {
  description = "AWS region where the workspace shall be provisioned"
}

variable "aws_cidr_block" {
  default = "10.4.0.0/16"
}

variable "databricks_account_name" {
  description = "Account name in Databricks"
}
variable "databricks_workspace_name" {
  description = "Databricks workspace name"
}

variable "databricks_account_id" {
  description = "Your Databricks Account Id"
}

variable "databricks_username" {
  description = "Email you use to login to https://accounts.cloud.databricks.com/"
}

variable "databricks_password" {
  description = "Password you use to login to https://accounts.cloud.databricks.com/"
}

// --------------------------------------------------
// ---------------- LOCALS  -------------------------
// --------------------------------------------------

locals {
  aws_prefix = "${var.databricks_account_name}-${var.databricks_workspace_name}"
}

// --------------------------------------------------
// ---------------- PROVIDERS -----------------------
// --------------------------------------------------

provider "aws" {
  region = var.aws_region
}

provider "databricks" {
  alias    = "mws"
  host     = "https://accounts.cloud.databricks.com/"
  username = var.databricks_username
  password = var.databricks_password
}


// --------------------------------------------------
// ---------------- CREDENTIALS ---------------------
// --------------------------------------------------


data "databricks_aws_assume_role_policy" "this" {
  external_id = var.databricks_account_id
}

resource "aws_iam_role" "cross_account_role" {
  name               = "${local.aws_prefix}-crossaccount"
  assume_role_policy = data.databricks_aws_assume_role_policy.this.json
  tags               = var.tags
}

data "databricks_aws_crossaccount_policy" "this" {
}

resource "aws_iam_role_policy" "this" {
  name   = "${local.aws_prefix}-policy"
  role   = aws_iam_role.cross_account_role.id
  policy = data.databricks_aws_crossaccount_policy.this.json
}


// ----------------------------------------------
// ---------------- NETWORK ---------------------
// ----------------------------------------------

data "aws_availability_zones" "available" {}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "3.2.0"

  name = "${local.aws_prefix}-vpc"
  cidr = var.aws_cidr_block
  azs  = data.aws_availability_zones.available.names
  tags = var.tags

  enable_dns_hostnames = true
  enable_nat_gateway   = true
  create_igw           = true

  public_subnets = [cidrsubnet(var.aws_cidr_block, 3, 0)]
  private_subnets = [cidrsubnet(var.aws_cidr_block, 3, 1),
  cidrsubnet(var.aws_cidr_block, 3, 2)]

  manage_default_security_group = true
  default_security_group_name   = "${local.aws_prefix}-sg"

  default_security_group_egress = [{
    cidr_blocks = "0.0.0.0/0"
  }]

  default_security_group_ingress = [{
    description = "Allow all internal TCP and UDP"
    self        = true
  }]
}

module "vpc_endpoints" {
  source  = "terraform-aws-modules/vpc/aws//modules/vpc-endpoints"
  version = "3.2.0"

  vpc_id             = module.vpc.vpc_id
  security_group_ids = [module.vpc.default_security_group_id]

  endpoints = {
    s3 = {
      service      = "s3"
      service_type = "Gateway"
      route_table_ids = flatten([
        module.vpc.private_route_table_ids,
      module.vpc.public_route_table_ids])
      tags = {
        Name = "${local.aws_prefix}-s3-vpc-endpoint"
      }
    },
    sts = {
      service             = "sts"
      private_dns_enabled = true
      subnet_ids          = module.vpc.private_subnets
      tags = {
        Name = "${local.aws_prefix}-sts-vpc-endpoint"
      }
    },
    kinesis-streams = {
      service             = "kinesis-streams"
      private_dns_enabled = true
      subnet_ids          = module.vpc.private_subnets
      tags = {
        Name = "${local.aws_prefix}-kinesis-vpc-endpoint"
      }
    },
  }

  tags = var.tags
}


// ----------------------------------------------
// ---------------- STORAGE ---------------------
// ----------------------------------------------


resource "aws_s3_bucket" "root_storage_bucket" {
  bucket = "${local.aws_prefix}-rootbucket"
  acl    = "private"
  versioning {
    enabled = false
  }
  force_destroy = true
  tags = merge(var.tags, {
    Name = "${local.aws_prefix}-rootbucket"
  })
}

resource "aws_s3_bucket_public_access_block" "root_storage_bucket" {
  bucket             = aws_s3_bucket.root_storage_bucket.id
  ignore_public_acls = true
  depends_on         = [aws_s3_bucket.root_storage_bucket]
}

data "databricks_aws_bucket_policy" "this" {
  bucket = aws_s3_bucket.root_storage_bucket.bucket
}

resource "aws_s3_bucket_policy" "root_bucket_policy" {
  bucket     = aws_s3_bucket.root_storage_bucket.id
  policy     = data.databricks_aws_bucket_policy.this.json
  depends_on = [aws_s3_bucket_public_access_block.root_storage_bucket]
}

// ----------------------------------------------
// ---------------- CONFIGURATIONS --------------
// ----------------------------------------------

resource "databricks_mws_credentials" "this" {
  provider         = databricks.mws
  account_id       = var.databricks_account_id
  role_arn         = aws_iam_role.cross_account_role.arn
  credentials_name = "${local.aws_prefix}-creds"
  depends_on       = [aws_iam_role_policy.this]
}

resource "databricks_mws_networks" "this" {
  provider           = databricks.mws
  account_id         = var.databricks_account_id
  network_name       = "${local.aws_prefix}-network"
  security_group_ids = [module.vpc.default_security_group_id]
  subnet_ids         = module.vpc.private_subnets
  vpc_id             = module.vpc.vpc_id
}

resource "databricks_mws_storage_configurations" "this" {
  provider                   = databricks.mws
  account_id                 = var.databricks_account_id
  bucket_name                = aws_s3_bucket.root_storage_bucket.bucket
  storage_configuration_name = "${local.aws_prefix}-storage"
}

// -----------------------------------------
// ---------------- WORKSPACE --------------
// -----------------------------------------

resource "time_sleep" "wait_for_iam_role" {
  depends_on = [
  aws_iam_role.cross_account_role]
  create_duration = "10s"
}


resource "databricks_mws_workspaces" "this" {
  provider       = databricks.mws
  account_id     = var.databricks_account_id
  aws_region     = var.aws_region
  workspace_name = var.databricks_workspace_name

  credentials_id           = databricks_mws_credentials.this.credentials_id
  storage_configuration_id = databricks_mws_storage_configurations.this.storage_configuration_id
  network_id               = databricks_mws_networks.this.network_id

  depends_on = [
    time_sleep.wait_for_iam_role
  ]
}

output "databricks_host" {
  value = databricks_mws_workspaces.this.workspace_url
}
