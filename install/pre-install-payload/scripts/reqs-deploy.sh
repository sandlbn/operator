#!/usr/bin/env bash

set -o errexit
set -o pipefail
set -o nounset

INSTALL_COCO_CONTAINERD=${INSTALL_COCO_CONTAINERD:-false}
INSTALL_OFFICIAL_CONTAINERD=${INSTALL_OFFICIAL_CONTAINERD:-false}
INSTALL_VFIO_GPU_CONTAINERD=${INSTALL_VFIO_GPU_CONTAINERD:-false}
INSTALL_NYDUS_SNAPSHOTTER=${INSTALL_NYDUS_SNAPSHOTTER:-false}

containerd_config="/etc/containerd/config.toml"
artifacts_dir="/opt/confidential-containers-pre-install-artifacts"

readonly snapshot_annotations_marker="disable_snapshot_annotations - DO NOT EDIT. GENERATED BY CoCo OPERATOR"

die() {
	msg="$*"
	echo "ERROR: $msg" >&2
	exit 1
}

function host_ctr() {
	nsenter --target 1 --mount ctr "${@}"
}

function host_systemctl() {
	nsenter --target 1 --mount systemctl "${@}"
}

function get_container_engine() {
	local container_engine
	container_engine=$(kubectl get node "$NODE_NAME" -o jsonpath='{.status.nodeInfo.containerRuntimeVersion}' | awk -F '[:]' '{print $1}')
	if [[ "${container_engine}" != "containerd" && "${container_engine}" != "cri-o" ]]; then
		die "${container_engine} is not yet supported"
	fi

	echo "$container_engine"
}

function set_container_engine() {
	# Those are intentionally not set as local

	container_engine=$(get_container_engine)
	if [ "$container_engine" == "cri-o" ]; then
		container_engine="crio"
	fi
}

function install_containerd_artefacts() {
	local flavour
	flavour="${1}"

	echo "Copying ${flavour} containerd-for-cc artifacts onto host"


	install -D -m 755 "${artifacts_dir}/opt/confidential-containers/bin/${flavour}-containerd" /opt/confidential-containers/bin/containerd
	install -D -m 644 "${artifacts_dir}/etc/systemd/system/containerd.service.d/containerd-for-cc-override.conf" /etc/systemd/system/containerd.service.d/containerd-for-cc-override.conf
}

function install_coco_containerd_artefacts() {
	install_containerd_artefacts "coco"
}

function install_official_containerd_artefacts() {
	install_containerd_artefacts "official"
}

function install_vfio_gpu_containerd_artefacts() {
	install_containerd_artefacts "vfio-gpu"
}

function install_nydus_snapshotter_artefacts() {
	echo "Copying nydus-snapshotter artifacts onto host"

	install -D -m 755 "${artifacts_dir}/opt/confidential-containers/bin/containerd-nydus-grpc" /opt/confidential-containers/bin/containerd-nydus-grpc
	install -D -m 755 "${artifacts_dir}/opt/confidential-containers/bin/nydus-overlayfs" /opt/confidential-containers/bin/nydus-overlayfs
	ln -sf /opt/confidential-containers/bin/nydus-overlayfs /usr/local/bin/nydus-overlayfs

	install -D -m 644 "${artifacts_dir}/opt/confidential-containers/share/nydus-snapshotter/config-coco-guest-pulling.toml" /opt/confidential-containers/share/nydus-snapshotter/config-coco-guest-pulling.toml
	install -D -m 644 "${artifacts_dir}/etc/systemd/system/nydus-snapshotter.service" /etc/systemd/system/nydus-snapshotter.service

	host_systemctl daemon-reload
	host_systemctl enable nydus-snapshotter.service

	configure_nydus_snapshotter_for_containerd
}

function install_artifacts() {
	# There shouldn't be installed additional artifacts for CRI-O
	[ "${container_engine}" = "crio" ] && return

	if [ "${INSTALL_COCO_CONTAINERD}" = "true" ]; then
		install_coco_containerd_artefacts
	fi

	if [ "${INSTALL_OFFICIAL_CONTAINERD}" = "true" ]; then
		install_official_containerd_artefacts
	fi

	if [ "${INSTALL_VFIO_GPU_CONTAINERD}" = "true" ]; then
		install_vfio_gpu_containerd_artefacts
	fi

	if [ "${INSTALL_NYDUS_SNAPSHOTTER}" = "true" ]; then
		install_nydus_snapshotter_artefacts
	fi
}

