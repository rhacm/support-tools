#!/bin/bash

# THIS IS A WORK IN PROGRESS.

# Copyright (c) 2023 Red Hat, Inc.
#
# Author: joeg-pro
#
# This script performs an agressive cleanup of an OCP cluster to remove all
# known remnants of MCE or ACM hub.  Its intended to be used to cleanup after
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


#-----------------------------#
# Message-blurting functions  #
#-----------------------------#

function msg() {
   echo "$@"
}

function wmsg() {
   echo "Warning:" "$@"
}

function emsg() {
   echo "Error:" "$@"
}

#-----------------------------------------#
# Lowest-level Resource nuking primitives #
#-----------------------------------------#

function do_chg() {

   if [[ $dry_run_mode -eq 0 ]]; then
      "$@"
      return $?
   else
      echo "WOULD-DO:" "$@"
      return 0
   fi
}

function do_chg_no_stdout() {
   if [[ $dry_run_mode -eq 0 ]]; then
      "$@" > /dev/null
      return $?
   else
      echo "WOULD-DO:" "$@"
      return 0
   fi
}

function do_chg_no_stderr() {
   if [[ $dry_run_mode -eq 0 ]]; then
      "$@" 2> /dev/null
      return $?
   else
      echo "WOULD-DO:" "$@"
      return 0
   fi
}

function patch_resource() {

   local dash_lower_n_opt=()
   if [[ "$1" == "-n" ]]; then
      dash_lower_n_opt=("$1" "$2")
      shift 2
   fi
   local kind_and_name="$1"
   shift 1

   do_chg_no_stdout oc "${dash_lower_n_opt[@]}" patch "$kind_and_name" "$@"
}

function zorch_finalizer() {

   local dash_lower_n_opt=()
   if [[ "$1" == "-n" ]]; then
      dash_lower_n_opt=("$1" "$2")
      shift 2
   fi

   local kind_and_name="$1"

   local get_json='{.metadata.finalizers}'
   local patch_json='{"metadata":{"finalizers":null}}'

   local finalizers=$(oc "${dash_lower_n_opt[@]}" get "$kind_and_name" -o "jsonpath=$get_json" 2> /dev/null)
   if [[ -n "$finalizers" ]]; then
      patch_resource "${dash_lower_n_opt[@]}" "$kind_and_name" --type=merge -p "$patch_json"
   fi
}

function delete_resource() {

   # Doesn't zorch finalizers, just deletes.

   local ns=""
   local dash_lower_n_opt=()
   if [[ "$1" == "-n" ]]; then
      ns="$2"
      dash_lower_n_opt=("$1" "$2")
      shift 2
   fi
   local kind_and_name="$1"

   if ! oc "${dash_lower_n_opt[@]}" get "$kind_and_name" -o yaml > /dev/null 2>&1; then
      return
   fi

   if [[ -n "$ns" ]]; then
      msg "Deleting $kind_and_name from namespace $ns."
   else
      msg "Deleting $kind_and_name."
   fi

   do_chg_no_stderr oc "${dash_lower_n_opt[@]}" delete --ignore-not-found --timeout=15s "$kind_and_name"
   if [[ $? -ne 0 ]]; then

      if [[ -n "$ns" ]]; then
         msg "Warniing: Could not delete $kind_and_name from namespace $ns (timeout)."
      else
         msg "Warniing: Could not delete $kind_and_name (timeout)."
      fi
   fi
}

function delete_resource_no_wait() {

   # Doesn't zorch finalizers, just deletes.  Doesn't wait.

   local ns=""
   local dash_lower_n_opt=()
   if [[ "$1" == "-n" ]]; then
      ns="$2"
      dash_lower_n_opt=("$1" "$2")
      shift 2
   fi
   local kind_and_name="$1"

   if ! oc "${dash_lower_n_opt[@]}" get "$kind_and_name" -o yaml > /dev/null 2>&1; then
      return
   fi

   if [[ -n "$ns" ]]; then
      msg "Deleting $kind_and_name from namespace $ns."
   else
      msg "Deleting $kind_and_name."
   fi

   do_chg_no_stderr oc "${dash_lower_n_opt[@]}" delete --ignore-not-found --wait=false "$kind_and_name"
   if [[ $? -ne 0 ]]; then

      if [[ -n "$ns" ]]; then
         msg "Warniing: Could not delete $kind_and_name from namespace $ns (timeout)."
      else
         msg "Warniing: Could not delete $kind_and_name (timeout)."
      fi
   fi
}

