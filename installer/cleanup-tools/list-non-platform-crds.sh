#!/bin/bash

# Copyright (c) 2023 Red Hat, Inc.

# List CRDs, filtering out the ones that exist on a fresh OCP install.
# The goal is to list only the ones tha tmight be relevant to eg. MCH or MCE.
#
# Filter list developed based on OCP 4.11 installed on VSphere, so it might
# need to be extended for subsequent releases or other platforms.  That's
# easy enough to do by adding new things to the include_patterns or
# exclude_patterns arrays.
#
# Requires:
# - Bash V4
# - oc
# - grep

keepers=()

# We're going to exclude .openshift.io in general, but there are some
# subsets of that API group suffix that are relevant to MCE or ACM.

include_patterns=()
include_patterns+=(".multicluster.openshift.io")
include_patterns+=(".agent-install.openshift.io")
include_patterns+=(".hive.openshift.io")
include_patterns+=(".oadp.openshift.io")

exclude_patterns=()
exclude_patterns+=(".k8s.io")
exclude_patterns+=(".cni.cncf.io")
exclude_patterns+=(".ovn.org")
exclude_patterns+=(".openshift.io")
exclude_patterns+=(".coreos.com")
exclude_patterns+=(".metal3.io")
exclude_patterns+=(".vmware.com")

# Get all of the CRD names.  We're going to munch on this list several times.

all_crds=$(oc get "crd" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')

# Grab from $all_crds the openshift.io ones we want to keep (say are non-platform).

for pattern in "${include_patterns[@]}"; do
   some_keepers=$(grep "$pattern" <<< "$all_crds")
   for keeper in $some_keepers; do
      keepers+=("$keeper")
   done
done

# Now start with $all_crds and filter out all of the ones we don't want to keep.

remaining_crds="$all_crds"

for pattern in "${exclude_patterns[@]}"; do
    remaining_crds=$(grep -v "$pattern" <<< "$remaining_crds")
done
for keeper in $remaining_crds; do
   keepers+=("$keeper")
done

# Show what we're left with....

for keeper in "${keepers[@]}"; do
   echo "$keeper"
done

exit 0

