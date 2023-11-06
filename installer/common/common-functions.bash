# Source me, don't run me.

# Copyright (c) 2023 Red Hat, Inc.

# Author: joeg-pro

#----------------------------------------
# COnstants for referencing fixed things
#----------------------------------------

# Various CR kindss. Ech <foo>_kind variables identifies one kiind...

# Kubernetes kinds:
k8s_validating_webhook_cfg_kind="validatingwebhookconfigurations.admissionregistration.k8s.io"
k8s_mutating_webhook_cfg_kind="mutatingwebhookconfigurations.admissionregistration.k8s.io"
k8s_apiservice_kind="aPiservices.apiregistration.k8s.io"
k8s_crd_kind="customresourcedefinitions.apiextensions.k8s.io"

# OLM/operator framework kinds:
olm_og_kind="operatorgroup.operators.coreos.com"
olm_sub_kind="subscription.operators.coreos.com"
olm_ip_kind="installplan.operators.coreos.com"
olm_csv_kind="clusterserviceversion.operators.coreos.com"
olm_catsrc_kind="catalogsource.operators.coreos.com"

# Constants for fixed namespaces, i.e. ones that can't be configured.
# Each <foo>_ns identifies one fixed namespace...

# For OLM:
olm_marketplace_ns="openshift-marketplace"
olm_global_operators_ns="openshift-operators"

#---------------------------------------------------
# Utility functions for finding configurable things
#---------------------------------------------------

function jsonpath_range_over_items() {

   # Emits a jsonpath spec that iterates over an .items() list, outputting
   # a delimited list of fields, one line per item.

   local field_list="$@"
   local jp="{range .items[*]}"
   local is_first=1
   local delim="/"

   for f in $field_list; do
      if [[ $is_first -eq 0 ]]; then
         jp="$jp{\"$delim\"}"
      fi
      jp="$jp{$f}"
      is_first=0
   done
   jp="$jp{\"\n\"}{end}"
   echo $jp
}

function extract_delimited_field() {
   local field_nr="$1"
   local delim="$2"
   local field_string="$3"

   cut -d"$delim" -f"$field_nr" <<< "$field_string"
}

function find_subs_for_operator() {

   # Find the OLM subscriptions to an operator under either its released-product or
   # community-operator package name. If found emit package-name, namespace and name
   # of subscription for each found.

   local pkg_name_1="$1"
   local pkg_name_2="${2:-.}"
   local in_ns="$3"

   if [[ "$pkg_name_2" == "." ]]; then
      pkg_name_2="$pkg_name_1"
   fi

   local jp=$(jsonpath_range_over_items ".spec.name" ".metadata.namespace" ".metadata.name")
   if [[ -z "$in_ns" ]]; then
      local t=$(oc get "$olm_sub_kind" --all-namespaces -o jsonpath="$jp")
   else
      local t=$(oc -n "$in_ns" get "$olm_sub_kind" -o jsonpath="$jp")
   fi

   if [[ -z "$t" ]]; then
      return
   fi

   while read line; do
      local pkg=$(extract_delimited_field 1 "/" "$line")
      if [[ "$pkg" == "$pkg_name_1" ]] || [[ "$pkg" == "$pkg_name_2" ]]; then
         local ns=$(extract_delimited_field 2 "/" "$line")
         local sub_name=$(extract_delimited_field 3 "/" "$line")
         echo "$pkg/$ns/$sub_name"
      fi
   done <<< "$t"
}

