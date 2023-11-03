#!/bin/bash

# THIS IS A WORK IN PROGRESS.

# Copyright (c) 2023 Red Hat, Inc.
#
# Author: joeg-pro
#
# This script performs an agressive cleanup of an OCP cluster to remove all
# known remnants of MCE or ACM.  Its intended to be used to cleanup after
# a failed install or uninstall, so as to prepare for a new install attempt.
#
# By "agressive" we mean that the scirpt does not attempt an orderly uninstall
# as we assume the reason its being run is that an orderly uninstall has
# already been attempted and has failed/got stuck. As a result, this script
# prceeeds agressively by duing things like deleting all deployments and
# pods in MCE/ACM namespaces, and "doing what it takes" to get rid of
# resource instances (removing governing webhooks, removing finalizers, etc.)
#
# USE OF THIS SCRIPT WILL RESULT IN THE DELETION/LOSS OF CONFIGURATION INFO
# MADE IN MCE OR MCE RESOURCES SINCE IT DELETES RESOURCE INSTANCES WITHOUT
# BACKING THEM UP FIRST.
#
# ALSO, IT IS POSSIBLE THAT USE OF THIS SCRIPT COULD RESULT IN BREAKAGE TO
# OTHER APPLICATIONS/OPERATORS THAT ARE INSTALLED ON THE SAME CLUSTER AS
# MCE OR ACM IF THOSE OTHER APPLICATIONS/OPERATORS USE OR DEPEND ON THINGS
# THAT WE ASSUME ARE PROVIDED BY/OWNED BY MCE OR ACM AND THUS CLEAN THEM UP.
#
# Examples of changes made that could cause breakage:
#
# - Cluster monitoring's user-workload monitorin is disabled on the assumption
#   that  it was ACM that enabled it and is the only thing using it.
#
# - Resources related to OADP and Velero are removed, on the assumption that
#   they were installed by ACM's cluster-backup functionality and that is
#   the only thing using them.
#
# Requires:
# - Bash V4
# - oc
# - cut

my_dir=$(dirname $(readlink -f "$0"))

source "$my_dir/common-functions.bash"
source "$my_dir/find-mce.bash"
source "$my_dir/find-mch.bash"

do_hub_stuff=0
do_agent_stuff=1

nuke_velero=1
nuke_oadp=1
nuke_prometheus=1
nuke_user_resource_monitoring=1

#-----------------------------------------#
# Lowest-level Resource nuking primitives #
#-----------------------------------------#

function zorch_namespaced_finalizer() {
   local ns="$1"
   local kind_and_name="$2"

   local finalizers=$(oc -n "$ns" get "$kind_and_name" -o jsonpath='{.metadata.finalizers}' 2> /dev/null)
   if [[ -n "$finalizers" ]]; then
      oc -n "$ns" patch --type=merge -p '{"metadata":{"finalizers":null}}' "$kind_and_name" > /dev/null
   fi
}

function zorch_cluster_finalizer() {
   local kind_and_name="$1"

   local finalizers=$(oc get "$kind_and_name" -o jsonpath='{.metadata.finalizers}' 2> /dev/null)
   if [[ -n "$finalizers" ]]; then
      oc patch --type=merge -p '{"metadata":{"finalizers":null}}' "$kind_and_name" > /dev/null
   fi
}

function nuke_namespaced_resource() {

   local ns="$1"
   local kind_and_name="$2"
   if ! oc -n "$ns" get "$kind_and_name" -o yaml > /dev/null 2>&1; then
      return
   fi

   echo "Deleting $kind_and_name from namespace $ns."

   zorch_namespaced_finalizer "$ns" "$kind_and_name"
   oc -n "$ns" delete --ignore-not-found --timeout=10s "$kind_and_name" 2> /dev/null
   if [[ $? -ne 0 ]]; then
      echo "Timeout waiting for deletion to occur, retrying."
      zorch_namespaced_finalizer "$ns" "$kind_and_name"
      oc -n "$ns" delete --timeout=30s "$kind_and_name"
      if [[ $? -ne 0 ]]; then
         echo "Warning: Could not delete $kind_and_name from namespace $ns (timeout on retry)."
      fi
   fi
}

function delete_cluster_resource() {

   # Doesn't zorch finalizers, just deletes.
   # (Intended for deletingn nsmaceps.)

   local kind_and_name="$1"
   if ! oc get "$kind_and_name" -o yaml > /dev/null 2>&1; then
      return
   fi

   echo "Deleting $kind_and_name."

   oc  delete --ignore-not-found --timeout=15s "$kind_and_name" 2> /dev/null
   if [[ $? -ne 0 ]]; then
      echo "Warniing: Could not delete $kind_and_name (timeout)."
   fi
}

function delete_cluster_resource_no_wait() {

   # Doesn't zorch finalizers, just deletes.
   # (Intended for deletingn nsmaceps.)

   local kind_and_name="$1"
   if ! oc get "$kind_and_name" -o yaml > /dev/null 2>&1; then
      return
   fi

   echo "Deleting $kind_and_name."
   oc  delete --ignore-not-found --wait=false "$kind_and_name" 2> /dev/null
}

function nuke_cluster_resource() {

   local kind_and_name="$1"
   if ! oc get "$kind_and_name" -o yaml > /dev/null 2>&1; then
      return
   fi

   echo "Deleting $kind_and_name."

   zorch_cluster_finalizer "$kind_and_name"
   oc  delete --ignore-not-found --timeout=10s "$kind_and_name" 2> /dev/null
   if [[ $? -ne 0 ]]; then
      echo "Timeout waiting for deletion to occur, retrying."
      zorch_cluster_finalizer "$kind_and_name"
      oc  delete --timeout=30s "$kind_and_name"
      if [[ $? -ne 0 ]]; then
         echo "Warniing: Could not delete $kind_and_name (timeout after retry)."
      fi
   fi
}

function nuke_kind_from_namespace() {

   # Removes all instances of specified kind from the specified namespace.

   local kind="$1"
   local ns="$2"

   local inst_list=$(oc -n "$ns" get "$kind" -o name)
   if [[ $? -eq 0 ]]; then
      for inst in $inst_list; do
         nuke_namespaced_resource "$ns" "$inst"
      done
   fi
}

function nuke_kinds_from_namespace() {

   # Removes all instances of specified kinds (in array) from the specified namespace.

   local -n kind_list="$1"
   local ns="$2"

   local kind
   for kind in "${kind_list[@]}"; do
      nuke_kind_from_namespace "$kind" "$ns"
  done
}

function nuke_kinds_from_namespaces() {

   # Removes all instances of specified kinds (in array) from the specified namespaces (in array).

   local -n kind_list="$1"
   local -n ns_list="$2"

   local ns
   for ns in "${ns_list[@]}"; do
      nuke_kinds_from_namespace "$kind_list" "$ns"
   done
}

