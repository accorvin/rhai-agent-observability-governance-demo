.PHONY: install deploy-mlflow deploy-model test-model demo-agent verify

install:
	./shared/install-rhoai.sh

deploy-mlflow:
	./scenarios/mlflow-agent-observability/scripts/deploy-mlflow.sh

deploy-model:
	./scenarios/maas-cpu-simulator/scripts/deploy-model.sh

test-model:
	./scenarios/maas-cpu-simulator/scripts/test-maas.sh

demo-agent:
	./scenarios/mlflow-agent-observability/scripts/run-agent-demo.sh

verify:
	oc get csv -n redhat-ods-operator
	oc get csv -n cert-manager-operator
	oc get csv -n openshift-operators | grep rhcl
	oc get csv -n openshift-lws-operator
	oc get kuadrant kuadrant -n kuadrant-system
	oc get gateway maas-default-gateway -n openshift-ingress
	oc get datasciencecluster default-dsc -o jsonpath='{.status.phase}{"\n"}'
	oc get datasciencecluster default-dsc -o jsonpath='{.status.conditions[?(@.type=="ModelsAsAServiceReady")].status}{"\n"}'
	oc get deployment postgres -n redhat-ods-applications
	oc get deployment maas-api -n redhat-ai-gateway-infra
	oc get pods -n redhat-ods-applications
	oc get pods -n redhat-ai-gateway-infra
