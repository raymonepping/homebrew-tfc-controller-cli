# Terraform Cloud Organization Report

**Organization:** optimus_prime  
**Email:** raymon.epping@hashicorp.com  
**Generated:** 2025-09-29T10:21:27Z

## Table of Contents
- [Organization](#organization)
- [Summary](#summary)
- [Projects](#projects)
- [Workspaces](#workspaces)
- [Workspace Variables (keys only)](#workspace-variables-keys-only)
- [Variable Sets](#variable-sets)
  - [Varset Scopes](#varset-scopes)
  - [Varset Variables (keys only)](#varset-variables-keys-only)
- [Private Registry](#private-registry)
  - [Modules](#modules)
  - [Module Versions](#module-versions)
- [Reserved Tag Keys](#reserved-tag-keys)
- [Users](#users)
- [Teams](#teams)
  - [Core](#core)
  - [Team ↔ Project Access](#team--project-access)

## Organization

Name	Email	SSO
|Name|Email|SSO|
|---|---|---|
|optimus_prime|raymon.epping@hashicorp.com|not enforced|

## Summary

Projects	Workspaces	Users	Teams	Varsets	Modules
|Projects|Workspaces|Users|Teams|Varsets|Modules|
|---|---|---|---|---|---|
|1|13|1|3|1|2|

## Projects

|ID|Name|Description|
|---|---|---|
|prj-YQBi1ZNfjboS51sQ|Default Project|—|

## Workspaces

|WS ID|Name|Project|Exec Mode|TF Ver|Auto-apply|Queue-all|Agent Pool|VCS Repo|Branch|
|---|---|---|---|---|---|---|---|---|---|
|ws-EgUsFJYvDdq3c8aN|aws_demo|Default Project|remote|1.12.1|❌|❌|—|—|—|
|ws-DsS876pLLuabg1vg|blessjoe|Default Project|agent|1.11.4|✅|❌|local_pool|raymonepping/blessjoe|—|
|ws-Ub1wNdz46ehYjS6c|demo_optimus|Default Project|agent|1.12.1|❌|❌|local_pool|raymonepping/demo_optimus|—|
|ws-BhgQHam8RCsXPp5i|demo_prime|Default Project|agent|1.12.1|❌|❌|local_pool|raymonepping/demo_prime|—|
|ws-wEwaS8i1SENBkViE|hatsjoe|Default Project|agent|1.11.3|❌|❌|local_pool|raymonepping/hatsjoe|—|
|ws-CFQJd5znDaFcaPrf|medium|Default Project|agent|1.12.2|❌|❌|local_pool|raymonepping/medium|—|
|ws-MhmeMLdeY6S2Xs9P|medium_podman|Default Project|agent|1.12.2|❌|❌|local_pool|raymonepping/medium_podman|—|
|ws-qUcNyvEyipYmkEv4|optimus_prime|Default Project|agent|1.12.1|❌|❌|local_pool|raymonepping/optimus_prime|—|
|ws-j2QdGNLtsczJPqxk|project_oss|Default Project|agent|1.13.3|✅|❌|local_pool|raymonepping/project_oss|hcp-move|
|ws-e8wcyDyguFVtuAd1|prox_demo|Default Project|remote|1.12.1|❌|❌|—|raymonepping/prox_demo|—|
|ws-77Afv3exLqPy7gJM|proximus|Default Project|agent|1.12.1|❌|❌|local_pool|raymonepping/blessjoe|—|
|ws-wRybjXPMJCf26UGF|transform|Default Project|agent|1.12.2|✅|❌|nomad_repping|raymonepping/transform|—|
|ws-4iCk1mNRRZyyk9Ds|waypoint_vm|Default Project|remote|1.12.1|✅|❌|—|—|—|

## Workspace Variables (keys only)

|Workspace|Key|Category|HCL|Sensitive|
|---|---|---|---|---|
|aws_demo|AWS_ACCESS_KEY_ID|env|❌|—|
|aws_demo|AWS_SECRET_ACCESS_KEY|env|❌|🔒|
|aws_demo|AWS_SESSION_EXPIRATION|env|❌|—|
|aws_demo|AWS_SESSION_TOKEN|env|❌|🔒|
|aws_demo|ami_id|terraform|❌|—|
|aws_demo|asn_number|terraform|❌|—|
|aws_demo|create_entities|terraform|❌|—|
|aws_demo|ipam_cidr|terraform|❌|—|
|aws_demo|ipam_name|terraform|❌|—|
|aws_demo|netbox_token|terraform|❌|—|
|aws_demo|netbox_url|terraform|❌|—|
|aws_demo|project_name|terraform|❌|—|
|aws_demo|public_key|terraform|❌|—|
|aws_demo|region|terraform|❌|—|
|demo_optimus|AWS_ACCESS_KEY_ID|env|❌|—|
|demo_optimus|AWS_SECRET_ACCESS_KEY|env|❌|🔒|
|demo_optimus|AWS_SESSION_EXPIRATION|env|❌|—|
|demo_optimus|AWS_SESSION_TOKEN|env|❌|🔒|
|demo_optimus|asn_number|terraform|❌|—|
|demo_optimus|az|terraform|❌|—|
|demo_optimus|ipam_cidr|terraform|❌|—|
|demo_optimus|ipam_name|terraform|❌|—|
|demo_optimus|netbox_prefix|terraform|❌|—|
|demo_optimus|netbox_token|terraform|❌|—|
|demo_optimus|netbox_url|terraform|❌|—|
|demo_optimus|project_name|terraform|❌|—|
|demo_optimus|public_subnet_cidr|terraform|❌|—|
|demo_optimus|region|terraform|❌|—|
|demo_optimus|sdn_dcgw_subnet_cidr|terraform|❌|—|
|demo_optimus|vpc_cidr|terraform|❌|—|
|demo_optimus|vpc_name|terraform|❌|—|
|demo_prime|AWS_ACCESS_KEY_ID|env|❌|—|
|demo_prime|AWS_SECRET_ACCESS_KEY|env|❌|🔒|
|demo_prime|AWS_SESSION_EXPIRATION|env|❌|—|
|demo_prime|AWS_SESSION_TOKEN|env|❌|🔒|
|demo_prime|ami_id|terraform|❌|—|
|demo_prime|key_name|terraform|❌|—|
|demo_prime|project_name|terraform|❌|—|
|demo_prime|public_key|terraform|❌|—|
|demo_prime|region|terraform|❌|—|
|demo_prime|selected_os|terraform|❌|—|
|demo_prime|vm_count|terraform|❌|—|
|medium|project_name|terraform|❌|—|
|optimus_prime|AWS_ACCESS_KEY_ID|env|❌|—|
|optimus_prime|AWS_SECRET_ACCESS_KEY|env|❌|🔒|
|optimus_prime|AWS_SESSION_EXPIRATION|env|❌|—|
|optimus_prime|AWS_SESSION_TOKEN|env|❌|🔒|
|optimus_prime|enable_dns_hostnames|terraform|❌|—|
|optimus_prime|enable_dns_support|terraform|❌|—|
|optimus_prime|enable_flow_logs|terraform|❌|—|
|optimus_prime|environment|terraform|❌|—|
|optimus_prime|ipam_pool_cidr|terraform|❌|—|
|optimus_prime|os_type|terraform|❌|—|
|optimus_prime|project_name|terraform|❌|—|
|optimus_prime|region|terraform|❌|—|
|optimus_prime|use_ipam|terraform|❌|—|
|optimus_prime|vault_address|terraform|❌|—|
|optimus_prime|vault_namespace|terraform|❌|—|
|optimus_prime|vault_token|terraform|❌|🔒|
|optimus_prime|vpc_cidr|terraform|❌|—|
|prox_demo|AWS_ACCESS_KEY_ID|env|❌|—|
|prox_demo|AWS_SECRET_ACCESS_KEY|env|❌|🔒|
|prox_demo|AWS_SESSION_EXPIRATION|env|❌|—|
|prox_demo|AWS_SESSION_TOKEN|env|❌|🔒|
|prox_demo|ami_id|terraform|❌|—|
|prox_demo|asn_number|terraform|❌|—|
|prox_demo|create_entities|terraform|❌|—|
|prox_demo|ipam_cidr|terraform|❌|—|
|prox_demo|ipam_name|terraform|❌|—|
|prox_demo|netbox_token|terraform|❌|🔒|
|prox_demo|netbox_url|terraform|❌|—|
|prox_demo|project_name|terraform|❌|—|
|prox_demo|public_key|terraform|❌|—|
|prox_demo|public_subnet_cidr|terraform|❌|—|
|prox_demo|region|terraform|❌|—|
|prox_demo|sdn_dcgw_subnet_cidr|terraform|❌|—|
|proximus|AWS_ACCESS_KEY_ID|env|❌|—|
|proximus|AWS_SECRET_ACCESS_KEY|env|❌|🔒|
|proximus|AWS_SESSION_EXPIRATION|env|❌|—|
|proximus|AWS_SESSION_TOKEN|env|❌|🔒|
|transform|AWS_ACCESS_KEY_ID|env|❌|—|
|transform|AWS_SECRET_ACCESS_KEY|env|❌|🔒|
|transform|AWS_SESSION_EXPIRATION|env|❌|—|
|transform|AWS_SESSION_TOKEN|env|❌|🔒|
|transform|environment|terraform|❌|—|
|transform|project_name|terraform|❌|—|
|waypoint_vm|ami_id|terraform|❌|—|
|waypoint_vm|key_name|terraform|❌|—|
|waypoint_vm|name|terraform|❌|—|
|waypoint_vm|project_name|terraform|❌|—|
|waypoint_vm|public_key|terraform|❌|—|
|waypoint_vm|security_group_id|terraform|❌|—|
|waypoint_vm|subnet_id|terraform|❌|—|
|waypoint_vm|volume_size|terraform|❌|—|
|waypoint_vm|volume_type|terraform|❌|—|
|waypoint_vm|waypoint_application|terraform|❌|—|

## Variable Sets

|ID|Name|Description|Scope|
|---|---|---|---|
|varset-jqvdYH3DNXiKPXSX|optimus_prime_variables|Variables needed to deploy infrastructure and instances with Optimus Prime|scoped|

### Varset Scopes

_No varset scopes found._

### Varset Variables (keys only)

_No varset variables found (keys)._

## Private Registry

### Modules

|Name|Provider|Namespace|Latest|Versions|VCS Repo|
|---|---|---|---|---|---|
|bumblebee|aws|optimus_prime|—|0|raymonepping/terraform-aws-bumblebee|
|optimus|aws|optimus_prime|—|0|raymonepping/terraform-aws-optimus|

### Module Versions

_No module versions found._

## Reserved Tag Keys

|Key|Created|
|---|---|
|demo_prospect|2025-05-30T06:42:06.468Z|

## Users

|Username|Email|Status|Teams|
|---|---|---|---|
|RaymonEpping|raymon.epping@hashicorp.com|active|Devs, Ops, owners|

## Teams

### Core

|Team ID|Name|Users|Visibility|SSO Team ID|Allow Member Tokens|Org Access|
|---|---|---|---|---|---|---|
|team-dYwCabJ3tXbpJpNE|Devs|2|secret|—|❌|—|
|team-v8H3qWsNDeU77rnF|Ops|1|secret|—|❌|—|
|team-6iWtnDuSVD7PX98C|owners|4|secret|—|✅|access-secret-teams, manage-agent-pools, manage-membership, manage-modules, manage-organization-access, manage-policies, manage-policy-overrides, manage-projects, manage-providers, manage-public-modules, manage-public-providers, manage-run-tasks, manage-teams, manage-vcs-settings, manage-workspaces, read-projects, read-workspaces|

### Team Memberships

|Team|User ID|
|---|---|
|Devs|user-HudBUuwbFmmZua1m|
|Devs|user-dYJ8PAvMFznRZegs|
|Ops|user-HudBUuwbFmmZua1m|
|owners|user-26BcX2F61eZ56J5v|
|owners|user-275sjft7yRSMFsx3|
|owners|user-HudBUuwbFmmZua1m|
|owners|user-UeNNWyVKjDuGYZ2w|

### Team ↔ Project Access

|Project|Team|Access|
|---|---|---|
|Default Project|Devs|read|
|Default Project|Ops|write|
