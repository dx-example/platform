# Openshift-Pipelines

This chart deploys the Red Hat OpenShift Pipelines operator which adds Tekton functionality to the cluster.

## Installation

The operator itself is deployed to the `openshift-operators` _Namespace_ and creates the `pipeline` _TektonPipelines_ resource which installs Tekton Pipelines.

Tekton Pipelines are deployed to the `openshift-pipelines` _Namespace_ - this is where the controller pods run.

## Uninstallation

Uninstallation of Openshift Pipelines must be done by following the official uninstallation documentation: https://docs.openshift.com/container-platform/4.8/cicd/pipelines/uninstalling-pipelines.html

1. delete the custom resources created by the Pipelines Operator
2. Uninstall the Operator itself

## Documentation

Official Openshift Pipelines documentation can be found here: https://docs.openshift.com/container-platform/4.8/cicd/pipelines/understanding-openshift-pipelines.html

Tekton documentation can be found here: https://tekton.dev/docs

## Troubleshooting

Check the pod logs in the `openshift-pipelines` _Namespace_ for information.