function nuke_cluster_kinds() {

   # Removes all instances of the specified cluster-scoped kinds (in array).

   local -n kind_list="$1"

   local kind
   for kind in "${kind_list[@]}"; do
      local inst_list=$(oc get "$kind" -o name 2> /dev/null)
      if [[ "$?" -eq 0 ]]; then
         for inst in $inst_list; do
            nuke_cluster_resource "$inst"
         done
      fi
  done
}

function nuke_cluster_kind_matching_name_pattern() {

   # Removes all instances of a specified cluster-scoped kind that have
   # a name matching the specified pattern.

   local cluster_kind="$1"
   local pattern="$2"

   local hits=$(oc get "$cluster_kind" -o name | grep "$pattern")
   if [[ -n "$hits" ]]; then
      local line
      while read line; do
         oc delete "$line"
      done <<< "$hits"
   fi
}

function nuke_cluster_kind_matching_name_patterns() {

   # Removes all instances of a specified cluster-scoped kind that have
   # a name matching one of the specified patterns (in array).

   local cluster_kind="$1"
   local -n pattern_list="$2"

   local pattern
   for pattern in "${pattern_list[@]}"; do
      nuke_cluster_kind_matching_name_pattern "$cluster_kind" "$pattern"
   done
}

function nuke_kind_from_namespace_matching_name_patterns() {

   # Removes instances of a specified namespace-scoped kind from the specified
   # namespace that have a name matching one of the specified patterns (in array).

   local kind="$1"
   local ns="$2"
   local -n pattern_list="$3"

   local inst_list=$(oc -n "$ns" get "$kind" -o name)

   local pattern
   for pattern in "${pattern_list[@]}"; do
      local hits=$(grep "$pattern" <<< "$inst_list")
      if [[ -n "$hits" ]]; then
         while read line; do
            oc -n "$ns" delete "$line"
         done <<< "$hits"
      fi
   done

}

function zorch_conversion_webhooks_from_crs_matching_kind_patterns() {

   # Disables conversion webhooks for custom resource types with a name
   # matching one of the specified patterns (in array).

   local -n pattern_list="$1"

   local pattern
   local crd
   for pattern in "${pattern_list[@]}"; do
      local crd_list=$(oc get crd -o name | grep "$pattern")
      for crd in $crd_list; do
         local conversion_strategy=$(oc get $crd -o 'jsonpath={.spec.conversion.strategy}')
         if [[ "$conversion_strategy" == "Webhook" ]]; then
            echo "Removing conversion webhook from CRD ${crd#*/}."
            oc patch "$crd" --type=merge -p '{"spec":{"conversion": null}}'
         fi
      done
   done
}

function nuke_crs_matching_kind_patterns() {

   # Removes all instances of custom resource kinds with names matching one of
   # the specified patterns (in array).  If the custom-resource kind is a
   # namespaced one, removal is performed acrosss all namespaces.

   local -n pattern_list="$1"

   # Delete the CRDs (no wait) and let kube instance deletion hopefully
   # take care of deleting most instances.

   local did_something=0

   local pattern
   for pattern in "${pattern_list[@]}"; do
      local crd_list=$(oc get crd -o name | grep "$pattern")
      local crd
      for crd in $crd_list; do
         delete_cluster_resource_no_wait "$crd"
         # NB: This is a delete and not nke because the CRD has a finalizer that
         # is intended to coordinate with instance cleanup and we sure don't want
         # to get rid of the CRD if resource instances remain.
         did_something=1
      done
   done

   if [[ $did_something -eq 0 ]]; then
      return
   fi

   # Give background instance deletion a chance to do its thing.
   echo "Pausing a bit to allow instance deletion to occur."
   sleep 10

   # Look throught the remaining CRDs matching tha patterns and categorize according
   # to cluster vs. namespace cope.

   nuke_crs_clsuter_kinds=()     # Intentionally non-local
   nuke_crs_ns_scoped_kinds=()   # Intentionally non-local

   local pattern
   local crd
   for pattern in "${pattern_list[@]}"; do
      local crd_list=$(oc get crd -o name | grep "$pattern")
      for crd in $crd_list; do
         echo "Note: Instances of CR $crd remain, maybe blocked by finalizers."
         crd_name="${crd#*/}"
         crd_scope=$(oc get "$crd" -o jsonpath='{.spec.scope}')
         if [[ "$crd_scope" == "Cluster" ]]; then
            nuke_crs_cluster_kinds+=("$crd_name")
         else
            nuke_crs_ns_scoped_kinds+=("$crd_name")
         fi
      done
   done

   # Now individually nuke any instances that are stuck.

   temp_list=()  # Intentionally non-local
   for kind in "${nuke_crs_cluster_kinds[@]}"; do
      if oc get "crd/$kind" -o name > /dev/null 2>&1; then
         temp_list+=("$kind")
      fi
   done
   nuke_cluster_kinds temp_list

   for kind in "${nuke_crs_ns_scoped_kinds[@]}"; do
      if oc get "crd/$kind" -o name > /dev/null 2>&1; then
         local inst_list=$(oc get "$kind" --all-namespaces \
            -o jsonpath='{range .items[*]}{.metadata.namespace}{"/"}{.metadata.name}{"\n"}{end}')
         if [[ -n "$inst_list" ]]; then
            local inst
            for inst in $inst_list; do
               inst_ns="${inst%/*}"
               inst_name="${inst#*/}"
               nuke_namespaced_resource "$inst_ns" "$kind/$inst_name"
            done
         fi
      fi
   done
}

function nuke_pods_from_namespace() {

   # Removes all Deployments/ReplicaSets/StatefulSets/Pods from a specified namespace.
   # Also removes all Leases found.

   local ns="$1"

   local inst_list=$(oc -n "$ns" get pods -o name)
   if [[ -z "$inst_list" ]]; then
      return
   fi

   echo "Deleeting pods and higher-level apps from namespace $ns."

   local kinds="deployments statefulsets"
   local need_to_pause=0
   local kind
   for kind in $kinds; do
      inst_list=$(oc -n "$ns" get "$kind" -o name)
      if [[ -n "$inst_list" ]]; then
          echo "   ...Deleting $kind"
          need_to_pause=1
          local inst
          for inst in $inst_list; do
             nuke_namespaced_resource "$ns" "$inst"
          done
      fi
   done

   if [[ $need_to_pause -ne 0 ]]; then
      echo "Pausing a bit."
      sleep 10
   fi

   local inst_list=$(oc -n "$ns" get pods -o name)
   if [[ -z "$inst_list" ]]; then
      echo "...All pods are gone"
      return
   fi

   local inst_list=$(oc -n "$ns" get replicasets -o name)
   if [[ -n "$inst_list" ]]; then
      echo "Deleeting replicasets explicitly."

      local inst
      for inst in $inst_list; do
         nuke_namespaced_resource "$ns" "$inst"
      done

      echo "Pausing a bit."
      sleep 10
   fi

   local inst_list=$(oc -n "$ns" get pods -o name)
   if [[ -z "$inst_list" ]]; then
      echo "...All pods are gone"
      return
   fi

   echo "Deleeting pods explicitly."

   local inst
   for inst in $inst_list; do
      nuke_namespaced_resource "$ns" "$inst"
   done
   echo "Pausing a bit."
   sleep 10

   inst_list=$(oc -n "$ns" get pods -o name)
   if [[ -z "$inst_list" ]]; then
      echo "...All pods are gone"
   else
      echo "Warning: Pods still remain in namespace $ns, giving up on deleting them."
   fi

   echo "Deleting leases."
   nuke_kind_from_namespace "lease.coordination.k8s.io" "$ns"

}

