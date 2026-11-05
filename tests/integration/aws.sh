#!/usr/bin/env bash
# Integration checks against the real AWS deployment (make aws-test). Not part of
# `make test`: needs make aws-apply + make aws-deploy, and talks to real AWS.
# Read-only, except calls that must be DENIED by IAM (they would create nothing useful;
# an unexpected success is cleaned up). This is the IAM enforcement Floci can't show.
set -uo pipefail
source "$(dirname "$0")/lib.sh"

A=scripts/aws.sh
awsr() { docker compose --progress quiet run --rm -T aws-real "$@" --output json; }
TFA="docker compose --progress quiet run --rm -T terraform-aws -chdir=infrastructure/terraform/environments/aws"
# denied <output>: the call failed with an IAM authorization error.
denied() { grep -qE 'AccessDenied|not authorized|UnauthorizedOperation' <<<"$1"; }

echo "== Account and Terraform"
if $A check 2>/dev/null; then pass "profile cop is account $AWS_ACCOUNT_ID"; else bad "profile cop is not account $AWS_ACCOUNT_ID"; finish; fi
$TFA plan -detailed-exitcode -input=false -no-color >/dev/null 2>&1
rc=$?
[ $rc -eq 0 ] && pass "second plan is empty (no drift)" || bad "plan exit $rc (2 = drift)"

echo "== Host"
id=$($A instance 2>/dev/null) && pass "one running cop-aws instance ($id)" || { bad "no single running cop-aws instance"; finish; }
ping=$(awsr ssm describe-instance-information --filters "Key=InstanceIds,Values=$id" | jq -r '.InstanceInformationList[0].PingStatus')
[ "$ping" = Online ] && pass "SSM agent online" || bad "SSM agent: $ping"
sg=$(awsr ec2 describe-security-groups --filters Name=group-name,Values=cop-aws-host | jq '.SecurityGroups[0].IpPermissions | length')
[ "$sg" = 0 ] && pass "no inbound rules: UIs only through the SSM tunnel" || bad "host security group has $sg inbound rules"