function find_csvs_for_operator() {

   # Find the OLM CSVs for an operator under either its released-product or community-
   # operator package name. If found emit package-name, namespace and name of that CSV
   # for each one found.

   # NB: We rely on the following OLM label to find a matching CSV:
   #
   # operators.coreos.com/advanced-cluster-management.acm: ""
   # operators.coreos.com/<pkg-name>.<namespace>: ""

   local pkg_name_1="$1"
   local pkg_name_2="${2:-.}"
   local in_ns="$3"

   if [[ "$pkg_name_2" == "." ]]; then
      pkg_name_2="$pkg_name_1"
   fi

   local jp=$(jsonpath_range_over_items ".metadata.namespace" ".metadata.name")
   if [[ -z "$in_ns" ]]; then
      local t=$(oc get "$olm_csv_kind" --all-namespaces -o jsonpath="$jp")
   else
      local t=$(oc -n "$in_ns" get "$olm_csv_kind" -o jsonpath="$jp")
   fi

   if [[ -z "$t" ]]; then
      return
   fi

   while read line; do
      if [[ -z "$line" ]]; then
         continue
      fi
      local csv_ns=$(extract_delimited_field 1 "/" "$line")
      local csv_name=$(extract_delimited_field 2 "/" "$line")
      local csv_labels=$(oc -n "$csv_ns" get "$olm_csv_kind" "$csv_name" \
         -o jsonpath='{.metadata.labels}')

      csv_labels="${csv_labels#\{}"  # Get rid of surrounding {}
      csv_labels="${csv_labels%\}}"

      local save_ifs="$IFS"
      IFS=","
      for l in $csv_labels; do
         local l_name="${l%:*}"
         for try_pkg in $pkg_name_1 $pkg_name_2; do
            local olm_pkg_label="\"operators.coreos.com/$try_pkg.$csv_ns\""
            if [[ "$l_name" == "$olm_pkg_label" ]]; then
               echo "$try_pkg/$csv_ns/$csv_name"
               break
            fi
        done
      done
   done <<< "$t"

   return
}

function find_operator_by_sub_or_csv() {

   local pkg_name_1="$1"
   local pkg_name_2="${2:-.}"

   local sub_info=$(find_subs_for_operator "$pkg_name_1" "$pkg_name_2")
   if [[ -n "$sub_info" ]]; then

      local sub_cnt=$(wc -l <<< "$sub_info")

      if [[ $sub_cnt -eq 1 ]]; then
         echo "sub/$sub_info"
         return
      elif [[ $sub_cnt -gt 1 ]]; then
         >&2 echo "Warning: Multiple $pkg_name_1/$pkg_name_2 OLM subscriptions found, using first."
         local first_sub=$(head -n1 <<< "$sub_info")
         echo "sub/$first_sub"
         return
      fi
   fi

   local csv_info=$(find_csvs_for_operator "$pkg_name_1" "$pkg_name_2")

   if [[ -n "$csv_info" ]]; then
      local csv_cnt=$(wc -l <<< "$csv_info")

      if [[ $csv_cnt -eq 1 ]]; then
         echo "csv/$csv_info"
         return
      elif [[ $csv_cnt -gt 1 ]]; then
         >&2 echo "Warning: Multiple $pkg_name_1/$pkg_name_2 CSVs, using first."
         local first_csv=$(head -n1 <<< "$csv_info")
         echo "csv/$first_csv"
         return
      fi
   fi

   return

}

function find_singleton_cluster_resource() {

   # Find the (expected) singleton instance of a cluster-scoped resource. If found,
   # emit the name of that resource.  If more than one found, warn and use the
   # first one found.

   local kind="$1"

   local jp=$(jsonpath_range_over_items ".metadata.name")
   local t=$(oc get "$kind" -o jsonpath="$jp")

   local found_it=0
   local warned_about_dups=0

   while read line; do
      if [[ -n "$line" ]]; then
         if [[ $found_it -eq 0 ]]; then
            found_it=1
            local name="$line"
         else
            if [[ $warned_about_dups -eq 0 ]]; then
               warned_about_dups=1
               >&2 echo "Warning: Multiple $kind resources found, using first."
            fi
         fi
      fi
   done <<< "$t"
   if [[ $found_it -ne 0 ]]; then
      echo "$name"
   fi

}

function find_singleton_namespaced_resource() {

   # Find the (expected) singleton instance of a namespaced resource. If found, emit
   # the nameepsace and resource name of that instnace.  If more than one found,
   # warn and use the first one found.

   local kind="$1"


   local jp=$(jsonpath_range_over_items ".metadata.namespace" ".metadata.name")
   local t=$(oc get "$kind" --all-namespaces -o jsonpath="$jp")

   local found_it=0
   local warned_about_dups=0

   while read line; do
      if [[ -n "$line" ]]; then
         if [[ $found_it -eq 0 ]]; then
            found_it=1
            local ns=$(extract_delimited_field 1 "/" "$line")
            local name=$(extract_delimited_field 2 "/" "$line")
         else
            if [[ $warned_about_dups -eq 0 ]]; then
               warned_about_dups=1
               >&2 echo "Warning: Multiple $kind resources found, using first."
            fi
         fi
      fi
   done <<< "$t"

   if [[ $found_it -ne 0 ]]; then
      echo "$ns/$name"
   fi
}

