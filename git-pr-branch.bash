#!/bin/bash

# For every KubeDB database operator repo:
#   1. git fetch --all
#   2. git add . && git commit -s -m "save"
#   3. git checkout -b <pr-name>
#   4. git reset --hard origin/master
#
# Usage: bash git-pr-branch.bash [branch-name]
#   branch-name defaults to "pr-name" if not provided.

set -u

branch="${1:-pr-name}"
base_dir="$HOME/go/src/kubedb.dev"

# 32 KubeDB database operators
dbRepo=("aerospike" "cassandra" "clickhouse" "db2" "documentdb" "druid" "elasticsearch" "hanadb" "hazelcast" "ignite" "kafka" "mssqlserver" "mariadb" "memcached" "milvus" "mongodb" "mysql" "neo4j" "oracle" "percona-xtradb" "pgbouncer" "pgpool" "postgres" "proxysql" "qdrant" "rabbitmq" "redis" "redis-sentinel" "singlestore" "solr" "weaviate" "zookeeper")

for repo in "${dbRepo[@]}"; do
  repo_dir="$base_dir/$repo"
  echo "==> processing $repo"

  if [[ ! -d "$repo_dir/.git" ]]; then
    echo "    repo not found, skipping: $repo_dir"
    continue
  fi

  cd "$repo_dir" || { echo "    cannot cd into $repo_dir, skipping"; continue; }

  git fetch --all
  git add .
  git commit -s -m "save"
  git checkout -b "$branch"
  git reset --hard origin/master
done

echo "All database repositories processed."
