# k8s-server

This is an on-prem, home Kubernetes cluster where local development happens before apps are deployed in the cloud.

## Access

A cluster-admin kubeconfig is located at `/home/andrew/admin.conf`.

## Ingress

All ingresses should use hostnames with a `.immutablesoftware.dev` or `.primera.rodeo` domain. Which one should be used depends on the app/project being deployed, but `.immutablesoftware.dev` is a good default choice.