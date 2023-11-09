#!/bin/bash

set -euo pipefail
set -x
test_source_file=.current-test
if [[ -f $test_source_file ]]; then
  source $test_source_file
fi

db_image=${DB_IMAGE:-postgres}
engine=${DB_ENGINE:-postgres}
request_num=${REQUEST_NUM:-1}
new_password=${NEW_PASSWORD:-newpassword}

master_secret_name=${MASTER_SECRET_NAME:-}
master_secret_arn=${MASTER_SECRET_ARN:-}
user_secret_name=${USER_SECRET_NAME:-}
user_secret_arn=${USER_SECRET_ARN:-}

username=user1
host=host.docker.internal
port=5432
dbname=postgres

# Put a new secrert version 
client_request_token=request-$request_num-3bfd-6413-b3ul-7502bdla2941

user_secret_string_single_quote="{'engine': '$engine', 'host': '$host', 'port': $port, 'dbname': '$dbname', 'username': '$username', 'password': '$new_password', 'masterarn': '$master_secret_arn'}"
user_secret_string=$(echo $user_secret_string_single_quote | tr "'" '"')

# This initiates the rotation 
aws secretsmanager put-secret-value \
  --secret-id $user_secret_name \
  --client-request-token $client_request_token \
  --secret-string "$user_secret_string" \
  --version-stages AWSPENDING

sleep 2

setSecret_event_single_quote="{'ClientRequestToken': '$client_request_token', 'SecretId': '$user_secret_arn', 'Step': 'setSecret'}"
setSecret_event=$(echo $setSecret_event_single_quote | tr "'" '"')

# This invokes the lambda that would have been triggered by the `put-secret-value` command above
status_code=$(curl "http://localhost:9000/2015-03-31/functions/function/invocations" -d "$setSecret_event" -o /dev/null -w "%{http_code}")
echo "lambda invocation status code=$status_code"

if [[ "$status_code" != "200" ]]; then
  exit 1
fi

# Test with the new password
export PGPASSWORD="$NEW_PASSWORD"

# Attempt to log into the database with the 
docker run --rm --env PGPASSWORD \
  --network host --add-host=host.docker.internal:host-gateway \
  --entrypoint psql $db_image \
  -h host.docker.internal -p $port -U $username -d $dbname -c "SELECT 1"

previous_id=$(aws secretsmanager describe-secret --secret-id $user_secret_name | grep -B1 AWSPREVIOUS | grep -v AWSPREVIOUS | cut -d '"' -f 2 || echo "")
current_id=$(aws secretsmanager describe-secret --secret-id $user_secret_name | grep -B1 AWSCURRENT | grep -v AWSCURRENT | cut -d '"' -f 2)
pending_id=$(aws secretsmanager describe-secret --secret-id $user_secret_name | grep -B1 AWSPENDING | grep -v AWSPENDING | cut -d '"' -f 2)

remove_from_previous_id_arg="--remove-from-version-id $previous_id"

if [[ -z "$previous_id" ]]; then
  remove_from_previous_id_arg=""
fi

aws secretsmanager update-secret-version-stage \
  --secret-id $user_secret_name \
  --version-stage AWSPREVIOUS \
  --move-to-version-id $current_id $remove_from_previous_id_arg

aws secretsmanager update-secret-version-stage \
  --secret-id $user_secret_name \
  --version-stage AWSCURRENT \
  --move-to-version-id $pending_id \
  --remove-from-version-id $current_id

# Test with the current version returned from the secret (to confirm mock rotation above worked)
export PGPASSWORD="$(aws secretsmanager get-secret-value --secret-id $user_secret_name | jq -r .SecretString | jq -r .password)"

# Attempt to log into the database with the 
docker run --rm --env PGPASSWORD \
  --network host --add-host=host.docker.internal:host-gateway \
  --entrypoint psql $db_image \
  -h host.docker.internal -p $port -U $username -d $dbname -c "SELECT 1"

aws secretsmanager describe-secret --secret-id $user_secret_name
