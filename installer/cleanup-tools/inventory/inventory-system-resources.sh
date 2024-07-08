#!/bin/bash

# Copyright (c) 2023, 2024 Red Hat, Inc.

# Produces an inventory (recorded in a subdirectory) of all (or most) resources
# on a Openshift Container Platform (OCP) cluster.  This is intended to be used
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
##
# - This script makes no attempt to identify resources that exist but are
#   modified by ACM or MCE.  (One known example of such a moifications is the
#   cluster-monitoring-config ConfigMap in the openshift-monitoring namespace.)

output_dir="${1:-./resource-inventory}"

rm -rf "$output_dir"
mkdir -p "$output_dir"
cd $output_dir

# Start with an explicit list of cluster/namespaced resources from
# built-in Kube APIs.

cluster_resource_kinds=()
cluster_resource_kinds+=("namespaces")
cluster_resource_kinds+=("customresourcedefinitions")
cluster_resource_kinds+=("validatingwebhookconfigurations")
cluster_resource_kinds+=("mutatingwebhookconfigurations")
cluster_resource_kinds+=("apiservices")
cluster_resource_kinds+=("clusterroles")
cluster_resource_kinds+=("clusterrolebindings")

namespaced_resource_kinds=()
namespaced_resource_kinds+=("configmaps")
namespaced_resource_kinds+=("secrets")
namespaced_resource_kinds+=("roles")
namespaced_resource_kinds+=("rolebindings")

namespaced_resource_kinds+=("routes")

namespaced_resource_kinds+=("pods")
namespaced_resource_kinds+=("deployments")
anamespaced_resource_kinds+=("replicasets")
namespaced_resource_kinds+=("statefulsets")
namespaced_resource_kinds+=("daemonsets")
namespaced_resource_kinds+=("jobs")
namespaced_resource_kinds+=("cronjobs")

namespaced_resource_kinds+=("persistentvolumes")
namespaced_resource_kinds+=("persistentvolumeclaims")

# Exclude some CRDs that are noisy (often chaning) and not relevant to us.

declare -A excluded_crd_kinds
excluded_crd_kinds["apirequestcounts.apiserver.openshift.io"]=1


# Add in all CRD kinds that are not excluded:

cluster_scoped_crds=$(oc get "crd" -A \
   -o jsonpath='{range .items[*]}{.spec.scope}{" "}{.metadata.name}{"\n"}{end}'  \
   | grep "^Cluster " | cut -d' ' -f2 | sort)
for crd in $cluster_scoped_crds; do
   if [[ "${excluded_crd_kinds[$crd]}" -eq 0 ]]; then
      cluster_resource_kinds+=("$crd")
   fi
done

namespaced_crds=$(oc get "crd" -A \
   -o jsonpath='{range .items[*]}{.spec.scope}{" "}{.metadata.name}{"\n"}{end}'  \
   | grep "^Namespaced " | cut -d' ' -f2 | sort)
for crd in $namespaced_crds; do

   if [[ "${excluded_crd_kinds[$crd]}" -eq 0 ]]; then
      namespaced_resource_kinds+=("$crd")
   fi
done

# Collect lists of cluster-scoped resources:

for kind in ${cluster_resource_kinds[@]}; do
   echo "Gathering lists of $kind."
   oc get "$kind" \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' \
      | sort > "$kind"
done

# Collect lists of namespace-scoped resources:

for kind in ${namespaced_resource_kinds[@]}; do
   echo "Gathering lists of $kind."
   oc get "$kind" -A \
      -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' \
      | sort > "$kind"
done