function uninstall_containerd_artefacts() {
	echo "Removing containerd-for-cc artifacts from host"

	echo "Removing the systemd drop-in file"
	rm -f "/etc/systemd/system/${container_engine}.service.d/${container_engine}-for-cc-override.conf"
	echo "Removing the systemd drop-in file's directory, if empty"
	if [ -d "/etc/systemd/system/${container_engine}.service.d" ]; then
		rmdir --ignore-fail-on-non-empty "/etc/systemd/system/${container_engine}.service.d"
	fi

	echo "Removing the containerd binary"
	rm -f /opt/confidential-containers/bin/containerd
	echo "Removing the /opt/confidential-containers/bin directory"
	if [ -d /opt/confidential-containers/bin ]; then
		rmdir --ignore-fail-on-non-empty -p /opt/confidential-containers/bin
	fi
}

function uninstall_nydus_snapshotter_artefacts() {
	if host_systemctl list-units | grep -q nydus-snapshotter; then
		for i in `host_ctr -n k8s.io snapshot --snapshotter nydus list | grep -v KEY | cut -d' ' -f1`; do
			host_ctr -n k8s.io snapshot --snapshotter nydus rm "$i" || true
		done

		remove_nydus_snapshotter_from_containerd
		host_systemctl disable --now nydus-snapshotter.service
		rm -rf /etc/systemd/system/nydus-snapshotter.service
	fi

	echo "Removing nydus-snapshotter artifacts from host"
	rm -f /opt/confidential-containers/bin/containerd-nydus-grpc
	rm -f /opt/confidential-containers/bin/nydus-overlayfs
	rm -f /usr/local/bin/nydus-overlayfs
	rm -f /opt/confidential-containers/share/nydus-snapshotter/config-coco-guest-pulling.toml

	# We can do this here as we're sure that only the nydus-snapshotter is
	# installing something in the /opt/confidential-containers/share
	# directory
	rm -rf /opt/confidential-containers/share
	rm -rf /var/lib/containerd-nydus/*
}

function uninstall_artifacts() {
	# It didn't install additional artifacts for CRI-O, so return
	[ "${container_engine}" = "crio" ] && return

	if [ "${INSTALL_NYDUS_SNAPSHOTTER}" = "true" ]; then
		uninstall_nydus_snapshotter_artefacts
	fi

	if [ "${INSTALL_COCO_CONTAINERD}" = "true" ] || [ "${INSTALL_OFFICIAL_CONTAINERD}" = "true" ] || [ "${INSTALL_VFIO_GPU_CONTAINERD}" = "true" ]; then
		uninstall_containerd_artefacts
	fi
}

function restart_systemd_service() {
	host_systemctl daemon-reload
	echo "Restarting ${container_engine}"
	host_systemctl restart "${container_engine}"
}

function configure_nydus_snapshotter_for_containerd() {
	echo "configure nydus snapshotter for containerd"

	local containerd_imports_path="/etc/containerd/config.toml.d"
	local tmp_containerd_config="$(mktemp)"

	( for i in {{1..10}}; do
		local containerd_config_pre="$(cat "${containerd_config}")"
		echo "${containerd_config_pre}" > "$tmp_containerd_config"

		echo "Create ${containerd_imports_path}"
		mkdir -p "${containerd_imports_path}"

		echo "Drop-in the nydus configuration"
		cat << EOF | tee "${containerd_imports_path}"/nydus-snapshotter.toml
[proxy_plugins]
  [proxy_plugins.nydus]
	type = "snapshot"
	address = "/run/containerd-nydus/containerd-nydus-grpc.sock"
EOF
		if grep -q "^imports = " "$tmp_containerd_config"; then
			# Avoid adding the import twice
			if ! grep "^imports = " "$tmp_containerd_config" | grep -q "\"${containerd_imports_path}/nydus-snapshotter.toml\""; then
				sed -i -e "s|^imports = \[\(.*\)\]|imports = [\"${containerd_imports_path}/nydus-snapshotter.toml\", \1]|g" "${tmp_containerd_config}"
				sed -i -e "s|, ]|]|g" "${tmp_containerd_config}"
			fi
		else
			sed -i -e "1s|^|imports = [\"${containerd_imports_path}/nydus-snapshotter.toml\"]\n|" "${tmp_containerd_config}"
		fi

		# Annotations should be passed down to the remote snapshotter in order to
		# make it work. This can be done by setting `disable_snapshot_annotations = false`
		# in the containerd's config.toml.
		if grep -q 'disable_snapshot_annotations' "$tmp_containerd_config"; then
			sed -i -e "s|disable_snapshot_annotations = true|disable_snapshot_annotations = false|" \
				"${tmp_containerd_config}"
		else
			# In case the property does not exist, let's append it to the
			# [plugins."io.containerd.grpc.v1.cri".containerd] section.
			sed -i '/\[plugins\..*\.containerd\]/a'"# ${snapshot_annotations_marker}"'\ndisable_snapshot_annotations = false' \
				"${tmp_containerd_config}"
		fi

		# Finally if for some unknown reason the property is still not set, let's
		# fail the installation.
		grep -q 'disable_snapshot_annotations = false' "${tmp_containerd_config}"

		# Only update the file when the original one did not change
		if [ "$(cat "${containerd_config}")" == "$containerd_config_pre" ]; then
			mv "$tmp_containerd_config" "$containerd_config"
			exit 0
		fi
		sleep $(($RANDOM / 1000))
	done ) || { echo "Failed to configure snapshotter in 10 iterations, is someone else modifying the config?"; exit -1; }
	rm -f "$tmp_containerd_config"
}

function remove_nydus_snapshotter_from_containerd() {
	echo "Remove nydus snapshotter from containerd"

	local tmp_containerd_config="$(mktemp)"
	local containerd_imports_path="/etc/containerd/config.toml.d"

	( for i in {{1..10}}; do
        local containerd_config_pre="$(cat "${containerd_config}")"
        echo "${containerd_config_pre}" > "$tmp_containerd_config"

		sed -i -e "s|\"${containerd_imports_path}/nydus-snapshotter.toml\"||g" "${tmp_containerd_config}"
		sed -i -e "s|, ]|]|g" "${tmp_containerd_config}"

		if grep -q "${snapshot_annotations_marker}" "${tmp_containerd_config}"; then
			sed -i '/'"${snapshot_annotations_marker}"'/d' \
				"${tmp_containerd_config}"
			sed -i '/disable_snapshot_annotations = false/d' \
				"${tmp_containerd_config}"
		else
			sed -i -e "s|disable_snapshot_annotations = false|disable_snapshot_annotations = true|" "${tmp_containerd_config}"
		fi

        if [ "$(cat "${containerd_config}")" == "$containerd_config_pre" ]; then
            mv "$tmp_containerd_config" "$containerd_config"
            exit 0
        fi
		sleep $(($RANDOM / 1000))
	done ) || { echo "Failed to unconfigure snapshotter in 10 iterations, is someone else modifying the config?"; exit -1; }
	rm -f "$tmp_containerd_config"
	rm -f "${containerd_imports_path}/nydus-snapshotter.toml"
}

label_node() {
	case "${1}" in
	install)
		kubectl label node "${NODE_NAME}" confidentialcontainers.org/preinstall=done
		;;
	uninstall)
		kubectl label node "${NODE_NAME}" confidentialcontainers.org/postuninstall=done
		;;
	*)
		;;
	esac
}

function wait_till_node_is_ready() {
    local ready="False"

    while ! [[ "${ready}" == "True" ]]; do
        sleep 2s
        ready=$(kubectl get node $NODE_NAME -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
    done
}

function print_help() {
	echo "Help: ${0} [install/uninstall]"
}

function main() {
	echo "INSTALL_COCO_CONTAINERD: ${INSTALL_COCO_CONTAINERD}"
	echo "INSTALL_OFFICIAL_CONTAINERD: ${INSTALL_OFFICIAL_CONTAINERD}"
	echo "INSTALL_VFIO_GPU_CONTAINERD: ${INSTALL_VFIO_GPU_CONTAINERD}"

	# script requires that user is root
	local euid
	euid=$(id -u)
	if [ "${euid}" -ne 0 ]; then
		die "This script must be run as root"
	fi

	local action="${1:-}"
	if [ -z "${action}" ]; then
		print_help && die ""
	fi

	set_container_engine

	if [[ ${container_engine} = "containerd" && ! -f "${containerd_config}" ]]; then
		mkdir -p /etc/containerd
		containerd config default > /etc/containerd/config.toml
	fi

	case "${action}" in
	install)
		install_artifacts
		;;
	uninstall)
		# Adjustment for s390x (clefos:7)
		# It is identified that a node is not labeled during post-uninstall,
		# if the function is called after container engine is restarted by systemctl.
		# This results in having the uninstallation not triggered.
		if [ "$(uname -m)" = "s390x" ]; then
			label_node "${action}"
		fi
		uninstall_artifacts
		;;
	*)
		print_help
		;;
	esac

	restart_systemd_service
	wait_till_node_is_ready
	label_node "${action}"


	# It is assumed this script will be called as a daemonset. As a result, do
	# not return, otherwise the daemon will restart and reexecute the script.
	sleep infinity
}

main "$@"