function kind_exists_in_namespace() {

   local kind="$1"
   local ns="$2"

   local inst_list=$(oc -n "$ns" get "$kind" -o name)
   if [[ -n "$inst_list" ]]; then
      return 0
   else
      return 1
   fi

}

function _workload_resources_exist_in_namespaces() {

   # Returns true (0) if there are any instances of a workload resources exist
   # in any of the specified namespaces (in array).

   local -n ns_list="$1"
   shift 1
   local kinds="$@"

   local kind
   for kind in $kinds; do
      local n
      for ns in "${ns_list[@]}"; do
         if kind_exists_in_namespace "$kind" "$ns"; then
            return 0
         fi
      done
   done
   return 1
}

function _nuke_workload_resources_from_namespaces() {

   local msg_nuking_what="$1"   # For msgs
   local msg_from_where="$2"    # For msgs
   local -n ns_list="$3"
   local ns_list_name="$3"
   shift 3
   local kinds="$@"

   if ! _workload_resources_exist_in_namespaces "$ns_list_name" "$kinds"; then
      return 0
   fi

   local max_passes=3

   echo "Removing $msg_nuking_what from $msg_from_where."
   for pass in $(seq $max_passes); do
      local nuked_something=0
      local blurted_pass_msg=0

      local kind
      for kind in $kinds; do
         local blurted_kind_msg=0
         local ns
         for ns in "${ns_list[@]}"; do
            local inst_list=$(oc -n "$ns" get "$kind" -o name)
            if [[ -n "$inst_list" ]]; then
               if [[ $blurted_pass_msg -eq 0 ]]; then
                  echo "Performing pass $pass..."
                  blurted_pass_msg=1
               fi
               if [[ $blurted_kind_msg -eq 0 ]]; then
                   echo "...Deleting all $kind"
                   blurted_kind_msg=1
               fi
               nuked_something=1
               local inst
               for inst in $inst_list; do
                  nuke_namespaced_resource "$ns" "$inst"
               done
            fi
         done
      done
      if [[ $nuked_something -ne 0 ]]; then
         echo "...Pausing a bit"
         sleep 10
      else
         # Nothing left, no need for another pass.
         break
      fi
   done

   if ! _workload_resources_exist_in_namespaces "$ns_list_name" "$kinds"; then
      echo "All $msg_nuking_what are gone."
      return 0
   else
      echo "Warning: $msg_nuking_what remain after $max_passes passes, giving up."
      return 1
   fi
}

function nuke_pods_from_namespaces() {


   local workload_kinds="deployments statefulsets daemonsets jobs"

   local ns_list_name="$1"
   local msg_from_where="$2"

   _nuke_workload_resources_from_namespaces \
      "workload resources" "$msg_from_where" "$ns_list_name" $workload_kinds
   _nuke_workload_resources_from_namespaces \
      "remaining pods" "$msg_from_where" "$ns_list_name" "pods"

}

function nuke_olm_operator_from_namespace() {

   local pkg_name="$1"
   local op_ns="$2"

   local t=$(find_subs_for_operator "$pkg_name" "." "$op_ns")
   if [[ -n "$t" ]]; then
      local line
      while read line; do
         local sub_pkg=$(extract_delimited_field 1 "/" "$line")
         local sub_ns=$(extract_delimited_field 2 "/" "$line")
         local sub_name=$(extract_delimited_field 3 "/" "$line")
         oc -n "$sub_ns" delete sub "$sub_name"
      done <<< "$t"
   fi

   local t=$(find_csvs_for_operator "$pkg_name" "." "$op_ns")
   if [[ -n "$t" ]]; then
      local line
      while read line; do
         local csv_pkg=$(extract_delimited_field 1 "/" "$line")
         local csv_ns=$(extract_delimited_field 2 "/" "$line")
         local csv_name=$(extract_delimited_field 3 "/" "$line")
         oc -n "$csv_ns" delete csv "$csv_name"
      done <<< "$t"
   fi
}

function delete_namespace() {

   local ns="$1"
   delete_cluster_resource "ns/$ns"
}

function delete_namespaces() {

   local -n ns_list="$1"

   for ns in "${ns_list[@]}"; do
      delete_namespace "$ns"
   done
}

#--------------------------------------------------#
# Resource list gathering functions and variables #
#-------------------------------------------------#

hub_resource_patchers=()
agent_resource_patchers=()

hub_components=()

api_services=()
mutating_webhooks=()
validating_webhooks=()

sub_operator_operand_kinds=()
sub_operator_installed_operators=()

top_operator_operand_kinds=()

hub_top_pod_namespaces=()
hub_pod_namespaces=()
hub_other_namespaces=()

hub_cluster_roles=()
hub_cluster_role_bindings=()
hub_cr_kinds=()
hub_ocp_monitoring_promrules=()
hub_ocp_monitoring_servicemonitors=()
hub_console_plugins=()

agent_components=()
agent_api_services=()
agent_pod_namespaces=()
agent_other_namespaces=()
agent_cluster_roles=()
agent_cr_kinds=()
agent_ocp_monitoring_promrules=()
agent_ocp_monitoring_servicemonitors=()

function _add_to_list() {
   local -n the_list="$1"
   local the_component="$2"
   shift 2
   for e in "$@"; do
      the_list+=($e)
   done
}

function add_hub_resource_patchers()   { _add_to_list hub_resource_patchers "$@" ; }
function add_agent_resource_patchers() { _add_to_list agent_resource_patchers "$@" ; }

function add_hub_components()          { _add_to_list hub_components "." "$@"; }

function add_api_services()            { _add_to_list api_services "$@"; }
function add_mutating_webhooks()       { _add_to_list mutating_webhooks "$@"; }
function add_validating_webhooks()     { _add_to_list validating_webhooks "$@"; }

