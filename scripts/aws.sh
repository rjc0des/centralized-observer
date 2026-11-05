#!/usr/bin/env bash
# Real-AWS operations from the Mac (make aws-*). Every AWS call runs in the aws-real
# container (profile "cop", ~/.aws read-only); nothing here reads the credentials itself.
#   scripts/aws.sh check            account guard: profile must be AWS_ACCOUNT_ID
#   scripts/aws.sh deploy           build + push images, upload the release, run it on the host
#   scripts/aws.sh tunnel           SSM port-forward Grafana/Prometheus/Alertmanager to the Mac
#   scripts/aws.sh run '<script>'   run a shell script on the host as root (Run Command)
set -euo pipefail
cd "$(dirname "$0")/.."

die() { echo "aws.sh: $*" >&2; exit 1; }
REGION=$(sed -n 's/^AWS_REGION=//p' .env | tail -1)
REGION=${REGION:-ap-south-1}
ACCOUNT=$(sed -n 's/^AWS_ACCOUNT_ID=//p' .env | tail -1)
[[ $ACCOUNT =~ ^[0-9]{12}$ ]] || die "set AWS_ACCOUNT_ID (12 digits) in .env"
NAME=cop-aws
BUCKET=$NAME-backups-$ACCOUNT
REGISTRY=$ACCOUNT.dkr.ecr.$REGION.amazonaws.com

aws() { docker compose --progress quiet run --rm -T aws-real "$@"; }

check() {
  local acct
  acct=$(aws sts get-caller-identity --query Account --output text)
  [ "$acct" = "$ACCOUNT" ] || die "profile cop is account '$acct', expected $ACCOUNT"
  echo "aws: account $acct, $REGION" >&2
}

instance() {
  local ids
  ids=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=$NAME" Name=instance-state-name,Values=running \
    --query 'Reservations[].Instances[].InstanceId' --output text)
  set -- $ids
  [ $# -eq 1 ] || die "want one running $NAME instance, found: '$ids'"
  echo "$1"
}

# Run Command: prints the script's stdout (stderr to stderr), exits with its status.
# ponytail: output is truncated by SSM at 24,000 characters; ship logs to S3 if that bites.
run() {
  local id cid out st
  id=$(instance)
  cid=$(aws ssm send-command --instance-ids "$id" --document-name AWS-RunShellScript \
    --parameters "$(jq -nc --arg c "$1" '{commands: [$c]}')" \
    --query Command.CommandId --output text)
  for _ in $(seq 1 180); do
    sleep 5
    out=$(aws ssm get-command-invocation --command-id "$cid" --instance-id "$id" --output json 2>/dev/null) || continue
    st=$(jq -r .Status <<<"$out")
    case $st in Pending | InProgress | Delayed) continue ;; esac
    jq -r .StandardOutputContent <<<"$out"
    jq -r .StandardErrorContent <<<"$out" >&2
    [ "$st" = Success ] && return 0
    echo "aws.sh: command $cid: $st" >&2
    return 1
  done
  die "command $cid still running after 15 minutes"
}

deploy() {
  check
  # Images and the release share one immutable tag: the commit, marked if the tree is dirty.
  local tag app
  tag=$(git rev-parse --short=12 HEAD)
  [ -z "$(git status --porcelain)" ] || tag=$tag-dirty-$(date +%Y%m%d%H%M%S)
  echo "== release $tag"
  docker compose build ecommerce-api incident-api
  aws ecr get-login-password | docker login --username AWS --password-stdin "$REGISTRY" >/dev/null
  trap 'docker logout "$REGISTRY" >/dev/null' EXIT
  for app in ecommerce-api incident-api; do
    if aws ecr describe-images --repository-name "cop/$app" --image-ids "imageTag=$tag" >/dev/null 2>&1; then
      echo "cop/$app:$tag already in ECR"
    else
      docker tag "cop/$app:dev" "$REGISTRY/cop/$app:$tag"
      docker push -q "$REGISTRY/cop/$app:$tag"
    fi
  done
  # Tracked and untracked-but-not-ignored files: .env, state and keys stay out.
  # Tracked files deleted but not yet committed are skipped (tar would fail on them).
  git ls-files -z -co --exclude-standard |
    while IFS= read -r -d '' f; do [ -e "$f" ] && printf '%s\0' "$f"; done |
    COPYFILE_DISABLE=1 tar --no-xattrs --null -T - -czf - |
    aws s3 cp - "s3://$BUCKET/releases/$tag.tar.gz"
  echo "== deploying on $(instance)"
  run "set -eu
d=/opt/cop/releases/$tag
mkdir -p \$d
aws --region $REGION s3 cp s3://$BUCKET/releases/$tag.tar.gz - | tar -xz -C \$d
exec \$d/infrastructure/host/deploy.sh $tag"
}

tunnel() {
  check
  local id
  id=$(instance)
  echo "Grafana http://127.0.0.1:13000  Prometheus http://127.0.0.1:19090  Alertmanager http://127.0.0.1:19093  (Ctrl-C closes)"
  docker compose --progress quiet run --rm --entrypoint sh aws-real -c "
    for p in 3000:13000 9090:19090 9093:19093; do
      aws ssm start-session --target $id --document-name AWS-StartPortForwardingSession \
        --parameters portNumber=\${p%:*},localPortNumber=\${p#*:} >/dev/null &
    done
    wait"
}

case ${1:-} in
  check) check ;;
  instance) instance ;;
  deploy) deploy ;;
  tunnel) tunnel ;;
  run) [ $# -eq 2 ] || die "usage: $0 run '<script>'"; run "$2" ;;
  *) die "usage: $0 check|instance|deploy|tunnel|run '<script>'" ;;
esac