function nuke_resource() {

   local ns=""
   local dash_lower_n_opt=()
   if [[ "$1" == "-n" ]]; then
      ns="$2"
      dash_lower_n_opt=("$1" "$2")
      shift 2
   fi
   local kind_and_name="$1"

   if ! oc "${dash_lower_n_opt[@]}" get "$kind_and_name" -o yaml > /dev/null 2>&1; then
      return
   fi

   if [[ -n "$ns" ]]; then
      msg "Deleting $kind_and_name from namespace $ns."
   else
      msg "Deleting $kind_and_name."
   fi

   zorch_finalizer "${dash_lower_n_opt[@]}" "$kind_and_name"

   do_chg_no_stderr oc "${dash_lower_n_opt[@]}" delete --ignore-not-found --timeout=10s "$kind_and_name"
   if [[ $? -ne 0 ]]; then
      msg "Timeout waiting for deletion to occur, retrying."
      zorch_finalizer "${dash_lower_n_opt[@]}" "$kind_and_name"
      oc "${dash_lower_n_opt[@]}" delete --timeout=30s "$kind_and_name"
      if [[ $? -ne 0 ]]; then
         if [[ -n "$ns" ]]; then
            msg "Warning: Could not delete $kind_and_name from namespace $ns (timeout on retry)."
         else
            wmsg "Could not delete $kind_and_name (timeout on retry)."
         fi
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
         nuke_resource -n "$ns" "$inst"
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
            nuke_resource "$inst"
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
         nuke_resource "$line"
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
            nuke_resource -n "$ns" "$line"
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
            msg "Removing conversion webhook from CRD ${crd#*/}."
            patch_resource "$crd" --type=merge -p '{"spec":{"conversion": null}}'
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
         delete_resource_no_wait "$crd"
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
   msg "Pausing a bit to allow instance deletion to occur."
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
         msg "Note: Instances of CR $crd remain, maybe blocked by finalizers."
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
               nuke_resource -n "$inst_ns" "$kind/$inst_name"
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

   msg "Deleeting pods and higher-level apps from namespace $ns."

   local kinds="deployments statefulsets"
   local need_to_pause=0
   local kind
   for kind in $kinds; do
      inst_list=$(oc -n "$ns" get "$kind" -o name)
      if [[ -n "$inst_list" ]]; then
          msg "   ...Deleting $kind"
          need_to_pause=1
          local inst
          for inst in $inst_list; do
             nuke_resource -n "$ns" "$inst"
          done
      fi
   done

   if [[ $dry_run_mode -eq 0 ]]; then
      if [[ $need_to_pause -ne 0 ]]; then
         msg "Pausing a bit."
         sleep 10
      fi
   fi

   local inst_list=$(oc -n "$ns" get pods -o name)
   if [[ -z "$inst_list" ]]; then
      msg "...All pods are gone"
      return
   fi

   local inst_list=$(oc -n "$ns" get replicasets -o name)
   if [[ -n "$inst_list" ]]; then
      msg "Deleeting replicasets explicitly."

      local inst
      for inst in $inst_list; do
         nuke_resource -n "$ns" "$inst"
      done

      if [[ $dry_run_mode -eq 0 ]]; then
         msg "Pausing a bit."
         sleep 10
      fi
   fi

   local inst_list=$(oc -n "$ns" get pods -o name)
   if [[ -z "$inst_list" ]]; then
      msg "...All pods are gone"
      return
   fi

   msg "Deleeting pods explicitly."

   local inst
   for inst in $inst_list; do
      nuke_resource -n "$ns" "$inst"
   done

   if [[ $dry_run_mode -eq 0 ]]; then
      msg "Pausing a bit."
      sleep 10
   fi

   inst_list=$(oc -n "$ns" get pods -o name)
   if [[ -z "$inst_list" ]]; then
      msg "...All pods are gone"
   else
      if [[ $dry_run_mode -eq 0 ]]; then
         wmsg "Pods still remain in namespace $ns, giving up on deleting them."
      fi
   fi

   msg "Deleting leases."
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

   if [[ $dry_run_mode -ne 0 ]]; then
      local max_passes=1
   else
      local max_passes=3
   fi

   msg "Removing $msg_nuking_what from $msg_from_where."
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
                  msg "Performing pass $pass..."
                  blurted_pass_msg=1
               fi
               if [[ $blurted_kind_msg -eq 0 ]]; then
                   msg "...Deleting all $kind"
                   blurted_kind_msg=1
               fi
               nuked_something=1
               local inst
               for inst in $inst_list; do
                  nuke_resource -n "$ns" "$inst"
               done
            fi
         done
      done
      if [[ $nuked_something -ne 0 ]]; then
         if [[ $dry_run_mode -eq 0 ]]; then
            msg "...Pausing a bit"
            sleep 10
         fi
      else
         # Nothing left, no need for another pass.
         break
      fi
   done

   if ! _workload_resources_exist_in_namespaces "$ns_list_name" "$kinds"; then
      msg "All $msg_nuking_what are gone."
      return 0
   else

      if [[ $dry_run_mode -eq 0 ]]; then
         wmsg "$msg_nuking_what remain after $max_passes passes, giving up."
         return 1
      else
         return 0
      fi
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
         delete_resource -n "$sub_ns" "sub/$sub_name"
      done <<< "$t"
   fi

   local t=$(find_csvs_for_operator "$pkg_name" "." "$op_ns")
   if [[ -n "$t" ]]; then
      local line
      while read line; do
         local csv_pkg=$(extract_delimited_field 1 "/" "$line")
         local csv_ns=$(extract_delimited_field 2 "/" "$line")
         local csv_name=$(extract_delimited_field 3 "/" "$line")
         delete_resource -n "$csv_ns" "csv/$csv_name"
      done <<< "$t"
   fi
}

