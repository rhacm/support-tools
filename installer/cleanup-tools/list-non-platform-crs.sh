#!/bin/bash

# Copyright (c) 2023 Red Hat, Inc.
#
# List instances of non-platform CRDs.
#
# Requires
# - Bash V4
# - readlink
# - oc
#
# Uses:
# - list-non-platform-crds.sh (from the same directory as this script)

my_dir=$(dirname $(readlink -f "$0"))

crd_list=$($my_dir/list-non-platform-crds.sh)
for crd in $crd_list; do
   instances=$(oc get "$crd" --all-namespaces -o name)
   if [[ -n "$instances" ]]; then
      echo "Instances of $crd:"
      oc get "$crd" --all-namespaces
      echo ""
   fi
done
