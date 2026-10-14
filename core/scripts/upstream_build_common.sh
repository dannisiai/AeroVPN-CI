#!/usr/bin/env bash
# Sourced after core/upstream.env by the platform builders.
prepare_upstream() {
    if [ ! -e "${UPSTREAM_DIR}" ]; then
        mkdir -p "${ROOT_DIR}/core/upstream"
        git clone --depth 1 --branch "${UPSTREAM_VERSION}" "${UPSTREAM_REPO}" "${UPSTREAM_DIR}"
    fi
    local ref actual
    for ref in HEAD "${UPSTREAM_VERSION}^{commit}"; do
        actual="$(git -C "${UPSTREAM_DIR}" rev-parse "${ref}")"
        if [ "${actual}" != "${UPSTREAM_COMMIT}" ]; then
            echo "ERROR: unreviewed upstream ${ref}=${actual}, expected ${UPSTREAM_COMMIT}." >&2
            return 1
        fi
    done
    if [ -n "$(git -C "${UPSTREAM_DIR}" status --porcelain --untracked-files=normal)" ]; then
        echo "ERROR: upstream source is modified; use a clean pinned checkout." >&2
        return 1
    fi
    test -d "${UPSTREAM_DIR}/experimental/libbox"
}

install_gomobile() {
    local name
    GOBIN_DIR="${ROOT_DIR}/core/upstream/tools/gomobile-${GOMOBILE_VERSION}"
    mkdir -p "${GOBIN_DIR}"
    export GOBIN="${GOBIN_DIR}"
    export PATH="${GOBIN_DIR}:${PATH}"
    for name in gomobile gobind; do
        go install "github.com/sagernet/gomobile/cmd/${name}@${GOMOBILE_VERSION}"
        if ! go version -m "${GOBIN_DIR}/${name}" | awk -v expected="${GOMOBILE_VERSION}" \
            '$1 == "mod" && $2 == "github.com/sagernet/gomobile" && $3 == expected { found=1 } END { exit !found }'; then
            echo "ERROR: wrong gomobile fork/version in ${GOBIN_DIR}/${name}." >&2
            return 1
        fi
    done
}
