#!/usr/bin/env bash
# Integration test for infrastructure/terraform/environments/local on Floci: apply,
# no drift on a second plan, the account guard, secrets kept out of state, and each
# resource's security settings read back with the AWS CLI. Leaves the environment
# applied (like the rest of the stack). Needs `make up` first; takes ~1-2 minutes.
set -uo pipefail
source "$(dirname "$0")/lib.sh"

ENV_DIR=infrastructure/terraform/environments/local
STATE=$ENV_DIR/terraform.tfstate
SECRETS="POSTGRES_PASSWORD ECOMMERCE_OWNER_PASSWORD ECOMMERCE_APP_PASSWORD INCIDENT_DB_PASSWORD INCIDENT_OWNER_PASSWORD INCIDENT_APP_PASSWORD INCIDENT_API_TOKEN REDIS_PASSWORD GRAFANA_ADMIN_PASSWORD"

tf() { docker compose --progress quiet run --rm -T terraform -chdir=$ENV_DIR "$@" -input=false -no-color; }
aws() { docker compose --progress quiet run --rm -T aws "$@" --output json; }

echo "== Credentials"
# The Floci tool containers must never see real credentials; only the profile-"aws"
# services (aws-real, terraform-aws) mount ~/.aws.
cfg=$(docker compose --profile tools config --format json)
mounts=$(jq -r '[.services.aws, .services.terraform | (.volumes // [])[] | .source] | map(select(test("\\.aws"))) | join(",")' <<<"$cfg")
envs=$(jq -r '[.services.aws, .services.terraform | .environment | keys[]] | map(select(test("PROFILE|SHARED_CREDENTIALS|SESSION_TOKEN"))) | join(",")' <<<"$cfg")
[ -z "$mounts$envs" ] && pass "Floci aws/terraform containers mount no ~/.aws and set no profile" ||
  bad "Floci tool containers can reach real credentials: $mounts $envs"

echo "== Terraform"
tf init >/dev/null && pass "init" || bad "terraform init failed"
out=$(tf apply -auto-approve 2>&1) && pass "apply" || bad "apply failed: $(tail -20 <<<"$out")"
tf plan -detailed-exitcode >/dev/null 2>&1
rc=$?
[ $rc -eq 0 ] && pass "second plan is empty (Floci returns what was written)" || bad "second plan exit $rc (2 = drift)"

# Floci derives the account from a 12-digit access key: the provider must refuse it.
out=$(docker compose --progress quiet run --rm -T -e AWS_ACCESS_KEY_ID=111111111111 terraform -chdir=$ENV_DIR plan -input=false -no-color 2>&1)
rc=$?
[ $rc -ne 0 ] && grep -q 'not allowed' <<<"$out" && pass "provider refuses any account but Floci's 000000000000" ||
  bad "plan in account 111111111111 was not refused (exit $rc)"

leaked=""
for v in $SECRETS; do grep -qF -- "${!v}" "$STATE" && leaked="$leaked $v"; done
[ -z "$leaked" ] && pass "no secret value in terraform.tfstate (write-only value_wo)" || bad "secret values in state:$leaked"

echo "== SSM"
params=$(aws ssm get-parameters-by-path --path /cop/local --with-decryption)
wrong=""
for v in $SECRETS; do
  p=$(jq -c --arg n "/cop/local/$v" '.Parameters[] | select(.Name == $n)' <<<"$params")
  [ "$(jq -r .Type <<<"$p")" = SecureString ] && [ "$(jq -r .Value <<<"$p")" = "${!v}" ] || wrong="$wrong $v"
done
[ -z "$wrong" ] && pass "9 SecureString parameters under /cop/local hold the .env values" || bad "missing, not SecureString or wrong value:$wrong"

echo "== S3"
B=cop-local-backups-000000000000
[ "$(aws s3api get-bucket-versioning --bucket $B | jq -r .Status)" = Enabled ] && pass "versioning enabled" || bad "versioning not enabled"
[ "$(aws s3api get-bucket-encryption --bucket $B | jq -r '.ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm')" = AES256 ] &&
  pass "default encryption AES256" || bad "default encryption not AES256"