function add_top_operator_operand_kinds()           { _add_to_list top_operator_operand_kinds "$@"; }
function add_sub_operator_operand_kinds()           { _add_to_list sub_operator_operand_kinds "$@"; }
function add_sub_operator_installed_operators()     { _add_to_list sub_operator_installed_operators "$@"; }

function add_hub_top_pod_namespaces()               { _add_to_list hub_top_pod_namespaces "$@"; }
function add_hub_pod_namespaces()                   { _add_to_list hub_pod_namespaces     "$@"; }
function add_hub_other_namespaces()                 { _add_to_list hub_other_namespaces   "$@"; }

function add_hub_cluster_roles()                    { _add_to_list hub_cluster_roles "$@"; }
function add_hub_cluster_role_bindings()            { _add_to_list hub_cluster_roles "$@"; }
function add_hub_cr_kinds()                         { _add_to_list hub_cr_kinds "$@"; }
function add_hub_console_plugins()                  { _add_to_list hub_console_plugins "$@"; }

function add_hub_ocp_monitoring_promrules()         { _add_to_list hub_ocp_monitoring_promrules "$@"; }
function add_hub_ocp_monitoring_servicemonitors()   { _add_to_list hub_ocp_monitoring_servicemonitors "$@"; }

function add_agent_components()                     { _add_to_list agent_components "." "$@"; }

function add_agent_api_services()                   { _add_to_list agent_api_services "$@"; }

function add_agent_pod_namespaces()                 { _add_to_list agent_pod_namespaces "$@"; }
function add_agent_other_namespaces()               { _add_to_list agent_pod_namespaces "$@"; }

function add_agent_cr_kinds()                       { _add_to_list agent_cr_kinds "$@"; }
function add_agent_cluster_roles()                  { _add_to_list agent_cluster_roles "$@"; }

function add_agent_ocp_monitoring_promrules()       { _add_to_list agent_ocp_monitoring_promrules "$@"; }
function add_agent_ocp_monitoring_servicemonitors() { _add_to_list agent_ocp_monitoring_servicemonitors "$@"; }

#---------------------------#
# Resource nuking functions #
#---------------------------#

function nuke_webhooks_and_api_services() {

   echo "Disabling hub validating/mutating webhooks and API services."

   nuke_cluster_kind_matching_name_patterns "mutatingwebhookconfiguration" mutating_webhooks
   nuke_cluster_kind_matching_name_patterns "validatingwebhookconfiguration" validating_webhooks

   nuke_cluster_kind_matching_name_patterns "apiservice" api_services
}

function nuke_conversion_webhooks() {

   echo "Disabling hub conversion webhooks."

   zorch_conversion_webhooks_from_crs_matching_kind_patterns sub_operator_operand_kinds
   zorch_conversion_webhooks_from_crs_matching_kind_patterns hub_cr_kinds
}

function nuke_the_top_operators() {

   echo "Removing top-level hub OLM operators."

   local mch_op_ns="${MCH_SUB_NS:-${MCH_OP_NS:-${MCH_NS}}}"
   nuke_olm_operator_from_namespace "$MCH_PKG_NAME" "$mch_op_ns"

   local mce_op_ns="${MCE_SUB_NS:-${MCE_OP_NS:-${MCE_NS}}}"
   nuke_olm_operator_from_namespace "$MCE_PKG_NAME" "$mce_op_ns"
}

function nuke_sub_operator_operands() {

   # This deletes the CR instances that define operands that are monigored
   # and reconsiled by sub-operators integrated into the MCE or MCH package.

   echo "Removing hub sub-operator operand resources and CRDs."

   nuke_crs_matching_kind_patterns sub_operator_operand_kinds
}

function nuke_sub_operator_installed_operators() {

   # This deletes the OLM subscriptsion and CSVs for OLM operator dependencies
   # that are managed by an operand sub-operator.

   # TODO: We probably need to prevent the managing sub-operator from rereconsiling these?

   echo "Removing hub sub-operator installed OLM operators."

   local op_id
   for op_id in "${sub_operator_installed_operators[@]}"; do
      local op_ns=${op_id%/*}
      local op_pkg=${op_id#*/}
      nuke_olm_operator_from_namespace $op_pkg $op_ns
   done
}

function nuke_all_the_hub_pods() {

   # Gets rid of pods in all known hub namespaces

   echo "Deleting pods from top-level hub namespaces."
   nuke_pods_from_namespaces hub_top_pod_namespaces "top pod namespaces"

   echo "Deleting pods from other hub namespaces."
   nuke_pods_from_namespaces hub_pod_namespaces "other pod namespaces"
}

function nuke_managed_cluster() {

   local mc_name="$1"

   local k
   for k in manifestwork managedclusteraddon observabilityaddon rolebinding; do
      nuke_kind_from_namespace "$k" "$mc_name"
   done

   delete_namespace "$mc_name"
   nuke_cluster_resource "managedcluster/$mc_name"
}

function nuke_managed_clusters() {

   local inst_list=$(oc get "managedcluster" -o name 2> /dev/null)
   if [[ -z "$inst_list" ]]; then
      return
   fi

   echo "Removing all managed clusters."

   local inst
   for inst in $inst_list; do
      local mc_name="${inst#*/}"
      echo "Removing managed cluster $mc_name."
      nuke_managed_cluster "$mc_name"
   done
}

function nuke_managed_cluster_remnants() {

   # Detect namespaces that appear to be remnanats of a managed cluster and clean
   # these htings up.  (These things would be cleaned up by nick_managed_cluster
   # if a ManagedCluster reosurce was left around.)

   local ns_list=$(oc get ns -l"cluster.open-cluster-management.io/managedCluster" -o name)
   if [[ -z "$ns_list" ]]; then
      return
   fi

   echo "Cleaning up namespaces that are remnants of a managed cluster."
   local n
   for ns in "$ns_list"; do
      ns_name="${ns#*/}"
      echo "Removing remnant managed-cluster namespace $ns_name."
      nuke_managed_cluster "$ns_name"
   done
}


function run_hub_special_resource_patchers() {

   local patcher
   for patcher in "${hub_resource_patchers[@]}"; do
       $patcher
   done
}

function nuke_hub_cr_kinds() {

   echo "Removing hub custom resources and CRDs."
   nuke_crs_matching_kind_patterns hub_cr_kinds
}

function nuke_cluster_roles() {

   local patterns_array_name="$1"
   local -n patterns="$patterns_array_name"

   local jp=$(jsonpath_range_over_items ".roleRef.name" ".metadata.name")
   local t=$(oc get "clusterrolebindings" -o jsonpath="$jp")
   if [[ -n "$t" ]]; then

      # NB: This is a little sloppy, as we're not restricting the match to just the role-ref.
      # On the other hand, the sloppiness might benefit us as it might also ferret out a
      # role binding to a Openshift-defined role if the role-binding name matches the
      # nameing pattern of one of our roles.

      local pattern
      for pattern in "${patterns[@]}"; do
         local hits=$(grep "$pattern" <<< "$t")
         if [[ -n "$hits" ]]; then
            local line
            while read line; do
               local role_ref=$(extract_delimited_field 1 "/" "$line")
               local binding_name=$(extract_delimited_field 2 "/" "$line")
               delete_cluster_resource "clusterrolebinding/$binding_name"
            done <<< "$hits"
         fi
      done
   fi

   nuke_cluster_kind_matching_name_patterns "clusterrole" "$patterns_array_name"
}

