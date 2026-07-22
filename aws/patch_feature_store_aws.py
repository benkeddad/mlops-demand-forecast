#!/usr/bin/env python3
"""
Rewrites feature_repo/feature_store.yaml to point at RDS (offline store +
registry) and DynamoDB (online store) instead of the Docker/K8s service
names "postgres" and "redis" that the Compose and K3s paths use.

Kept as its own file instead of being inlined through a batch -> bash ->
python quoting chain: that exact pattern (bash logic passed as a string
through nested shells) is the one already documented as fragile in this
repo's own README ("cmd.exe delayed expansion corrupts embedded bash").
One argument, one shell boundary, no nesting.

Usage:
    python3 scripts/patch_feature_store_aws.py <rds-endpoint>
"""
import sys
from pathlib import Path

if len(sys.argv) != 2:
    print("Usage: patch_feature_store_aws.py <rds-endpoint>")
    sys.exit(1)

rds_endpoint = sys.argv[1]
repo_root = Path(__file__).resolve().parent.parent
target = repo_root / "feature_repo" / "feature_store.yaml"

new_content = f"""project: rossmann_project
provider: aws
entity_key_serialization_version: 2

registry:
  registry_type: sql
  path: postgresql://user:Password@{rds_endpoint}:5432/feast

offline_store:
  type: postgres
  host: {rds_endpoint}
  port: 5432
  database: rossmann
  db_schema: public
  user: user
  password: Password
  sslmode: disable

online_store:
  type: dynamodb
  region: us-east-1
"""

backup = target.with_suffix(".yaml.bak")
if target.exists() and not backup.exists():
    backup.write_text(target.read_text())
    print(f"Backed up original to {backup}")

target.write_text(new_content)
print(f"Wrote {target} pointing at RDS endpoint {rds_endpoint}")