[ "$(aws s3api get-public-access-block --bucket $B | jq '[.PublicAccessBlockConfiguration[]] | all')" = true ] &&
  pass "all four public access blocks on" || bad "public access block incomplete"
[ "$(aws s3api get-bucket-ownership-controls --bucket $B | jq -r '.OwnershipControls.Rules[0].ObjectOwnership')" = BucketOwnerEnforced ] &&
  pass "ACLs disabled (BucketOwnerEnforced)" || bad "object ownership not BucketOwnerEnforced"
policy=$(aws s3api get-bucket-policy --bucket $B | jq -r .Policy)
[ "$(jq -r '.Statement[] | select(.Effect == "Deny") | .Condition.Bool["aws:SecureTransport"]' <<<"$policy")" = false ] &&
  pass "policy denies non-TLS requests (stored; Floci doesn't enforce it)" || bad "no TLS-only deny statement"
[ "$(aws s3api get-bucket-lifecycle-configuration --bucket $B | jq '.Rules[0].NoncurrentVersionExpiration.NoncurrentDays')" = 30 ] &&
  pass "old versions expire after 30 days" || bad "noncurrent version expiry missing"

echo "== ECR"
repos=$(aws ecr describe-repositories --repository-names cop/ecommerce-api cop/incident-api)
[ "$(jq '[.repositories[] | select(.imageTagMutability == "IMMUTABLE" and .imageScanningConfiguration.scanOnPush)] | length' <<<"$repos")" = 2 ] &&
  pass "2 repositories, immutable tags, scan on push" || bad "repositories missing or mutable/unscanned"
rules=$(aws ecr get-lifecycle-policy --repository-name cop/ecommerce-api | jq -r .lifecyclePolicyText | jq '.rules | length')
[ "$rules" = 2 ] && pass "lifecycle policy: expire untagged, keep newest 10" || bad "lifecycle policy has ${rules:-no} rules"

echo "== IAM"
[ "$(aws iam get-instance-profile --instance-profile-name cop-local | jq -r '.InstanceProfile.Roles[0].RoleName')" = cop-local ] &&
  pass "instance profile carries the host role" || bad "instance profile has no host role"
# Managed policies can't be scoped to our paths (AmazonSSMManagedInstanceCore grants
# ssm:GetParameter on "*"), so the host role gets exactly one inline policy and nothing else.
attached=$(aws iam list-attached-role-policies --role-name cop-local | jq '.AttachedPolicies | length')
inline=$(aws iam list-role-policies --role-name cop-local | jq -c .PolicyNames)
[ "$attached" = 0 ] && [ "$inline" = '["host"]' ] && pass "host role: only its own inline policy, no managed policies" ||
  bad "host role: $attached managed policies, inline $inline"
doc=$(aws iam get-role-policy --role-name cop-local --policy-name host | jq -c .PolicyDocument)
# ssm:Get* only on /cop/local; "*" only where the action has no resource-level permissions.
jq -e '[.Statement[] | select([.Action] | flatten | any(startswith("ssm:Get"))) | [.Resource] | flatten | all(contains(":parameter/cop/local"))] | length > 0 and all' <<<"$doc" >/dev/null &&
  pass "secrets readable only under /cop/local" || bad "ssm:Get* reaches beyond /cop/local"