function nuke_hub_cluster_roles() {

   echo "Deleting hub cluster roles and bindings to them."
   nuke_cluster_roles hub_cluster_roles
}

function nuke_cluster_role_bindings() {

   local patterns_array_name="$1"
   local -n patterns="$patterns_array_name"

   local jp=$(jsonpath_range_over_items ".metadata.name")
   local t=$(oc get "clusterrolebindings" -o jsonpath="$jp")
   if [[ -n "$t" ]]; then
      local pattern
      for pattern in "${patterns[@]}"; do
         local hits=$(grep "$pattern" <<< "$t")
         if [[ -n "$hits" ]]; then
            local line
            while read line; do
               local binding_name=$(extract_delimited_field 1 "/" "$line")
               delete_cluster_resource "clusterrolebinding/$binding_name"
            done <<< "$hits"
         fi
      done
   fi
}

function nuke_hub_cluster_role_bindings() {

   echo "Deleting hub cluster role bindings."
   nuke_cluster_role_bindings hub_cluster_role_bindings
}

function nuke_hub_console_plugins() {

   echo "Deleting hub console plugins."

   for plugin in "${hub_console_plugins[@]}"; do
      nuke_cluster_resource "consoleplugins.console.openshift.io/$plugin"
  done
}

function nuke_hub_ocp_monitoring_additions() {

   echo "Deleting hub addiitons made to openshift-monitoring namespace."

   nuke_kind_from_namespace_matching_name_patterns "servicemonitor" \
      "openshift-monitoring" hub_ocp_monitoring_servicemonitors
   nuke_kind_from_namespace_matching_name_patterns "prometheusrule" \
      "openshift-monitoring" hub_ocp_monitoring_promrules
}

function nuke_top_operand_kinds() {

   echo "Removing hub top-operator operand resources and CRDs."
   nuke_crs_matching_kind_patterns top_operator_operand_kinds
}

function delete_hub_namespaces() {

   echo "Deleting hub namespaces."

   delete_namespaces hub_top_pod_namespaces
   delete_namespaces hub_pod_namespaces
   delete_namespaces hub_other_namespaces
}

function nuke_all_the_agent_pods() {

   # Gets rid of pods that will exist of the hub cluster is imported.

   echo "Deleting pods from agent namespaces."
   nuke_pods_from_namespaces agent_pod_namespaces "agent pod namespaces"
}

function nuke_agent_webhooks_and_api_services() {

   echo "Disabling agent API services."

   nuke_cluster_kind_matching_name_patterns "apiservice" agent_api_services
}

function run_agent_special_resource_patchers() {

   local patcher
   for patcher in "${agent_resource_patchers[@]}"; do
       $patcher
   done
}

function nuke_agent_cr_kinds() {

   echo "Removing agent custom resources and CRDs."
   nuke_crs_matching_kind_patterns agent_cr_kinds
}

function nuke_agent_cluster_roles() {

   echo "Deleting agent cluster roles and bindings to them."
   nuke_cluster_roles agent_cluster_roles
}

function delete_agent_namespaces() {

   echo "Deleting agent namespaces."

   delete_namespaces agent_pod_namespaces
   delete_namespaces hub_other_namespaces
}

function nuke_agent_ocp_monitoring_additions() {

   echo "Deleting agent addiitons made to openshift-monitoring namespace."

   nuke_kind_from_namespace_matching_name_patterns "servicemonitor" \
      "openshift-monitoring" agent_ocp_monitoring_servicemonitors
   nuke_kind_from_namespace_matching_name_patterns "prometheusrule" \
      "openshift-monitoring" agent_ocp_monitoring_promrules
}


#----------------------------------------------#
# Per-component resource identifying functions #
#----------------------------------------------#

add_hub_components ai
function identify_hub_ai_things() {

   local component="ai"

   add_api_services        "$component" "v1.admission.agentinstall.openshift.io"
   add_mutating_webhooks   "$component" ".admission.agentinstall.openshift.io"
   add_validating_webhooks "$component" ".admission.agentinstall.openshift.io"

   add_sub_operator_operand_kinds "$component" "/agentserviceconfigs.agent-install.openshift.io"

   add_hub_cluster_roles "$component" "system:openshift:assisted-installer:"
   add_hub_cr_kinds      "$component" ".agent-install.openshift.io"
}

add_hub_components hive
function identify_hub_hive_things() {

   local component="hive"

   add_api_services        "$component" "v1.admission.hive.openshift.io"
   add_mutating_webhooks   "$component" ".admission.hive.openshift.io"
   add_validating_webhooks "$component" ".admission.hive.openshift.io"

   add_sub_operator_operand_kinds "$component" "hiveconfigs.hive.openshift.io"
   add_hub_pod_namespaces         "$component" "hive"

   add_hub_cluster_roles "$component" "hive-admin"
   add_hub_cluster_roles "$component" "hive-cluster-pool-admin"
   add_hub_cluster_roles "$component" "hive-controllers"
   add_hub_cluster_roles "$component" "hive-frontend"
   add_hub_cluster_roles "$component" "hive-reader"
   add_hub_cluster_roles "$component" "system:openshift:hive:hiveadmission"

   add_hub_cr_kinds "$component" ".hive.openshift.io"
   add_hub_cr_kinds "$component" ".hiveinternal.openshift.io"
}

add_hub_components hypershift
function identify_hub_hypershift_things() {

   local component="hypershift"

   add_sub_operator_operand_kinds "$component" "/hypershiftagentserviceconfigs.agent-install.openshift.io"
   add_hub_pod_namespaces         "$component" "hypershift"

   add_hub_cluster_roles "$component" "hypershift-operator"
   add_hub_cluster_roles "$component" "open-cluster-management:hypershift-preview:hypershift-addon-manager"
}

