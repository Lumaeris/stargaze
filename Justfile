image_name := env("BUILD_IMAGE_NAME", "stargaze")
image_tag := env("BUILD_IMAGE_TAG", "latest")
base_dir := env("BUILD_BASE_DIR", ".")
filesystem := env("BUILD_FILESYSTEM", "btrfs")
selinux := env("BUILD_SELINUX", `stat /sys/fs/selinux/status >/dev/null 2>&1 && echo true || echo false`)
image_labels := env("IMAGE_LABELS", "containers.bootc=1")

options := if selinux == "true" { "-v /var/lib/containers:/var/lib/containers:Z -v /sys/fs/selinux:/sys/fs/selinux --security-opt label=type:unconfined_t" } else { "-v /var/lib/containers:/var/lib/containers" }
container_runtime := env("CONTAINER_RUNTIME", `command -v podman >/dev/null 2>&1 && echo podman || echo docker`)

build $image_name=image_name $image_tag=image_tag:
    {{container_runtime}} build -t "${image_name}:${image_tag}" .

bootc $image_name=image_name $image_tag=image_tag *ARGS:
    sudo {{container_runtime}} run \
        --rm --privileged --pid=host \
        -it \
        {{options}} \
        -v /dev:/dev \
        -e RUST_LOG=debug \
        -v "{{base_dir}}:/data" \
        "${image_name}:${image_tag}" bootc {{ARGS}}

disk-image $image_name=image_name $image_tag=image_tag $base_dir=base_dir $filesystem=filesystem:
    #!/usr/bin/env bash
    if [ ! -e "${base_dir}/bootable.img" ] ; then
        fallocate -l 20G "${base_dir}/bootable.img"
    fi
    just bootc $image_name $image_tag install to-disk --composefs-backend \
        --via-loopback /data/bootable.img --filesystem "${filesystem}" \
        --wipe --bootloader systemd

rechunk $image_name=image_name $image_tag=image_tag $image_labels=image_labels:
    #!/usr/bin/env bash
    set -x
    
    export CHUNKAH_CONFIG_STR="$({{container_runtime}} inspect "${image_name}:${image_tag}")"

    # add labels from IMAGE_LABELS
    while IFS= read -r label; do
    if [[ -n "$label" ]]; then
        BUILD_ARGS+=("--label" "$label")
    fi
    done <<< "${image_labels}"

    {{container_runtime}} run --rm "--mount=type=image,src=${image_name},target=/chunkah" \
        -e CHUNKAH_CONFIG_STR quay.io/coreos/chunkah:latest build --compressed \
        --max-layers 128 --tag "${image_name}:${image_tag}" "${BUILD_ARGS[@]}" | podman load