wild=$(jq -r '[.Statement[] | select([.Resource] | flatten | index("*")) | .Sid] | sort | join(",")' <<<"$doc")
[ "$wild" = EcrLogin,SessionManager ] && pass "\"*\" resources only for ECR login and Session Manager" || bad "wildcard resources in: $wild"
# ec2messages:DeleteMessage is exempt: it only dequeues the SSM agent's own delivered command.
risky=$(jq -r '[.Statement[].Action] | flatten | map(select(test("\\*|Delete") and . != "ec2messages:DeleteMessage")) | join(",")' <<<"$doc")
[ -z "$risky" ] && pass "no wildcard or delete actions (host cannot erase backups)" || bad "risky actions: $risky"
# The boundary caps the role, so a deploy key that may create roles can't mint an admin one.
BARN=arn:aws:iam::000000000000:policy/cop-local-host-boundary
got=$(aws iam get-role --role-name cop-local | jq -r '.Role.PermissionsBoundary.PermissionsBoundaryArn')
[ "$got" = "$BARN" ] && pass "host role carries the permissions boundary" || bad "host role boundary: $got"
# Floci doesn't enforce boundaries: an action the role uses but the boundary lacks would
# only fail on real AWS. Compare against the boundary as stored, not the file.
ver=$(aws iam get-policy --policy-arn "$BARN" | jq -r .Policy.DefaultVersionId)
bdoc=$(aws iam get-policy-version --policy-arn "$BARN" --version-id "$ver" | jq -r .PolicyVersion.Document)
outside=$(jq -rn --argjson p "$doc" --argjson b "$bdoc" '([$p.Statement[].Action] | flatten) - ([$b.Statement[].Action] | flatten) | join(",")')
[ -z "$outside" ] && pass "every host action is inside the boundary" || bad "host actions outside the boundary: ${outside:-unreadable boundary}"

echo "== Network and host"
sg=$(aws ec2 describe-security-groups --filters Name=group-name,Values=cop-local-host | jq -c '.SecurityGroups[0]')
[ "$(jq '.IpPermissions | length' <<<"$sg")" = 0 ] && pass "host security group: no inbound rules" || bad "host security group has inbound rules"
egress=$(jq -c '[.IpPermissionsEgress[] | "\(.IpProtocol) \(.FromPort)-\(.ToPort) \([.IpRanges[].CidrIp, .Ipv6Ranges[].CidrIpv6] | join(","))"] | sort' <<<"$sg")
[ "$egress" = '["tcp 443-443 0.0.0.0/0","tcp 587-587 0.0.0.0/0"]' ] && pass "egress only tcp 443 and 587" || bad "egress: $egress"
vpc=$(jq -r .VpcId <<<"$sg")
dsg=$(aws ec2 describe-security-groups --filters Name=vpc-id,Values="$vpc" Name=group-name,Values=default | jq '.SecurityGroups[0] | (.IpPermissions + .IpPermissionsEgress) | length')
[ "$dsg" = 0 ] && pass "default security group has no rules" || bad "default security group has $dsg rules"
inst=$(aws ec2 describe-instances --filters Name=tag:Name,Values=cop-local Name=instance-state-name,Values=running | jq -c '[.Reservations[].Instances[]]')
[ "$(jq length <<<"$inst")" = 1 ] && pass "one host instance running (metadata only on Floci)" || bad "$(jq length <<<"$inst") running host instances, want 1"
# Hop limit 1: containers on the host must not reach IMDS (the role's credentials).
[ "$(jq -r '.[0] | "\(.InstanceType) \(.MetadataOptions.HttpTokens) \(.MetadataOptions.HttpPutResponseHopLimit) \(.IamInstanceProfile.Arn | split("/")[1])"' <<<"$inst")" = "t4g.small required 1 cop-local" ] &&
  pass "t4g.small, IMDSv2 required, hop limit 1, host profile" || bad "instance: $(jq -c '.[0] | [.InstanceType, .MetadataOptions.HttpTokens, .MetadataOptions.HttpPutResponseHopLimit, .IamInstanceProfile.Arn]' <<<"$inst")"
vol=$(jq -r '.[0].BlockDeviceMappings[0].Ebs.VolumeId' <<<"$inst")
[ "$(aws ec2 describe-volumes --volume-ids "$vol" | jq -r '.Volumes[0].Encrypted')" = true ] && pass "root volume encrypted" || bad "root volume not encrypted"

finish