function delete_namespace() {

   local ns="$1"
   delete_resource "ns/$ns"
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

   msg "Disabling hub validating/mutating webhooks and API services."

   nuke_cluster_kind_matching_name_patterns "mutatingwebhookconfiguration" mutating_webhooks
   nuke_cluster_kind_matching_name_patterns "validatingwebhookconfiguration" validating_webhooks

   nuke_cluster_kind_matching_name_patterns "apiservice" api_services
}

function nuke_conversion_webhooks() {

   msg "Disabling hub conversion webhooks."

   zorch_conversion_webhooks_from_crs_matching_kind_patterns sub_operator_operand_kinds
   zorch_conversion_webhooks_from_crs_matching_kind_patterns hub_cr_kinds
}

function nuke_the_top_operators() {

   msg "Removing top-level hub OLM operators."

   local mch_op_ns="${MCH_SUB_NS:-${MCH_OP_NS:-${MCH_NS}}}"
   nuke_olm_operator_from_namespace "$MCH_PKG_NAME" "$mch_op_ns"

   local mce_op_ns="${MCE_SUB_NS:-${MCE_OP_NS:-${MCE_NS}}}"
   nuke_olm_operator_from_namespace "$MCE_PKG_NAME" "$mce_op_ns"
}

function nuke_sub_operator_operands() {

   # This deletes the CR instances that define operands that are monigored
   # and reconsiled by sub-operators integrated into the MCE or MCH package.

   msg "Removing hub sub-operator operand resources and CRDs."

   nuke_crs_matching_kind_patterns sub_operator_operand_kinds
}

function nuke_sub_operator_installed_operators() {

   # This deletes the OLM subscriptsion and CSVs for OLM operator dependencies
   # that are managed by an operand sub-operator.

   # TODO: We probably need to prevent the managing sub-operator from rereconsiling these?

   msg "Removing hub sub-operator installed OLM operators."

   local op_id
   for op_id in "${sub_operator_installed_operators[@]}"; do
      local op_ns=${op_id%/*}
      local op_pkg=${op_id#*/}
      nuke_olm_operator_from_namespace $op_pkg $op_ns
   done
}

function nuke_all_the_hub_pods() {

   # Gets rid of pods in all known hub namespaces

   msg "Deleting pods from top-level hub namespaces."
   nuke_pods_from_namespaces hub_top_pod_namespaces "top pod namespaces"

   msg "Deleting pods from other hub namespaces."
   nuke_pods_from_namespaces hub_pod_namespaces "other pod namespaces"
}

