#!/bin/bash

# Copyright (c) 2023 Red Hat, Inc.
#
# Script that produces the differences in resource invneotires
# created by the inventory-system-resources.sh script.

# Requires:
# - Bash V4
# - diff

before_dir="${1%/}"
after_dir="${2%/}"

for after_file in $after_dir/*; do
   file_base=$(basename $after_file)

   before_file="$before_dir/$file_base"
   if ! cmp "$before_file"  "$after_file"; then
      echo "Differences in $file_base:"
      diff -u $before_file $after_file
   else
      echo "No changes in $file_base"

   fi
done

