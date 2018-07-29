#!/usr/bin/env bash

kubectl create -f admin-user.yaml
kubectl create -f admin-cluster-role-binding.yaml

kubectl -n kube-system describe secret $(kubectl -n kube-system get secret | grep admin-user | awk '{print $1}')

kubectl proxy
