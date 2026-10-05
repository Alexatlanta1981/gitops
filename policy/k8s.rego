package main

import rego.v1

workloads := {"Deployment", "StatefulSet", "DaemonSet", "Job", "CronJob"}

pod_spec := input.spec.template.spec if input.kind != "CronJob"
pod_spec := input.spec.jobTemplate.spec.template.spec if input.kind == "CronJob"

containers contains c if some c in pod_spec.containers
containers contains c if some c in pod_spec.initContainers

deny contains msg if {
	workloads[input.kind]
	some c in containers
	c.securityContext.privileged == true
	msg := sprintf("%s/%s: container %s is privileged", [input.kind, input.metadata.name, c.name])
}

deny contains msg if {
	workloads[input.kind]
	some v in pod_spec.volumes
	v.hostPath
	msg := sprintf("%s/%s: hostPath volumes are not allowed", [input.kind, input.metadata.name])
}

deny contains msg if {
	workloads[input.kind]
	pod_spec.hostNetwork == true
	msg := sprintf("%s/%s: hostNetwork is not allowed", [input.kind, input.metadata.name])
}

deny contains msg if {
	workloads[input.kind]
	some c in containers
	not regex.match(`^.+:.+$`, c.image)
	msg := sprintf("%s/%s: image %s must have an explicit tag", [input.kind, input.metadata.name, c.image])
}

deny contains msg if {
	workloads[input.kind]
	some c in containers
	regex.match(`:latest$`, c.image)
	msg := sprintf("%s/%s: image %s must not use :latest", [input.kind, input.metadata.name, c.image])
}

# Pinned = sha-<hex> (CI builds) or semver (v1.2.3).
deny contains msg if {
	workloads[input.kind]
	some c in containers
	tag := regex.find_all_string_submatch_n(`:([^:/]+)$`, c.image, 1)[0][1]
	not regex.match(`^(sha-[0-9a-f]{7,40}|v?[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?)$`, tag)
	msg := sprintf("%s/%s: image tag %q must be sha-<hex> or semver", [input.kind, input.metadata.name, tag])
}
