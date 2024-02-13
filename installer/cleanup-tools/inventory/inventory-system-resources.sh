#!/bin/bash

# Copyright (c) 2023 Red Hat, Inc.

# Produces an inventory (recorded in a subdirectory) of selected cluster-scoped
# resources that are created by an MCE or ACM hub instnace.  Intended to be used
# to do a before/after anaysis to catch "leaked" resources.
#
# An example usage sequence might be:
#
# (1) Run on a fresh OCP cluster, and save results in a "fresh-ocp" directory.
# (2) Install MCE and ACM
# (3) Run again to caputre thiings as they are now into a "after-acm" directory.
# (4) Use companion diff-resource-inventrooy.sh script to identify the diffs
#     between "fresh-ocp" and "after-acm" to see what MCE/ACM created.
# (5) Uninstall and or do a forced-cleanup of MCE/ACM.
# (6) Run again to caputre things as they now are into a "after-uninstall" directory.
# (7) Use diff-resource-inventory.sh ti identify the changes between "fresh-ocp"
#     and "fater-uninstall" to see what has been left behind after the ininstall/cleanup.
#
# Requires:
# - Bash V4
# - oc
# - grep
# - sort
#
# Notes:
#
# - The list of resource types inventoried is based on ACM 2.7 and 2.8 (and corresp.
#   MCE 2.2 and 2.3) and may need to be updated for subsequent releases.
#
# - Also, we have not yet verified that this list is complete/comprehensive but it
#   is at least a very good first stab.
#
# - This script makes no attempt to identify cluster resources that exist but are
#   modified by ACM or MCE.  (One known example of such a moifications is the
#   cluster-monitoring-config ConfigMap in the openshift-monitoring namespace.)

output_dir="${1:-./resource-inventory}"

rm -rf "$output_dir"
mkdir -p "$output_dir"
cd $output_dir

# Gather an inveotry of some important cluster-level resources

cluster_resource_kinds=()
cluster_resource_kinds+=("namespaces")
cluster_resource_kinds+=("customresourcedefinitions")
cluster_resource_kinds+=("validatingwebhookconfigurations")
cluster_resource_kinds+=("mutatingwebhookconfigurations")
cluster_resource_kinds+=("apiservices")
cluster_resource_kinds+=("clusterroles")
cluster_resource_kinds+=("clusterrolebindings")
cluster_resource_kinds+=("consoleplugins")
cluster_resource_kinds+=("storageversionmigrations")

for kind in ${cluster_resource_kinds[@]}; do
   oc get "$kind" \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' \
      | sort > "$kind"
done

# Monitoring COnfig in openshift-monitoring

monitoring_crds=$(oc get crd \
   -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' \
   | grep "monitoring\.coreos\.com" | sort)
for crd in $monitoring_crds; do
   oc -n "openshift-monitoring" get "$crd" -o name | sort >> openshift-monitoring
done

