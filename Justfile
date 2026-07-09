image_name := env("BUILD_IMAGE_NAME", "stargaze")
image_tag := env("BUILD_IMAGE_TAG", "latest")
base_dir := env("BUILD_BASE_DIR", ".")
filesystem := env("BUILD_FILESYSTEM", "btrfs")
selinux := env("BUILD_SELINUX", `stat /sys/fs/selinux/status >/dev/null 2>&1 && echo true || echo false`)
profiles := env("BUILD_PROFILES", "brew,bootc")
ci := env("CI", "false")

options := if selinux == "true" { "-v /var/lib/containers:/var/lib/containers:Z -v /sys/fs/selinux:/sys/fs/selinux --security-opt label=type:unconfined_t" } else { "-v /var/lib/containers:/var/lib/containers" }
container_runtime := env("CONTAINER_RUNTIME", `command -v podman >/dev/null 2>&1 && echo podman || echo docker`)

default:
    @just --list

alias build := build-bootc

build-bootc $profiles=profiles $ci=ci:
    #!/usr/bin/env bash
    ADDIT_ARGS=()
    if [[ {{ci}} == "true" ]]; then
        ADDIT_ARGS+=("--tools-tree-distribution=arch")
    fi

    mkosi -B --debug --profile={{profiles}} ${ADDIT_ARGS}

lint $image_name=image_name $image_tag=image_tag:
    {{container_runtime}} run --rm -it --entrypoint=bootc "${image_name}:${image_tag}" container lint

load $image_name=image_name $image_tag=image_tag $ci=ci:
    #!/usr/bin/env bash
    set -x
    {{container_runtime}} load -i "$(find mkosi.output/* -maxdepth 0 -type d -printf "%T@ ,%p\n" -iname "_*" -print0 | sort -n | head -n1 | cut -d, -f2)" -q | cut -d: -f3 | xargs -I{} {{container_runtime}} tag {} "${image_name}:${image_tag}"
    if [[ {{ci}} == "true" ]]; then
        sudo rm -rf mkosi.output/
    fi

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

rechunk $image_name=image_name $image_tag=image_tag $ci=ci:
    #!/usr/bin/env bash
    export CHUNKAH_CONFIG_STR="$({{container_runtime}} inspect "${image_name}:${image_tag}")"
    # Labels
    LABELS=("--label" "containers.bootc=1")
    if [[ {{ci}} == "true" ]]; then
        LABELS+=("--label" "io.artifacthub.package.deprecated=false")
        LABELS+=("--label" "io.artifacthub.package.prerelease=false")
        LABELS+=("--label" "io.artifacthub.package.license=Apache-2.0")
        LABELS+=("--label" "io.artifacthub.package.keywords=bootc,arch,bootcrew")
        LABELS+=("--label" "io.artifacthub.package.logo-url=https://avatars.githubusercontent.com/u/10499845?s=200&v=4")
        LABELS+=("--label" "io.artifacthub.package.readme-url=https://raw.githubusercontent.com/Lumaeris/stargaze/refs/heads/main/README.md")
        LABELS+=("--label" "org.opencontainers.image.created=$(date -u +%Y\-%m\-%d\T%H\:%M\:%S\Z)")
        LABELS+=("--label" "org.opencontainers.image.description=Stargaze")
        LABELS+=("--label" "org.opencontainers.image.documentation=https://raw.githubusercontent.com/Lumaeris/stargaze/refs/heads/main/README.md")
        LABELS+=("--label" "org.opencontainers.image.source=https://raw.githubusercontent.com/Lumaeris/stargaze/refs/heads/main/Containerfile")
        LABELS+=("--label" "org.opencontainers.image.title=${image_name}")
        LABELS+=("--label" "org.opencontainers.image.url=https://github.com/Lumaeris/stargaze")
        LABELS+=("--label" "org.opencontainers.image.vendor=Lumaeris")
        LABELS+=("--label" "org.opencontainers.image.version=latest-$(date -u +%Y%m%d)")
        if [[ -z "$(git status -s)" ]]; then
            LABELS+=("--label" "org.opencontainers.image.revision=$(git rev-parse HEAD)")
        else
            LABELS+=("--label" "org.opencontainers.image.revision=deadbeef")
        fi
    fi
    {{container_runtime}} run --rm "--mount=type=image,src=${image_name},target=/chunkah" \
        -e CHUNKAH_CONFIG_STR quay.io/coreos/chunkah:latest build --compressed \
        --max-layers 128 --tag "${image_name}:${image_tag}" "${LABELS[@]}" | {{container_runtime}} load

clean:
    mkosi clean
    sudo rm -rf mkosi.tools/ mkosi.cache/
