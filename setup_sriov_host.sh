#!/usr/bin/env bash
set -x

mapfile -t nodes < <(oc get nodes | awk '{if(NR>1) print $1}')

for node in "${nodes[@]}"; do
  echo "oc debug node/$node -- chroot /host rpm-ostree kargs --append=intel_iommu=on" 
done

