# Source me, don't run me.

# Copyright (c) 2023 Red Hat, Inc.

# Author: joeg-pro

# Requires common-functions.bash, assumed to be source'ed in.

#----------------------------------------
# COnstants for referencing fixed things
#----------------------------------------

# OLMM package names:
mch_prod_pkg_name="advanced-cluster-management"
mch_community_pkg_name="stolostron"
mch_guess_pkg_name="$mch_prod_pkg_name"

# Various CR kindss. Ech <foo>_kind variables identifies one kiind...

# MCH operator kind:
mch_kind="multiclusterhubs.operator.open-cluster-management.io"

# MCH App Lifecycle kinds:
alc_sub_kind="subscription.apps.open-cluster-management.io"
alc_helmrelease_kind="helmreleases.apps.open-cluster-management.io"

# Kinds related to other MCH components:
mco_kind="multiclusterobservabilities.observability.open-cluster-management.io"

# Constants for fixed namespaces, i.e. ones that can't be configured.
# Each <foo>_ns identifies one fixed namespace...

# For MCH:
mco_ns="open-cluster-management-observability"

#----------------------------------------------
# Varibles for referencing configurable things
#----------------------------------------------

# Variables for namespaces and other resources that are configurable. Their values
# are  set to null here just to get them listed in one place, with the value expected
# to be found at runtime.

MCH_SUB_NS=""    # The namespace in which the OLM scription for ACM (aka MCH) lives.
MCH_SUB_NAME=""  # The name of the OLM subscription resource for ACM.
MCE_PKG_NAME=""  # The name of the OLM package for MCE (community or productized)
MCH_OP_NS=""     # The namespace in which the MCH operator lives. (Usually: open-cluster-management)
MCH_NS=""        # The namespace in which the MCH operand lives.  This is almost always
                 # the same as $mce_op_ns but there is means to make it different.
MCH_NAME=""      # The name of the MCH resource.  (Usually: ???)
is_mch_hub=0     # Set to non-zero if the cluster if considered an ACM "hub" instance.


#----------------------------------------------------------------
# MCH-specific functions to locate various configurable things.
#----------------------------------------------------------------

function find_mch_operator_things() {

   echo "Locating MCH operator things."

   export MCH_SUB_NS=""
   export MCH_SUB_NAME=""
   export MCH_PKG_NAME=""
   export MCH_OP_NS=""
   export MCH_NS=""
   export MCH_NAME=""

   local have_sub_or_csv=0
   local info=$(find_operator_by_sub_or_csv "$mch_prod_pkg_name" "$mch_community_pkg_name")
   if [[ -n "$info" ]]; then
      have_sub_or_csv=1
      local how_found=$(extract_delimited_field 1 "/" "$info")
      export MCH_PKG_NAME=$(extract_delimited_field 2 "/" "$info")
      if [[ "$how_found" == "sub" ]]; then
         export MCH_SUB_NS=$(extract_delimited_field 3 "/" "$info")
         export MCH_SUB_NAME=$(extract_delimited_field 4 "/" "$info")
         export MCH_OP_NS="$MCH_SUB_NS"
      else
         # Since we found a CSV, we know the operator is in the same namespace as it.
         export MCH_OP_NS=$(extract_delimited_field 3 "/" "$info")
      fi
   else
      # Since we didn't find a subscription or CSV, we don't know for sure
      # what the package name is, but we'll take a guess.
      export MCH_PKG_NAME="$mch_guess_pkg_name"
   fi

   local have_mch=0
   if oc get crd "$mch_kind" -o name > /dev/null 2>&1; then
      info=$(find_singleton_namespaced_resource "$mch_kind")
      if [[ -n "$info" ]]; then
         have_mch=1
         export MCH_NS=$(extract_delimited_field 1 "/" "$info")
         export MCH_NAME=$(extract_delimited_field 2 "/" "$info")
         if [[ $have_sub_or_csv -eq 0 ]]; then
            # Currently, the operator is a single-namespace kind, so the operator
            # is always running in the same namespace as its singleton operand.
            # So we can fill in the operator NS even though we didn't find a
            # CSV or a subscription.
            export MCH_OP_NS="$MCH_NS"
         fi
      fi
   fi

   if [[ $have_sub_or_csv -eq 0 ]] && [[ $have_mch -eq 0 ]]; then
      echo "Did not detect signs of the MCH operator or MCH resource."
      return
   fi

   is_mch_hub=1

   echo "MCH operator resources:"
   if [[ -n "$MCH_SUB_NAME" ]]; then
      echo "   MCH sub namespace:      $MCH_SUB_NS"
      echo "   MCH sub name:           $MCH_SUB_NAME"
   else
      echo "   No MCH subscription found"
   fi
   echo "   MCH package:            $MCH_PKG_NAME"

   if [[ -n "$MCH_OP_NS" ]]; then
      echo "   MCH op namespace:       $MCH_OP_NS"
   fi
   if [[ -n "$MCH_NAME" ]]; then
      echo "   MCH operand namespace:  $MCH_NS"
      echo "   MCH resource name:      $MCH_NAME"
   else
      echo "   No MCH resource found"
   fi
   echo ""

}
