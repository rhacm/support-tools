# Source me, don't run me.

# Copyright (c) 2023 Red Hat, Inc.

# Author: joeg-pro

# Requires common-functions.bash, assumed to be already source'ed in.

#----------------------------------------
# COnstants for referencing fixed things
#----------------------------------------

# OLMM package names:
mce_prod_pkg_name="multicluster-engine"
mce_community_pkg_name="stolostron-engine"
mce_guess_pkg_name="$mce_prod_pkg_name"

# Various CR kindss. Each <foo>_kind variable identifies one kiind...

# MCE operator kind:
mce_kind="multiclusterengines.multicluster.openshift.io"

# MCE Foundation/Cluster Lifecycle kinds:
cm_clustermanager_kind="clustermanagers.operator.open-cluster-management.io"
cm_managedcluuster_kind="managedclusters.cluster.open-cluster-management.io"

# Kinds related to other MCE components:
hive_config_kind="hiveconfigs.hive.openshift.io"
ai_config_kind="agentserviceconfig.agent-install.openshift.io"
disc_config_kind="discoveryconfig.discovery.open-cluster-management.io"

# Constants for fixed namespaces, i.e. ones that can't be configured.
# Each <foo>_ns identifies one fixed namespace...

# For MCE:
default_hub_ns="open-cluster-management"
cm_hub_ns="open-cluster-management-hub"
cm_local_cluster_ns="local-cluster"
hive_ns="hive"

#----------------------------------------------
# Varibles for referencing configurable things
#----------------------------------------------

# Variables for namespaces and other resources that are configurable. Their values
# are  set to null here just to get them listed in one place, with the value expected
# to be found at runtime.

MCE_SUB_NS=""    # The namespace in which the OLM subscription for MCE lives.
MCE_SUB_NAME=""  # The name of the OLM subscription resource for MCE.
MCE_PKG_NAME=""  # The name of the OLM package for MCE (community or productized)
MCE_OP_NS=""     # The namespace in which the MCE operator lives. (Usualally: multicluster-engine)
MCE_NS=""        # The namespace in which the MCE operand lives.  This is almost always
                 # the same as $mce_op_ns but there is means to make it different.
MCE_NAME=""      # The name of the MCE resource.  (Usually: multicluster-engine)
is_mce_engine=0  # Set to non-zero if the cluster is considered an MCE "engine" instance.

#---------------------------------------------------------------
# MCE-specific functions to locate various configurable things.
#---------------------------------------------------------------

function find_mce_operator_things() {

   # Finds OLM and operator-related resources names and namespaces for MCE:
   #
   # - The namespace and name of the OLM sub for the operator (MCE_SUB_NS, MCE_SUB_NAME)
   # - The namespace in which the operator is running (MCE_OP_NS)
   # - The name of the MCE resource (cluster scoped) (MCE_NAME)
   # - The target namespace for the MCE "engine" operand. (MCE_NS)
   #
   # Not all of these will exist, especially in cases of failed/stalled installs.
   # If any of these exist, we consider the clsuter an MCE "engine" instance.
   #
   # Topology notes:
   #
   # - As of this wring, MCE is a "OwnNamespace" operator which means the operator
   #   will always be deployed in the same namespace as the OLM subscription, so
   #   MCE_SUB_NS will always equal MCE_OP_NS, but we define both in case this changes.
   #
   # - The  MCE resource is global, so it is not associated with a nameapce.
   #
   # - By default and hence the usual case, the MCE operand deployment reside in the
   #   same namespace as the operator. But this change by changed by MCE.spec.targetNamespace.
   #   So MCE_OP_NS is  usually the same as MCE_NS, but doesn't have to be.

   echo "Locating MCE operator things."

   export MCE_SUB_NS=""
   export MCE_SUB_NAME=""
   export MCE_PKG_NAME=""
   export MCE_OP_NS=""
   export MCE_NS=""
   export MCE_NAME=""

   local have_sub_or_csv=0
   local info=$(find_operator_by_sub_or_csv "$mce_prod_pkg_name" "$mce_community_pkg_name")
   if [[ -n "$info" ]]; then
      have_sub_or_csv=1
      local how_found=$(extract_delimited_field 1 "/" "$info")
      export MCE_PKG_NAME=$(extract_delimited_field 2 "/" "$info")
      if [[ "$how_found" == "sub" ]]; then
         export MCE_SUB_NS=$(extract_delimited_field 3 "/" "$info")
         export MCE_SUB_NAME=$(extract_delimited_field 4 "/" "$info")
         export MCE_OP_NS="$MCE_SUB_NS"
      else
         # Since we found a CSV, we know the operator is in the same namespace as it.
         export MCE_OP_NS=$(extract_delimited_field 3 "/" "$info")
      fi
   else
      # Since we didn't find a subscription or CSV, we don't know for sure
      # what the package name is, but we'll take a guess.
      export MCE_PKG_NAME="$mce_guess_pkg_name"
   fi

   local have_mce=0
   if oc get crd "$mce_kind" -o name > /dev/null 2>&1; then
      info=$(find_singleton_cluster_resource "$mce_kind")
      if [[ -n "$info" ]]; then
         have_mce=1
         export MCE_NAME="$info"
         export MCE_NS=$(oc get "$mce_kind" "$MCE_NAME" -o jsonpath='{.spec.targetNamespace}')
            if [[ $have_sub_or_csv -eq 0 ]]; then
            # Without a CSV or subscription, we can't reliably determine where
            # the operator is running.  But we'll take a guess and say that its
            # running in the operand namespace, since that is typical.
            export MCE_OP_NS="$MCE_NS"
         fi
      fi
   fi

   if [[ $have_sub_or_csv -eq 0 ]] && [[ $have_mce -eq 0 ]]; then
      echo "Did not detect signs of the MCE operator or MCE resource."
      return
   fi

   is_mce_engine=1

   echo "MCE operator resources:"
   if [[ -n "$MCE_SUB_NAME" ]]; then
      echo "   MCE sub namespace:      $MCE_SUB_NS"
      echo "   MCE sub name:           $MCE_SUB_NAME"
   else
      echo "   No MCE subscription found"
   fi
   echo "   MCE package:            $MCE_PKG_NAME"

   if [[ -n "$MCE_OP_NS" ]]; then
      echo "   MCE op namespace:       $MCE_OP_NS"
   fi
   if [[ -n "$MCE_NAME" ]]; then
      echo "   MCE operand namespace:  $MCE_NS"
      echo "   MCE resource name:      $MCE_NAME"
   else
      echo "   No MCE resource found"
   fi
   echo ""
}