add_hub_components cluster_manager
function identify_hub_cluster_manager_things() {

   local component="cluster_manager"

   add_api_services "$component" ".admission.cluster.open-cluster-management.io"
   add_api_services "$component" ".admission.work.open-cluster-management.io"
   add_api_services "$component" ".clusterview.open-cluster-management.io"
   add_api_services "$component" ".clusterview.open-cluster-management.io"

   add_api_services "$component" ".agent.open-cluster-management.io"

   add_mutating_webhooks "$component" ".admission.cluster.open-cluster-management.io"
   add_mutating_webhooks "$component" "ocm-mutating-webhook"

   add_validating_webhooks "$component" ".admission.cluster.open-cluster-management.io"
   add_validating_webhooks "$component" ".admission.work.open-cluster-management.io"
   add_validating_webhooks "$component" "ocm-validating-webhook"

   add_sub_operator_operand_kinds "$component" "clustermanagers.operator.open-cluster-management.io"
   add_hub_pod_namespaces         "$component" "open-cluster-management-hub"
   add_hub_other_namespaces       "$component" "open-cluster-management-global-set"

   add_hub_cluster_roles "$component" "multicluster-engine:"
   add_hub_cluster_roles "$component" "open-cluster-management:"
   add_hub_cluster_roles "$component" "open-cluster-management.cluster-lifecycle"
   add_hub_cluster_roles "$component" "server-foundation-inject-admin"
   add_hub_cluster_roles "$component" "server-foundation-inject-view"

   add_hub_resource_patchers "$component" "cluster_manager_patch_default_mcs"

   add_hub_cr_kinds "$component" ".imageregistry.open-cluster-management.io"
   add_hub_cr_kinds "$component" ".internal.open-cluster-management.io"
   add_hub_cr_kinds "$component" ".view.open-cluster-management.io"
   add_hub_cr_kinds "$component" ".work.open-cluster-management.io"
   add_hub_cr_kinds "$component" ".addon.open-cluster-management.io"
   add_hub_cr_kinds "$component" ".action.open-cluster-management.io"

   # We want to get rid of all .cluster.open-cluster-management.io"kinds except for
   # ManagedClusterers since we handle them specially.

   local crd_list=$(oc get crd -o name | grep ".cluster.open-cluster-management.io")
   for crd in $crd_list; do
      if [[ "$crd" != "managedclusters.cluster.open-cluster-management.io" ]]; then
         add_hub_cr_kinds "$component"  "$crd"
      fi
   done
}

function cluster_manager_patch_default_mcs() {

   # We disable the conversation webhook for the The ManagedClusterset CR,
   # which rendersthe default one subce ut gas selectorType: LegacyClusterSetLabel.
   # Patch it to fix it.

   local mcs="managedclustersets.cluster.open-cluster-management.io"
   if oc get "$mcs/default" -o name > /dev/null 2>&1; then
      echo "Patching default ManagedClusterSet."
      oc patch "managedclusterset/default" \
         --type=merge -p '{"spec": {"clusterSelector": {"selectorType": "LabelSelector"}}}'
   fi
}

add_hub_components cluster_proxy
function identify_hub_cluster_proxy_things() {

   local component="cluster_proxy"

   add_api_services       "$component" ".proxy.open-cluster-management.io"
   add_hub_pod_namespaces "$component" "default-broker"
   add_hub_cr_kinds       "$component" ".proxy.open-cluster-management.io"
}

add_hub_components managed_service_account
function identify_hub_managed_service_account_things() {

   # Since ACM 2.8

   local component="managed_service_account"
   add_hub_cluster_roles "$component" "open-cluster-management:managed-serviceaccount:"
}

add_hub_components discovery
function identify_hub_discovery_things() {

   local component="discovery"
   add_hub_cr_kinds "$component" ".discovery.open-cluster-management.io"
}

add_hub_components console_mce
function identify_hub_console_mce_things() {

   local component="console_mce"

   add_hub_cr_kinds        "$component" ".console.open-cluster-management.io"
   add_hub_console_plugins "$component" "mce"
}

add_hub_components console_acm
function identify_hub_console_acm_things() {

   local component="console_acm"

   add_hub_cr_kinds        "$component" ".console.open-cluster-management.io"
   add_hub_console_plugins "$component" "acm"
}

add_hub_components clc
function identify_hub_clc_things() {

   local component="clc"
   add_hub_cr_kinds "$component" "clustercurators.cluster.open-cluster-management.io "
}

add_hub_components mce_operator
function identify_hub_mce_operator_things() {

   # We omit things related to the MCE resource itself, since that is handled specially.

   local component="mce_operator"

   add_validating_webhooks    "$component" "multiclusterengines.multicluster.openshift.io"

   add_hub_top_pod_namespaces "$component" "$MCE_NS"
   add_hub_top_pod_namespaces "$component" "$MCE_OP_NS"

   add_hub_top_pod_namespaces "$component" "$MCE_OP_NS"
   add_hub_other_namespaces   "$component" "$MCE_SUB_NS"

   add_hub_cluster_roles      "$component" "multiclusterengines.multicluster.openshift.io"
   # These don't really belong to the MCE operator?
   add_hub_cluster_roles      "$component" "multicluster-engine:"

   add_top_operator_operand_kinds "$component" "multiclusterengines.multicluster.openshift.io"
}

add_hub_components mch_operator
function identify_hub_mch_operator_things() {

   # NB: We omit things related to the MCH resource itself, since that is handled specially.

   local component="mch_operator"

   add_validating_webhooks    "$component" "multiclusterhub-operator-validating-webhook"

   add_hub_top_pod_namespaces "$component" "$MCH_NS"
   add_hub_top_pod_namespaces "$component" "$MCH_OP_NS"
   add_hub_other_namespaces   "$component" "$MCH_SUB_NS"

   add_hub_cluster_roles "$component" "multiclusterhubs.operator.open-cluster-management.io"
   add_hub_cluster_roles "$component" ".submarineraddon.open-cluster-management.io"

   add_top_operator_operand_kinds "$component" "multiclusterhubs.operator.open-cluster-management.io"
}

add_hub_components appsub
function identify_hub_appsub_things() {

   local component="appsub"

   add_validating_webhooks "$component" "application-webhook-validator"
   add_validating_webhooks "$component" "channels.apps.open.cluster.management.webhook.validator"
   add_hub_cr_kinds        "$component" ".apps.open-cluster-management.io "
   add_hub_cr_kinds        "$component" "applications.app.k8s.io"
}

add_hub_components grc
function identify_hub_grc_things() {

   local component="grc"

   add_hub_cr_kinds "$component" ".policy.open-cluster-management.io"

   add_hub_cluster_roles "$component" "open-cluster-management:governance-policy-framework-crd"  # 2.7
   add_hub_cluster_roles "$component" "open-cluster-management:governance-policy-framework"      # 2.8

   add_hub_ocp_monitoring_servicemonitors "$component" "ocm-grc-policy-propagator-metrics"
   add_hub_ocp_monitoring_promrules       "$component" "ocm-grc-policy-propagator-metrics"
}

