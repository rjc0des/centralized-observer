# SSM SecureString parameters, one per secret, named <prefix>/<ENV_VAR_NAME> so the
# host can turn them back into its .env with one get-parameters-by-path call.
#
# Values are write-only (value_wo): Terraform sends them to SSM but never stores them in
# state or plans. To rotate, change the value and bump var.rotation.
# Encrypted with the AWS-managed key alias/aws/ssm (free).

variable "prefix" {
  type = string
}

# Names only: for_each can't iterate an ephemeral value, so the names come separately.
variable "names" {
  type = set(string)
}

variable "values" {
  type      = map(string)
  ephemeral = true
  sensitive = true
}

variable "rotation" {
  type    = number
  default = 1
}

resource "aws_ssm_parameter" "this" {
  for_each         = var.names
  name             = "${var.prefix}/${each.key}"
  type             = "SecureString"
  value_wo         = var.values[each.key]
  value_wo_version = var.rotation
}

output "arns" {
  value = [for p in aws_ssm_parameter.this : p.arn]
}
