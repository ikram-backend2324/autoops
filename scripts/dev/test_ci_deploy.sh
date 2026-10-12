#!/usr/bin/env bash
# Integration test of the server-side deploy path used by GitHub Actions:
#   ci-deploy (forced command) + autoops-compose, rendered from the Ansible templates.
# Runs inside the tools image against the local Docker daemon, with a throw-away app "cidemo":
#   1. v1 running            -> deploy v2       => RESULT=ok
#   2. broken release        -> deploy broken   => automatic rollback to v2
#   3. tag that does not exist                  => automatic rollback to v2
#   4. deploy v1, then `rollback`               => back on v2
# Needs images autoops/sample-app:{v1,v2,broken} (scripts/dev/test_ci_deploy_images.sh).
set -euo pipefail
cd "$(dirname "$0")/../.."
APP=cidemo
ROOT=/opt/autoops
DIR=$ROOT/apps/$APP
pass=0 fail=0
check() {  # check NAME EXPECTED_REGEX OUTPUT
  if grep -Eq "$2" <<< "$3"; then echo "✔ $1"; pass=$((pass + 1)); else echo "✖ $1 (expected /$2/)"; echo "$3" | tail -5; fail=$((fail + 1)); fi
}
deploy() { SSH_ORIGINAL_COMMAND="$*" CI_HEALTH_TIMEOUT=${CI_HEALTH_TIMEOUT:-60} "$ROOT/bin/ci-deploy" 2>&1 || true; }
current_tag() { sed -n 's/^APP_TAG=//p' "$DIR/tag.env"; }

mkdir -p "$ROOT/bin" "$DIR"
for t in ci-deploy autoops-compose; do
  ansible localhost -c local -m template -a "src=ansible/roles/app/templates/$t.sh.j2 dest=$ROOT/bin/$t mode=0755" \
    -e autoops_root=$ROOT -e app_base_dir=$ROOT/apps -e deploy_user=deploy >/dev/null
done
cp stacks/app/compose.yml "$DIR/compose.yml"
cat > "$DIR/.env" <<EOF
APP_NAME=$APP
APP_IMAGE=autoops/sample-app
APP_DOMAIN=$APP.localhost
APP_ENV_FILE=.env
DJANGO_SECRET_KEY=ci-deploy-test-secret-key-0123456789
POSTGRES_PASSWORD=ci-deploy-test-password
GUNICORN_WORKERS=1
EOF
printf 'APP_TAG=v1\nAPP_PREVIOUS_TAG=\n' > "$DIR/tag.env"
trap '"$ROOT/bin/autoops-compose" $APP down -v --remove-orphans >/dev/null 2>&1 || true' EXIT

echo "starting $APP:v1 ..."
"$ROOT/bin/autoops-compose" $APP up -d --pull missing >/dev/null 2>&1
for _ in $(seq 1 30); do "$ROOT/bin/autoops-compose" $APP health >/dev/null 2>&1 && break; sleep 3; done

out=$(deploy deploy $APP v2)
check "deploy v2 succeeds" "RESULT=ok TAG=v2 PREVIOUS=v1" "$out"
check "tag.env now v2" "^v2$" "$(current_tag)"

out=$(CI_HEALTH_TIMEOUT=45 deploy deploy $APP broken)
check "broken release is rolled back" "RESULT=rolled_back TAG=v2 FAILED=broken" "$out"
check "tag.env back on v2" "^v2$" "$(current_tag)"

out=$(CI_HEALTH_TIMEOUT=30 deploy deploy $APP no-such-tag)
check "unknown tag is rolled back" "RESULT=rolled_back TAG=v2 FAILED=no-such-tag" "$out"
check "tag.env still v2" "^v2$" "$(current_tag)"

out=$(deploy deploy $APP v1)
check "deploy v1" "RESULT=ok TAG=v1 PREVIOUS=v2" "$out"
out=$(deploy rollback $APP)
check "manual rollback returns to v2" "RESULT=ok TAG=v2" "$out"

out=$(deploy "rm -rf /" )
check "arbitrary commands are refused" "usage: deploy APP TAG" "$out"
out=$(deploy deploy "../etc" v1)
check "path traversal in app name is refused" "usage: deploy APP TAG" "$out"
out=$(deploy deploy $APP 'v1;id')
check "shell metacharacters in tag are refused" "invalid tag" "$out"

echo
echo "ci-deploy integration test: $pass passed, $fail failed"
(( fail == 0 ))
