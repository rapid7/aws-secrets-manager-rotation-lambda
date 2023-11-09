#!/bin/bash

# This integration script makes calls to aws and therefore the following environment variables must be set.
# SECRETS_MANAGER_ENDPOINT AWS_DEFAULT_REGION AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN

set -euo pipefail

for row in $(cat images.json | jq -r '.folders[] | @base64'); do
  _jq() {
    echo ${row} | base64 --decode | jq -r ${1}
  }

  engine=$(_jq '.engine')
  db_image=$(_jq '.db_image')
  function_name=$(_jq '.function_name')
  folder=$(_jq '.folder')
  system_packages=$(_jq '.install_system_packages') # returns 'null' if key is not present
  python_packages=$(_jq '.python_packages')         # returns 'null' if key is not present
  tag=$(_jq '.tag')

  image_uri="${1}:$tag"

  if [[ ! -d ~/.aws-lambda-rie ]]; then
    mkdir ~/.aws-lambda-rie
    curl -Lo ~/.aws-lambda-rie/aws-lambda-rie https://github.com/aws/aws-lambda-runtime-interface-emulator/releases/latest/download/aws-lambda-rie
    chmod +x ~/.aws-lambda-rie/aws-lambda-rie
  fi

  username=user1
  host=host.docker.internal
  port=5432
  dbname=postgres

  image_uri_base64=$(echo $image_uri | base64)
  test_id="${image_uri_base64:0:8}-$(date +%s)"

  master_secret_name="aws-secrets-manager-rotation-lambda-test-master-$test_id"
  master_secret_string_single_quote="{'username': 'postgres', 'password': 'postgres'}"
  master_secret_string=$(echo $master_secret_string_single_quote | tr "'" '"')

  master_secret_arn=${MASTER_SECRET_ARN:-}

  test_source_file=.current-test
  if [[ -f $test_source_file ]]; then
    rm $test_source_file
  fi

  if [[ -z "$master_secret_arn" ]]; then
    master_secret_arn=$(aws secretsmanager create-secret --name $master_secret_name --secret-string "$master_secret_string" | jq -r .ARN)
    echo "export MASTER_SECRET_NAME=$master_secret_name" | tee -a $test_source_file
    echo "export MASTER_SECRET_ARN=$master_secret_arn" | tee -a $test_source_file
  fi

  client_request_token=request-0-3bfd-6413-b3ul-7502bdla2941

  user_secret_name="aws-secrets-manager-rotation-lambda-test-user-$test_id"
  user_secret_string_single_quote="{'engine': '$engine', 'host': '$host', 'port': $port, 'dbname': '$dbname', 'username': '$username', 'password': 'changeme', 'masterarn': '$master_secret_arn'}"
  user_secret_string=$(echo $user_secret_string_single_quote | tr "'" '"')

  user_secret_arn=${USER_SECRET_ARN:-}

  if [[ -z "$user_secret_arn" ]]; then
    user_secret_arn=$(aws secretsmanager create-secret --name $user_secret_name --client-request-token $client_request_token --secret-string "$user_secret_string" | jq -r .ARN)
    echo "export USER_SECRET_NAME=$user_secret_name" | tee -a $test_source_file
    echo "export USER_SECRET_ARN=$user_secret_arn" | tee -a $test_source_file
  fi

  echo "export DB_IMAGE=$db_image" | tee -a $test_source_file
  echo "export DB_ENGINE=$engine" | tee -a $test_source_file

  # Run the lambda interface emulator from the lambda function image
  docker container inspect aws-lambda-rie > /dev/null 2>&1 || \
    docker run -q -d --rm -p 9000:8080 \
      --add-host=host.docker.internal:host-gateway \
      --name aws-lambda-rie \
      --env SECRETS_MANAGER_ENDPOINT \
      --env AWS_DEFAULT_REGION \
      --env AWS_ACCESS_KEY_ID \
      --env AWS_SECRET_ACCESS_KEY \
      --env AWS_SESSION_TOKEN \
      -v ./$folder:/workspace \
      -v ~/.aws-lambda-rie:/aws-lambda \
      --entrypoint launcher \
      $image_uri \
      /aws-lambda/aws-lambda-rie python -m awslambdaric $function_name \
      > /dev/null 2>&1

  docker container inspect aws-lambda-rie-test-db > /dev/null 2>&1 || \
    docker run -q -d --rm -p 5432:5432 \
      --name aws-lambda-rie-test-db \
      --env POSTGRES_USER=postgres \
      --env POSTGRES_PASSWORD=postgres \
      $db_image \
      > /dev/null 2>&1
  
  sleep 4

  source $test_source_file

  aws secretsmanager describe-secret --secret-id $user_secret_name

  # Set the initial password and verify it works
  NEW_PASSWORD=newPassword1 REQUEST_NUM=1 ./test-rotate.sh
  
  # Change the password and verify it work
  NEW_PASSWORD=newPassword2 REQUEST_NUM=2 ./test-rotate.sh

  # Change the password and verify it work
  NEW_PASSWORD=newPassword3 REQUEST_NUM=3 ./test-rotate.sh

  docker kill aws-lambda-rie && docker kill aws-lambda-rie-test-db

  aws secretsmanager delete-secret --secret-id $master_secret_name --force-delete-without-recovery
  aws secretsmanager delete-secret --secret-id $user_secret_name --force-delete-without-recovery

  rm $test_source_file  

  sleep 1
done