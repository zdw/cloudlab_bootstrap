# loadadmin.sh

Script to make an k8s admin user, then print out the token for `kubectl proxy` use.

Derived from: https://github.com/kubernetes/dashboard/wiki/Creating-sample-user

After that, for remote access to a cluster of VM's running on a remote system:

ssh -L 8001:localhost:8001 <hostname>

Then on local system, go to:

http://localhost:8001/api/v1/namespaces/kube-system/services/https:kubernetes-dashboard:/proxy/#!