add_hub_components mco
function identify_hub_mco_things() {

   local component="mco"

   add_validating_webhooks        "$component" "multicluster-observability-operator"
   add_sub_operator_operand_kinds "$component" "multiclusterobservabilities.observability.open-cluster-management.io"
   add_hub_top_pod_namespaces     "$component" "open-cluster-management-observability"

   add_hub_cluster_roles "$component" "endpoint-observability-mco-role"
   add_hub_cluster_roles "$component" "endpoint-observability-res-role"
   add_hub_cluster_roles "$component" "observabilityaddons.observability.open-cluster-management.io"
   add_hub_cluster_roles "$component" "multiclusterobservabilities.observability.open-cluster-management.io"
   add_hub_cr_kinds      "$component"  ".observability.open-cluster-management.io"

   add_hub_cluster_roles "$component" ".core.observatorium.io"
   add_hub_cr_kinds      "$component" ".core.observatorium.io"

   add_hub_cluster_roles         "$component" "openshift-adp-metrics-reader"   # XXX: Is this really ours?
   add_hub_cluster_role_bindings "$component" "metrics-collector-view"

   add_hub_ocp_monitoring_servicemonitors "$component" "observability-observatorium-"
   add_hub_ocp_monitoring_servicemonitors "$component" "observability-thanos-"

   # TODO: Move to an insighs component:

   add_hub_cr_kinds                       "$component" "policyreports.wgpolicyk8s.io"
   add_hub_ocp_monitoring_servicemonitors "$component" "acm-insights"

   # Added for ACM 2.8:
   #
   # TODO: These are created, but it seems that happens as a result of ACM enabling
   # user-workload monitoring by changing the settings in the cluster-monitoring-config
   # ConfigMap in the openshift-monitoring namespace.

   # add_hub_cluster_roles         "$component"  "prometheus-user-workload"
   # add_hub_cluster_roles         "$component"  "prometheus-user-workload-operator"
   # add_hub_cluster_roles         "$component"  "thanos-ruler"
   # add_hub_cluster_role_bindings "$component"  "thanos-ruler-monitoring"

   # These will go away if you reconfigure to turn off user-workload monitoring.
   # But we have no way to know that ACM is the thing that turned it on and is the
   # only thing on the cluster that has an interest in having it on.

   if [[ $nuke_user_resource_monitoring -ne 0 ]]; then
      add_hub_resource_patchers "$component" "observability_disable_user_workload_monitoring"
   fi
}

function observability_disable_user_workload_monitoring() {

   # Used for both huub and agent cleanup.

   echo "Disabling openshift user-workload monitoring."
   oc -n openshift-monitoring patch cm cluster-monitoring-config \
      --type=merge -p '{"data": {"config.yaml": "enableUserWorkload: false\n"}}'
   oc delete clusterrolebinding thanos-ruler-monitoring
}

add_hub_components search
function identify_hub_search_things() {

   local component="search"

   add_sub_operator_operand_kinds       "$component" "searches.search.open-cluster-management.io"

   add_hub_cr_kinds "$component" ".search.open-cluster-management.io"

   # Added in ACM 2.8:
   add_hub_cluster_roles                  "$component" "search"
   add_hub_ocp_monitoring_servicemonitors "$component" "search-api-monitor"
   add_hub_ocp_monitoring_servicemonitors "$component" "search-indexer-monitor"

}

add_hub_components cluster_backup
function identify_hub_cluster_backup_things() {

   add_sub_operator_installed_operators "$component" "open-cluster-management-backup/redhat-oadp-operator"

   add_hub_pod_namespaces "$component" "open-cluster-management-backup"
   add_hub_cr_kinds       "$component" "backupschedules.cluster.open-cluster-management.io"
   add_hub_cr_kinds       "$component" "restores.cluster.open-cluster-management.io"
   add_hub_cluster_roles  "$component" "open-cluster-management:cluster-backup-"

   add_hub_cluster_roles  "$component" "dpa-editor-role"
   add_hub_cluster_roles  "$component" "dpa-viewer-role"

   if [[ $nuke_velero -ne 0 ]]; then
      add_hub_cr_kinds "$component" ".velero.io"

      add_hub_cluster_role_bindings "$component" "backupstoragelocations.velero.io-"
      add_hub_cluster_role_bindings "$component" "backups.velero.io-"
      add_hub_cluster_role_bindings "$component" "dataprotectionapplications.oadp.openshift.io-"
      add_hub_cluster_role_bindings "$component" "deletebackuprequests.velero.io-"
      add_hub_cluster_role_bindings "$component" "downloadrequests.velero.io-"
      add_hub_cluster_role_bindings "$component" "podvolumebackups.velero.io-"
      add_hub_cluster_role_bindings "$component" "resticrepositories.velero.io-v1-edit"
      add_hub_cluster_role_bindings "$component" "restores.velero.io-v1-admin"
      add_hub_cluster_role_bindings "$component" "restores.velero.io-v1-crdview"
      add_hub_cluster_role_bindings "$component" "schedules.velero.io-v1-admin"
      add_hub_cluster_role_bindings "$component" "serverstatusrequests.velero.io-v1-admin"
      add_hub_cluster_role_bindings "$component" "volumesnapshotlocations.velero.io-"
   fi

   if [[ $nuke_oadp -ne 0 ]]; then
      add_hub_cr_kinds "$component" ".oadp.openshift.io"

      add_hub_cluster_role_bindings "$component" "cloudstorages.oadp.openshift.io-"
      add_hub_cluster_role_bindings "$component" "volumesnapshotbackups.datamover.oadp.openshift.io-"
      add_hub_cluster_role_bindings "$component" "volumesnapshotrestores.datamover.oadp.openshift.io-"
   fi
}

add_hub_components submariner
function identify_hub_submariner_things() {

   add_hub_cluster_roles "$component" ".submarineraddon.open-cluster-management.io"
   add_hub_cluster_roles "$component" "access-to-brokers-submariner-crd"
   add_hub_cr_kinds      "$component" ".submarineraddon.open-cluster-management.io"
}

add_agent_components foundation
function identify_agent_foundation_things() {

   local component="foundation"

   add_agent_pod_namespaces "$component" "open-cluster-management-agent"
   add_agent_pod_namespaces "$component" "open-cluster-management-agent-addon"

   add_agent_cr_kinds       "$component" "klusterletaddonconfigs.agent.open-cluster-management.io"
   add_agent_cr_kinds       "$componnet" "klusterlets.operator.open-cluster-management.io"
   add_agent_cr_kinds       "$componnet" ".work.open-cluster-management.io"

   add_agent_cluster_roles  "$component" "klusterlet"
   add_agent_cluster_roles  "$component" "open-cluster-management:klusterlet-addon-"
   add_agent_cluster_roles  "$component" "open-cluster-management:klusterlet-registration:"
   add_agent_cluster_roles  "$component" "open-cluster-management:klusterlet-work:"
   add_agent_cluster_roles  "$component" "open-cluster-management:management:klusterlet-registration:"

   add_agent_cluster_roles  "$component" "open-cluster-management:klusterlet-"
   add_agent_cluster_roles  "$component" "klusterlet-bootstrap-kubeconfig"
}

