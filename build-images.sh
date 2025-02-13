#!/bin/bash

set -euo pipefail

default_not_pushed_repo=ignored-not-pushed/some-repo

registry_repo="${1:-$default_not_pushed_repo}"
registry_hostname=$(cut -d/ -f1 <<< $registry_repo)
repo_name=$(cut -d/ -f2- <<< $registry_repo)

for row in $(cat images.json | jq -r '.folders[] | @base64'); do
  _jq() {
    echo ${row} | base64 --decode | jq -r ${1}
  }

  function_name=$(_jq '.function_name')
  folder=$(_jq '.folder')
  system_packages=$(_jq '.install_system_packages') # returns 'null' if key is not present
  python_packages=$(_jq '.python_packages')         # returns 'null' if key is not present
  tag=$(_jq '.tag')
  
  if [[ "$python_packages" != "null" ]]; then
    echo $python_packages | xargs -n1 > $folder/requirements.txt
  fi

  # This will set the entrypoint for the lambda container image
  echo "web: python -m awslambdaric $function_name" > $folder/Procfile

  pack_publish_arg="--publish"

  if [[ "$registry_repo" == "$default_not_pushed_repo" ]] ; then
    pack_publish_arg=""
  fi

  pack build "$registry_repo:$tag" \
    --network host \
    --builder paketobuildpacks/builder-jammy-full \
    $pack_publish_arg --path $folder

  if [[ -f $folder/requirements.txt ]]; then
    rm $folder/requirements.txt
  fi
  if [[ -f $folder/Procfile ]]; then
    rm $folder/Procfile
  fi
  
done