function nuke_managed_cluster() {

   local mc_name="$1"

   local k
   for k in manifestwork managedclusteraddon observabilityaddon rolebinding; do
      nuke_kind_from_namespace "$k" "$mc_name"
   done

   delete_namespace "$mc_name"
   nuke_resource "managedcluster/$mc_name"
}

function nuke_managed_clusters() {

   local inst_list=$(oc get "managedcluster" -o name 2> /dev/null)
   if [[ -z "$inst_list" ]]; then
      return
   fi

   msg "Removing all managed clusters."

   local inst
   for inst in $inst_list; do
      local mc_name="${inst#*/}"
      msg "Removing managed cluster $mc_name."
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

   msg "Cleaning up namespaces that are remnants of a managed cluster."
   local n
   for ns in "$ns_list"; do
      ns_name="${ns#*/}"
      msg "Removing remnant managed-cluster namespace $ns_name."
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

   msg "Removing hub custom resources and CRDs."
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
               delete_resource "clusterrolebinding/$binding_name"
            done <<< "$hits"
         fi
      done
   fi

   nuke_cluster_kind_matching_name_patterns "clusterrole" "$patterns_array_name"
}

function nuke_hub_cluster_roles() {

   msg "Deleting hub cluster roles and bindings to them."
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
               delete_resource "clusterrolebinding/$binding_name"
            done <<< "$hits"
         fi
      done
   fi
}

function nuke_hub_cluster_role_bindings() {

   msg "Deleting hub cluster role bindings."
   nuke_cluster_role_bindings hub_cluster_role_bindings
}

function nuke_hub_console_plugins() {

   msg "Deleting hub console plugins."

   for plugin in "${hub_console_plugins[@]}"; do
      nuke_resource "consoleplugins.console.openshift.io/$plugin"
  done
}

function nuke_hub_ocp_monitoring_additions() {

   msg "Deleting hub addiitons made to openshift-monitoring namespace."

   nuke_kind_from_namespace_matching_name_patterns "servicemonitor" \
      "openshift-monitoring" hub_ocp_monitoring_servicemonitors
   nuke_kind_from_namespace_matching_name_patterns "prometheusrule" \
      "openshift-monitoring" hub_ocp_monitoring_promrules
}

function nuke_top_operand_kinds() {

   msg "Removing hub top-operator operand resources and CRDs."
   nuke_crs_matching_kind_patterns top_operator_operand_kinds
}

function delete_hub_namespaces() {

   msg "Deleting hub namespaces."

   delete_namespaces hub_top_pod_namespaces
   delete_namespaces hub_pod_namespaces
   delete_namespaces hub_other_namespaces
}

function nuke_all_the_agent_pods() {

   # Gets rid of pods that will exist of the hub cluster is imported.

   msg "Deleting pods from agent namespaces."
   nuke_pods_from_namespaces agent_pod_namespaces "agent pod namespaces"
}

function nuke_agent_webhooks_and_api_services() {

   msg "Disabling agent API services."

   nuke_cluster_kind_matching_name_patterns "apiservice" agent_api_services
}

function run_agent_special_resource_patchers() {

   local patcher
   for patcher in "${agent_resource_patchers[@]}"; do
       $patcher
   done
}

function nuke_agent_cr_kinds() {

   msg "Removing agent custom resources and CRDs."
   nuke_crs_matching_kind_patterns agent_cr_kinds
}

function nuke_agent_cluster_roles() {

   msg "Deleting agent cluster roles and bindings to them."
   nuke_cluster_roles agent_cluster_roles
}

function delete_agent_namespaces() {

   msg "Deleting agent namespaces."

   delete_namespaces agent_pod_namespaces
   delete_namespaces hub_other_namespaces
}

