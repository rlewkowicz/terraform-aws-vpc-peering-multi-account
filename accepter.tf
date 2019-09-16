variable "accepter_region" {
  type        = "string"
  description = "Accepter AWS region"
}

variable "accepter_vpc_id" {
  type        = "string"
  description = "Accepter VPC ID filter"
  default     = ""
}

variable "accepter_vpc_tags" {
  type        = "map"
  description = "Accepter VPC Tags filter"
  default     = {}
}

variable "accepter_allow_remote_vpc_dns_resolution" {
  default     = "true"
  description = "Allow accepter VPC to resolve public DNS hostnames to private IP addresses when queried from instances in the requester VPC"
}

# Accepter's credentials
provider "aws" {
  alias   = "accepter"
  region  = "${var.accepter_region}"
  version = ">= 1.25"
}

locals {
  accepter_attributes = "${concat(var.attributes, list("accepter"))}"
  accepter_tags       = "${merge(var.tags, map("Side", "accepter"))}"
}

module "accepter" {
  source     = "git::https://github.com/cloudposse/terraform-null-label.git?ref=tags/0.3.3"
  enabled    = "${var.enabled}"
  namespace  = "${var.namespace}"
  name       = "${var.name}"
  stage      = "${var.stage}"
  delimiter  = "${var.delimiter}"
  attributes = "${local.accepter_attributes}"
  tags       = "${local.accepter_tags}"
}

data "aws_caller_identity" "accepter" {
  count    = "${local.count}"
  provider = "aws.accepter"
}

data "aws_region" "accepter" {
  count    = "${local.count}"
  provider = "aws.accepter"
}

# Lookup accepter's VPC so that we can reference the CIDR
data "aws_vpc" "accepter" {
  count    = "${local.count}"
  provider = "aws.accepter"
  id       = "${var.accepter_vpc_id}"
  tags     = "${var.accepter_vpc_tags}"
}

# Lookup accepter subnets
data "aws_subnet_ids" "accepter" {
  count    = "${local.count}"
  provider = "aws.accepter"
  vpc_id   = "${local.accepter_vpc_id}"
}

locals {
  accepter_subnet_ids       = "${distinct(sort(flatten(data.aws_subnet_ids.accepter.*.ids)))}"
  accepter_subnet_ids_count = "${length(local.accepter_subnet_ids)}"
  accepter_vpc_id           = "${join("", data.aws_vpc.accepter.*.id)}"
  accepter_account_id       = "${join("", data.aws_caller_identity.accepter.*.account_id)}"
  accepter_region           = "${join("", data.aws_region.accepter.*.name)}"
}

# Lookup accepter route tables
data "aws_route_tables" "accepter" {
  count    = "${local.count}"
  provider = "aws.accepter"
  vpc_id   = "${local.accepter_vpc_id}"
}

locals {
  accepter_aws_route_table_ids           = "${distinct(sort(data.aws_route_tables.accepter.ids))}"
  accepter_aws_route_table_ids_count     = "${length(local.accepter_aws_route_table_ids)}"
  accepter_cidr_block_associations       = "${flatten(data.aws_vpc.accepter.*.cidr_block_associations)}"
  accepter_cidr_block_associations_count = "${length(local.accepter_cidr_block_associations)}"
}

# Create routes from accepter to requester
resource "aws_route" "accepter" {
  count                     = "${local.enabled ? local.accepter_aws_route_table_ids_count * local.requester_cidr_block_associations_count : 0}"
  provider                  = "aws.accepter"
  route_table_id            = "${element(local.accepter_aws_route_table_ids, ceil(count.index / local.requester_cidr_block_associations_count))}"
  destination_cidr_block    = "${lookup(local.requester_cidr_block_associations[count.index % local.requester_cidr_block_associations_count], "cidr_block")}"
  vpc_peering_connection_id = "${join("", aws_vpc_peering_connection.requester.*.id)}"
  depends_on                = ["data.aws_route_tables.accepter", "aws_vpc_peering_connection_accepter.accepter", "aws_vpc_peering_connection.requester"]
}

# Accepter's side of the connection.
resource "aws_vpc_peering_connection_accepter" "accepter" {
  count                     = "${local.count}"
  provider                  = "aws.accepter"
  vpc_peering_connection_id = "${join("", aws_vpc_peering_connection.requester.*.id)}"
  auto_accept               = "${var.auto_accept}"
  tags                      = "${module.accepter.tags}"
}

resource "aws_vpc_peering_connection_options" "accepter" {
  provider                  = "aws.accepter"
  vpc_peering_connection_id = "${join("", aws_vpc_peering_connection.requester.*.id)}"

  accepter {
    allow_remote_vpc_dns_resolution = "${var.accepter_allow_remote_vpc_dns_resolution}"
  }
}

output "accepter_connection_id" {
  value       = "${join("", aws_vpc_peering_connection_accepter.accepter.*.id)}"
  description = "Accepter VPC peering connection ID"
}

output "accepter_accept_status" {
  value       = "${join("", aws_vpc_peering_connection_accepter.accepter.*.accept_status)}"
  description = "Accepter VPC peering connection request status"
}