add_agent_components observability
function identify_agent_observability_things() {

   local component="observability"

   add_agent_pod_namespaces "$component" "open-cluster-management-addon-observability"
   add_agent_cr_kinds       "$component" ".observability.open-cluster-management.io"
   add_agent_cluster_roles  "$component" "metrics-collector-view"

   # Added for ACM 2.8:
   #
   # TODO: These are created, but it seems that happens as a result of ACM enabling
   # user-workload monitoring by changing the settings in the cluster-monitoring-config
   # ConfigMap in the openshift-monitoring namespace.

   # add_agent_cluster_roles "$component" "prometheus-user-workload"
   # add_agent_cluster_roles "$component" "prometheus-user-workload-operator"
   # add_agent_cluster_roles "$component" "thanos-ruler"

   if [[ $nuke_user_resource_monitoring -ne 0 ]]; then
      add_agent_resource_patchers "$component" "observability_disable_user_workload_monitoring"
   fi
}

add_agent_components grc
function identify_agent_grc_things() {

   local component="grc"

   add_agent_cr_kinds "$component" ".policy.open-cluster-management.io"

   add_agent_ocp_monitoring_servicemonitors "$component" "ocm-config-policy-controller-open-cluster-management-agent-addon-metrics"
   add_agent_ocp_monitoring_servicemonitors "$component" "ocm-governance-policy-framework-open-cluster-management-agent-addon-metrics"
}

add_agent_components alc
function identify_agent_alc_things() {

   local component="alc"

   add_agent_cr_kinds "$component" ".apps.open-cluster-management.io"
}

add_agent_components hypershift
function identify_agent_hypershift_things() {

   local component="hypershift"

   # Since ACM 2.8:

   add_agent_pod_namespaces "$component" "hypershiftr"

   add_agent_pod_namespaces "$component" "hypershift"
   add_agent_cluster_roles  "$component" "hypershift-addon-agent"
   add_agent_cluster_roles  "$component" "hypershift-operator"
   add_agent_cluster_roles  "$component" "open-cluster-management:hypershift-addon:agent"

   add_agent_cr_kinds "$component" ".cluster.x-k8s.io"
   add_agent_cr_kinds "$component" ".hypershift.openshift.io"
   add_agent_cr_kinds "$component" ".capi-provider.agent-install.openshift.io"

   add_agent_cr_kinds "$component" "clusterclaims.cluster.open-cluster-management.io"  # Is this really due to hypershift?

   add_agent_ocp_monitoring_servicemonitors "$component" "acm-hypershift-addon-agent-metrics"
}


# Main:

# Find signs of the MCE and MCH operators and/or operand instances.

find_mce_operator_things
find_mch_operator_things

# If we didn't find enough renmanats to identify the MCE or MCH operand namespaces,
# plug in the default namespace names so at least we'll attempt cleanup for them.

if [[ -z "$MCE_NS" ]]; then
   MCE_NS="multicluster-engine"
fi
if [[ -z "$MCH_NS" ]]; then
   MCH_NS="open-cluster-management"
fi

# Now that our basic resources are located (or not), run our identify functions
# to accumulate the various kinds of things we'll nuek and from where.

for component in "${hub_components[@]}"; do
    f="identify_hub_${component}_things"
    $f
done
for component in "${agent_components[@]}"; do
    f="identify_agent_${component}_things"
    $f
done

# Take out the top-level MCE and MCH operator pods so they don't try to fix any
# nuking we are about to do.

if [[ $do_hub_stuff -ne 0 ]]; then
   nuke_the_top_operators
fi

# Get rid of any OLM operator installed by our sub-operators for similar reason.

if [[ $do_hub_stuff -ne 0 ]]; then
   nuke_sub_operator_installed_operators
fi

# Now try to get rid of all running hub controllers and agent ones as well
# (since the hub is probably imported as a managed cluster)

if [[ $do_hub_stuff -ne 0 ]]; then
   nuke_all_the_hub_pods
fi

if [[ $do_agent_stuff -ne 0 ]]; then
   nuke_all_the_agent_pods
fi

# Hopefully all running hub pods are gone.  Now we need to clean up other custom
# or standard resources, many of whihc can be tricky to get rid of when we no
# longer have controllers/webhook services running.

# Get rud of webhoooks and API services definitions since they are likely failing
# or not available due to our having gotten rid of many operator pods already.


if [[ $do_hub_stuff -ne 0 ]]; then
   nuke_webhooks_and_api_services
   nuke_conversion_webhooks
fi

# Similarly, get rid of the operands of the known sub-operators in MCE and MCH
# (eg. AgentServiceConfig, HiveConfig, Searches) to make get rid of more stuff
# via garbage collection.

if [[ $do_hub_stuff -ne 0 ]]; then
   nuke_sub_operator_operands
fi

# Get rid of all ManagedClusters.

if [[ $do_hub_stuff -ne 0 ]]; then
   nuke_managed_clusters
   nuke_managed_cluster_remnants
fi

# Do special patching necessary to let us get rid of some troublemaking resources.

if [[ $do_hub_stuff -ne 0 ]]; then
   run_hub_special_resource_patchers
fi

# Get rid of hub custom resource instances and their CRDs.

if [[ $do_hub_stuff -ne 0 ]]; then
   nuke_hub_cr_kinds
fi

# Cleanup hub cluster roles, which will also get rid of bindings to them.
# But since we have some cluster-role bindings to cluster-roles we don't own
# we need to get rid of them explicitly too.


if [[ $do_hub_stuff -ne 0 ]]; then
   nuke_hub_cluster_roles
   nuke_hub_cluster_role_bindings
fi

# Get rid of miscellaneous tihings.

if [[ $do_hub_stuff -ne 0 ]]; then
   nuke_hub_console_plugins
   nuke_hub_ocp_monitoring_additions
fi

# Do cleanup of agent things (for when local-clsuter is imported)

if [[ $do_agent_stuff -ne 0 ]]; then
   nuke_all_the_agent_pods
   nuke_agent_webhooks_and_api_services
   run_agent_special_resource_patchers
   nuke_agent_cr_kinds
   nuke_agent_cluster_roles
   nuke_agent_ocp_monitoring_additions
fi

# Get rid of top-operator operands (MCE, MCH)

if [[ $do_hub_stuff -ne 0 ]]; then
   nuke_top_operand_kinds
fi

# Finally, delete hub and agent namespace.

if [[ $do_hub_stuff -ne 0 ]]; then
   delete_hub_namespaces
fi

if [[ $do_agent_stuff -ne 0 ]]; then
   delete_agent_namespaces
fi

exit 0