# One Run Command gathers the on-host view; each line is "<key> <value>".
remote=$(cat <<'EOF'
cd "$(ls -1dt /opt/cop/releases/*/ | head -1)"
dc() { docker compose -f docker-compose.yml -f docker-compose.aws.yml "$@"; }
echo "release $(basename "$PWD")"
echo "unhealthy $(dc ps -a --format '{{.Service}} {{.State}} {{.Health}}' | awk '$1 !~ /migrate$/ && ($2 != "running" || ($3 != "" && $3 != "healthy")) {printf "%s,", $1}')"
echo "migrations $(dc ps -a --format '{{.Service}} {{.State}} {{.ExitCode}}' | awk '$1 ~ /migrate$/ {printf "%s=%s/%s,", $1, $2, $3}')"
echo "services $(dc ps --format '{{.Service}}' | wc -l)"
down=""
for u in 9090/-/ready 9093/-/ready 3100/ready 12345/-/ready 3000/api/health 8080/health 8081/health 8025/readyz; do
  curl -fsS -o /dev/null -m 5 "http://127.0.0.1:$u" || down="$down$u,"
done
echo "down $down"
q() { curl -fsS -m 10 -G http://127.0.0.1:9090/api/v1/query --data-urlencode "query=$1" | jq -r '.data.result[0].value[1] // "none"'; }
echo "up $(q 'count(up == 1)')/$(q 'count(up)')"
echo "env_aws $(q 'count(up{environment="aws"})')"
echo "env_local $(q 'count(up{environment="local"})')"
echo "loki_aws $(curl -fsS -m 10 -G http://127.0.0.1:3100/loki/api/v1/query --data-urlencode 'query=sum(count_over_time({environment="aws", container=~"cop-.+"}[10m]))' | jq -r '.data.result[0].value[1] // "none"')"
# Containers must not reach IMDS (hop limit 1), or any of them could take the role's credentials.
# Control: the same request from the host must succeed, so a broken probe can't pass.
imds() { curl -s -m 3 -o /dev/null -w '%{http_code}' -X PUT -H "X-aws-ec2-metadata-token-ttl-seconds: 60" http://169.254.169.254/latest/api/token; }
echo "imds_host $(imds)"
echo "imds_container $(docker exec cop-grafana-1 curl -s -m 3 -o /dev/null -w '%{http_code}' -X PUT -H "X-aws-ec2-metadata-token-ttl-seconds: 60" http://169.254.169.254/latest/api/token; echo " exit=$?")"
# Real IAM enforcement: the host role may read only /cop/aws and never delete objects.
r=$(aws --region ap-south-1 ssm get-parameter --name /cop/local/POSTGRES_PASSWORD 2>&1 >/dev/null | tr '\n' ' '); [ -n "$r" ] || r=ALLOWED
echo "iam_ssm_outside $r" | head -c 200; echo
r=$(aws --region ap-south-1 s3api delete-object --bucket "$BUCKET" --key releases/iam-check 2>&1 >/dev/null | tr '\n' ' '); [ -n "$r" ] || r=ALLOWED
echo "iam_s3_delete $r" | head -c 200; echo
EOF
)
out=$($A run "BUCKET=cop-aws-backups-$AWS_ACCOUNT_ID
$remote" 2>&1)
val() { sed -n "s/^$1 //p" <<<"$out" | head -1; }
echo "  (release $(val release))"
[ -z "$(val unhealthy)" ] && [ "$(val services)" -ge 15 ] 2>/dev/null &&
  pass "$(val services) services running, all healthchecks healthy" || bad "services: $(val services), not running/healthy: $(val unhealthy)"
[ "$(val migrations)" = "ecommerce-migrate=exited/0,incident-migrate=exited/0," ] && pass "both migrate jobs exited 0" || bad "migrations: $(val migrations)"
[ -z "$(val down)" ] && pass "every endpoint ready on the host" || bad "not ready: $(val down)"
up=$(val up)
[ "${up%/*}" = "${up#*/}" ] && [ "${up%/*}" -gt 0 ] 2>/dev/null && pass "Prometheus: all $up targets up" || bad "Prometheus targets up: $up"
[ "$(val env_aws)" -gt 0 ] 2>/dev/null && [ "$(val env_local)" = none ] && pass "target series labelled environment=aws ($(val env_aws)), none local" ||
  bad "environment labels: aws=$(val env_aws) local=$(val env_local)"
[ "$(val loki_aws)" -gt 0 ] 2>/dev/null && pass "Loki has cop-* container logs with environment=aws ($(val loki_aws) lines/10m)" || bad "no aws logs in Loki"
# Hop limit 1 drops the reply: curl times out (exit 28) inside the container, 200 on the host.
[ "$(val imds_host)" = 200 ] && [ "$(val imds_container)" = "000 exit=28" ] &&
  pass "containers get no IMDS token, the host does (role credentials stay on the host)" ||
  bad "IMDS: host $(val imds_host), container $(val imds_container) (want 200 / 000 exit=28)"
denied "$(val iam_ssm_outside)" && pass "host role denied a secret outside /cop/aws (real IAM)" || bad "host read outside /cop/aws: $(val iam_ssm_outside)"
denied "$(val iam_s3_delete)" && pass "host role denied s3:DeleteObject on the backups bucket" || bad "host s3 delete: $(val iam_s3_delete)"

echo "== Deploy credentials"
# The deployer may create cop-* roles only with cop-host-boundary attached.
trust='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
r=$(awsr iam create-role --role-name cop-iam-check --assume-role-policy-document "$trust" 2>&1)
if denied "$r"; then pass "deployer denied creating a role without the boundary (no admin-role escalation)"
else
  bad "deployer created a role without the boundary: $(head -c 200 <<<"$r")"
  awsr iam delete-role --role-name cop-iam-check >/dev/null 2>&1
fi

finish
