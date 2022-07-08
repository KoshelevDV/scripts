#!/usr/bin/env bash

set -Eueo pipefail
trap cleanup SIGINT SIGTERM ERR EXIT

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)

usage() {
  cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") -h <gitlab_host> -g <group_id> -t <token> -b <dev,stage,...> [-f <file_path>]

Script use private token to access Gitlab API to get list of project in group. 
SSH key is used to pull\push to repository (should specify ssh key path for ci-cd).
By default script recreate branches for all projects in group if file with projects isn't specified.

Available options:

    --help      Print this help and exit
-v, --verbose   Print script debug info
-h, --host      Gitlab host
-g, --group     Group id
-t, --token     Private or deploy token
-b, --branch    Branch to recreate
-f, --file      File with list of projects
-r, --right     flag - diff <origin/branch>...main
-l, --left      flag - diff main...<origin/branch>
EOF
  exit
}

cleanup() {
  trap - SIGINT SIGTERM ERR EXIT
  rm -rf $script_dir/.temp
}

setup_colors() {
  if [[ -t 2 ]] && [[ -z "${NO_COLOR-}" ]] && [[ "${TERM-}" != "dumb" ]]; then
    NOFORMAT='\033[0m' RED='\033[0;31m' GREEN='\033[0;32m' ORANGE='\033[0;33m' BLUE='\033[0;34m' PURPLE='\033[0;35m' CYAN='\033[0;36m' YELLOW='\033[1;33m'
  else
    NOFORMAT='' RED='' GREEN='' ORANGE='' BLUE='' PURPLE='' CYAN='' YELLOW=''
  fi
}

msg() {
  echo >&2 -e "${1-}"
}

die() {
  local msg=$1
  local code=${2-1} # default exit status 1
  msg "$msg"
  exit "$code"
}

parse_params() {
  while :; do
    case "${1-}" in
    --help) usage ;;
    -v | --verbose) set -x ;;
    --no-color) NO_COLOR=1 ;;
    -h | --host)
    host="${2-}"
      shift
      ;;
    -g | --group)
    group="${2-}"
      shift
      ;;
    -t | --token)
    token="${2-}"
      shift
      ;;
    -f | --file)
    readarray -t projects_to_recreate < "${2-}"
      shift
      ;;
    -b | branch)
    IFS=',' read -r -a branches <<< "${2-}"
      shift
      ;;
    -?*) die "Unknown option: $1" ;;
    *) break ;;
    esac
    shift
  done

  args=("$@")

  # check required params and arguments
  [[ -z "${host-}" ]]  && die "Missing required parameter: host" 
  [[ -z "${group-}" ]] && die "Missing required parameter: group"
  [[ -z "${token-}" ]] && die "Missing required parameter: token"
  # [[ ${#args[@]} -eq 0 ]] && die "Missing script arguments"

  return 0
}

parse_params "$@"
setup_colors

# script logic here
declare -A recraeted
for branch in "${branches[@]}"; do
  recraeted[$branch]+=0
done
broken=()

check_and_recreate() {
  echo "> [$project_name] $project_web_url"

  git clone --quiet $project > /dev/null

  status=$?
  if [ "$status" != "0" ]; then
      broken+=("$project_web_url")
  fi

  cd $project_path
  for branch in "${branches[@]}"; do
    recreate_branch $branch
  done
  cd ../
}

recreate_branch() {
    git pull > /dev/null
    routput=$(git diff origin/$1...main || true)
    if [ ! -z "$routput" ]; then
      echo "> $1 differs from main"
      git push origin --delete $1 || true
      git checkout -b $1
      git push -u origin $1
      recraeted[$branch]=$((recraeted[$branch]+1))
    fi
}

mkdir $script_dir/.temp
cd $script_dir/.temp

output=$(curl -s "https://$host/api/v4/groups/$group/projects?private_token=$token&per_page=100&page=1" | grep -c -i Unauthorized || true)
[[ "${output-}" != 0 ]] && die "You are not authorized!"

page_count=$(curl -sSL -D - "https://$host/api/v4/groups/$group/projects?private_token=$token&per_page=100" -o /dev/null | grep x-total-pages | grep -oE "[^\ ]+$" | tr -d '\r')

for ((page=1;page<=page_count;page++)); do
    projects=$(curl -s "https://$host/api/v4/groups/$group/projects?private_token=$token&per_page=100&page=$page")
    length=$(echo $projects |jq length )

    for ((i=0;i<length;i++)); do
        project=$(echo $projects | jq .[$i].ssh_url_to_repo | tr -d '"')
        project_name=$(echo $projects | jq .[$i].name | tr -d '"')
        project_path=$(echo $projects | jq .[$i].path | tr -d '"')
        project_web_url=$(echo $projects | jq .[$i].web_url | tr -d '"')
        
        if [[ ! -z "${projects_to_recreate-}" ]]; then
          if [[ " ${projects_to_recreate[*]} " =~ " ${project_path} " ]]; then
              check_and_recreate
          fi
        else
          check_and_recreate
        fi
    done
done
cd ../

for branch in "${!recraeted[@]}"; do
  msg "RECREATED $branch BRANCES: ${recraeted[$branch]}"
done

if [ "$(echo ${#broken[*]})" != "0" ]; then
    msg "Fail to recreate branches"
    for item in ${broken[*]}; do
        printf "   %s\n" $item
    done
fi