function nuke_agent_ocp_monitoring_additions() {

   msg "Deleting agent addiitons made to openshift-monitoring namespace."

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
      msg "Patching default ManagedClusterSet."
      patch_resource "managedclusterset/default" \
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

   msg "Disabling openshift user-workload monitoring."
   patch_resource openshift-monitoring "cm/cluster-monitoring-config" \
      --type=merge -p '{"data": {"config.yaml": "enableUserWorkload: false\n"}}'
   delete_resource "clusterrolebinding/thanos-ruler-monitoring"
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

# Arg processing.

opt_flags="w:dadyz"

nuking_confirme=0
hub_or_agent="both"
nuke_dependencies=0
dry_run_mode=0

while getopts "$opt_flags" OPTION; do

   if [[ $OPTARG == "-"* ]]; then
      # We don't expect any option args that start with a dash, so getopt is likely
      # consuming the next option as if it were this options argument because the
      # argument is missing in the invocation.

      >&2 msg "Error: Argument for -$OPTION option is missing."
      exit 1
   fi

   case "$OPTION" in
      d) dry_run_mode=1
         ;;
      w) hub_or_agent="$OPTARG"
         ;;
      y) nuking_confirmed=1
         ;;
      z) nuke_dependencies=1
         ;;
      ?) exit 1
         ;;
   esac
done
shift "$(($OPTIND -1))"

do_hub_stuff=0
do_agent_stuff=0

if [[ "$hub_or_agent" == "agent" ]]; then
   msg "PErforming cleanup of ACM/MCE agent components."
   do_agent_stuff=1
elif [[ "$hub_or_agent" == "hub" ]]; then
   msg "PErforming cleanup of ACM/MCE hub components."
   do_hub_stuff=1
elif [[ "$hub_or_agent" == "both" ]]; then
   msg "PErforming cleanup of ACM/MCE hub and agent components."
   do_agent_stuff=1
   do_hub_stuff=1
else
   msg "Unrecognized argument for -w flag: $hub_or_agent."
   exit 5
fi

if [[ $nuke_dependencies -ne 0 ]]; then

   # TODO: Allow these to be requested individually.

   msg "Will also perform cleanup the following depenedncies:"
   msg "- Removing Red Hat OADP resources"
   msg "- Removing Valero reources"
   msg "- Removing selected Prometheus dependencies"
   msg "- Disabling user-workload monitoring"
   nuke_velero=1
   nuke_oadp=1
   nuke_prometheus=1
   nuke_user_resource_monitoring=1
fi

if [[ $nuking_confirmed -eq 0 ]] && [[ $dry_run_mode -eq 0 ]]; then
   msg ""
   msg "WARNING:"
   msg ""
   msg "This script performs an agressive cleanup of typical remnants of an ACM"
   msg "or MCE hub or agent install.  Its intended to be sed to cleanup after a"
   msg "failed install or uninstall in order to prepare the OCP cluster ffor a"
   msg "new install attempt."
   msg ""
   msg "USE  OF THIS SCRIPT WILL RESULT IN THE DELETION/LOSS OF ALL ACM OR MCE"
   msg "CUSTOM RESOURCE INSTANCES AND OTHER CONFIGURATION DATA.  THIS DATA WILL"
   msg "BE DELETED WITHOUT PERFORMING ANY KIND OF BACKUP FIRST."
   msg ""
   msg ""
   msg "BESIDES REMOVING RESOURCES THAT ARE SPECIFIC TO ACM OR MCE, THIS SCRIPT"
   msg "WILL OPTONALLY ALSO REMOVE SOME DEPENDENT OPERATORS AND RESOURCE TYPES"
   msg "THAT ARE INStALLED BY ACM OR MCE AND ASSUMED TO BE USED BY ACM OR MCE ONLY."
   msg "THIS CLEANUP ACTION COULD AFFECT OTHER APPLICATIONS OR OPERATORS INSTALLED"
   msg "ON THE SAME CLUSTER AS ACM OR MCE IF THOSE OTHER APPLICATIONS OR OPERATORS"
   msg "RELY ON THE REMOVED OR RECONFIGURED THINGS.  PLEASE REFER TO COMMENTS AT"
   msg "THE TOP OF THE SCRIPT FOR A LIST OF RISKS IN THIS CATEGORY."
   msg ""
   msg "YOU HAVE BEEN WARNED.  :-)"
   msg ""
   msg "If you wish to proceed, invoke this script specifying the -y option to"
   msg "acknowledge these risks and proceeed with cleanup."

   exit 5
fi

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

